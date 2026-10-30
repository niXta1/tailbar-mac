import AppKit
import IOKit.pwr_mgt

// MARK: - sleep / wake recovery
//
// With INCY (or Happ) configured to keep its VPN up during sleep, a running
// Tailscale with an exit node (whose 0/1 and 128.0/1 routes come from
// tailscaled itself or the route helper) does not survive a lid close:
// while the link is down INCY can lose the host route to its own server, and
// on wake that traffic follows the /1 routes into Tailscale, whose underlay is
// INCY itself. Nothing recovers from that loop until every client restarts.
// Mirror the manual fix instead: take Tailscale down before sleep, wait after
// wake until the uplink and INCY are back, then bring Tailscale up again.

// iokit_common_msg() is a function-like C macro, which Swift does not import.
private let ioMessageCanSystemSleep: natural_t = 0xE000_0270
private let ioMessageSystemWillSleep: natural_t = 0xE000_0280

/// Holds system sleep until the handler calls `done`, capped well below the
/// 30-second limit macOS enforces for a power-change acknowledgement.
final class SystemSleepObserver {
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private let willSleep: (@escaping () -> Void) -> Void

    init(willSleep: @escaping (@escaping () -> Void) -> Void) {
        self.willSleep = willSleep
    }

    func start() {
        guard rootPort == 0 else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &notifyPort, { refcon, _, message, argument in
            guard let refcon = refcon else { return }
            Unmanaged<SystemSleepObserver>.fromOpaque(refcon).takeUnretainedValue().handle(message, argument)
        }, &notifier)
        guard rootPort != 0, let port = notifyPort else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
    }

    private func handle(_ message: natural_t, _ argument: UnsafeMutableRawPointer?) {
        let notificationID = Int(bitPattern: argument)
        switch message {
        case ioMessageCanSystemSleep:
            IOAllowPowerChange(rootPort, notificationID)
        case ioMessageSystemWillSleep:
            var acknowledged = false
            let allow = { [weak self] in
                guard let self = self, !acknowledged else { return }
                acknowledged = true
                IOAllowPowerChange(self.rootPort, notificationID)
            }
            // Never hold sleep hostage to a hung CLI.
            DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: allow)
            willSleep(allow)
        default:
            break
        }
    }
}

/// What to restore after a sleep-driven (or manual) Tailscale restart.
struct ReconnectSnapshot {
    let prefs: TSPrefs?
    let exitNodeTarget: String?
    let proxyPort: Int?
    var clientTunnel = false
}

func commandOutput(_ path: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// INCY TUN mode uses a fake-IP utun in 198.18.0.0/15; the route helper keys
/// on its 198.18.0.2 address.
func clientTunnelPresent(ifconfig: String) -> Bool {
    var iface = ""
    for line in ifconfig.split(separator: "\n") {
        if let first = line.first, !first.isWhitespace {
            iface = String(line.prefix { $0 != ":" })
            continue
        }
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        if iface.hasPrefix("utun"), fields.count > 1, fields[0] == "inet",
           fields[1].hasPrefix("198.18.") || fields[1].hasPrefix("198.19.") {
            return true
        }
    }
    return false
}

private func netstatRows(_ netstat: String) -> [[Substring]] {
    netstat.split(separator: "\n").map { $0.split(whereSeparator: { $0.isWhitespace }) }.filter { $0.count >= 4 }
}

/// The route helper's IPv4 halves (`0/1`, `128.0/1`) via a utun interface.
func splitDefaultRoutesPresent(netstat: String) -> Bool {
    netstatRows(netstat).contains { ($0[0] == "0/1" || $0[0] == "128.0/1") && $0[3].hasPrefix("utun") }
}

/// A default route (scoped or not) through a non-tunnel interface: the Wi-Fi
/// or Ethernet uplink is back, even while a VPN owns the primary default.
func physicalDefaultRoutePresent(netstat: String) -> Bool {
    netstatRows(netstat).contains { $0[0] == "default" && !$0[3].hasPrefix("utun") }
}

func exitNodeTarget(of status: TSStatus?) -> String? {
    guard let exitID = status?.exitNodeStatus?.ID else { return nil }
    // Peer is keyed by node key, not by the stable ID ExitNodeStatus reports.
    if let peer = status?.peer?.values.first(where: { $0.ID == exitID }), let ip = peer.TailscaleIPs?.first { return ip }
    return exitID
}

/// `up --reset` flattens prefs to Tailscale's defaults: put back what the user had.
func restorePrefsAfterReset(_ prefs: TSPrefs?, exitNodeTarget: String?) {
    // Subnet routes (home/office LANs) should just always be accepted on
    // this device — don't rely on "whatever it was right before this
    // connect" since --reset can itself have already flattened that to
    // false on a prior cycle, which then never recovers. accept-dns and
    // shields-up still follow whatever the user had explicitly set.
    var restoreArgs = ["--accept-routes=true"]
    if let prefs = prefs {
        if prefs.CorpDNS == false { restoreArgs.append("--accept-dns=false") }
        if prefs.ShieldsUp == true { restoreArgs.append("--shields-up=true") }
    }
    runTailscale(["set"] + restoreArgs)

    // `up --reset` intentionally clears the exit-node preference. Restore it
    // after the daemon is running so reconnecting from this UI does not
    // silently turn a full tunnel into a subnet only connection.
    if let target = exitNodeTarget {
        let allowLAN = prefs?.ExitNodeAllowLANAccess == true
        runTailscale(["set", "--exit-node=\(target)", "--exit-node-allow-lan-access=\(allowLAN)"])
    }
}

extension AppDelegate {
    static let reconnectAcrossSleepKey = "reconnectAcrossSleep"

    var reconnectAcrossSleep: Bool {
        get { UserDefaults.standard.object(forKey: AppDelegate.reconnectAcrossSleepKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: AppDelegate.reconnectAcrossSleepKey) }
    }

    func startSleepWakeHandling() {
        let observer = SystemSleepObserver { [weak self] done in
            guard let self = self else { done(); return }
            self.prepareForSleep(done)
        }
        observer.start()
        sleepObserver = observer
        // Full wakes only: a dark wake (Power Nap) leaves the snapshot pending.
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.recoverAfterWake()
            })
    }

    func makeReconnectSnapshot() -> ReconnectSnapshot {
        ReconnectSnapshot(prefs: currentPrefs, exitNodeTarget: exitNodeTarget(of: currentStatus),
                          proxyPort: clientTransport.proxyPort)
    }

    /// Runs `down` and waits for the /1 routes to go (the root route helper
    /// polls every 3 s), so they do not outlive the tunnel. Background thread only.
    func takeTailscaleDown() {
        let helperRoutes = splitDefaultRoutesPresent(netstat: commandOutput("/usr/sbin/netstat", ["-rn", "-f", "inet"]))
        runTailscale(["down"], timeout: 6)
        var waited = 0
        while helperRoutes, waited < 8,
              splitDefaultRoutesPresent(netstat: commandOutput("/usr/sbin/netstat", ["-rn", "-f", "inet"])) {
            Thread.sleep(forTimeInterval: 0.5)
            waited += 1
        }
    }

    func prepareForSleep(_ done: @escaping () -> Void) {
        sleepGeneration += 1
        // A dark wake between two sleeps keeps the snapshot from the first one.
        guard pendingReconnect == nil, reconnectAcrossSleep, !terminating,
              !loginInProgress, !commandInProgress, currentPrefs?.LoggedOut != true,
              currentStatus?.backendState == "Running" else { done(); return }
        pendingReconnect = makeReconnectSnapshot()
        commandInProgress = true
        updateDashboard()
        DispatchQueue.global(qos: .userInitiated).async {
            let tunnel = clientTunnelPresent(ifconfig: commandOutput("/sbin/ifconfig", []))
            self.takeTailscaleDown()
            DispatchQueue.main.async {
                self.pendingReconnect?.clientTunnel = tunnel
                self.commandInProgress = false
                self.updateDashboard()
                done()
            }
        }
    }

    func recoverAfterWake() {
        guard let snapshot = pendingReconnect, !terminating else { return }
        let generation = sleepGeneration
        waitingForUplink = true
        if !trackingMenu { rebuildMenu(status: currentStatus) }
        DispatchQueue.global(qos: .userInitiated).async {
            // Starting Tailscale before Wi-Fi/Ethernet returns recreates the loop
            // this cycle avoids, and only produces a false failure. A hotspot may
            // need a manual join minutes later, so wait without a deadline; a new
            // sleep or the user connecting by hand ends the wait.
            while !physicalDefaultRoutePresent(netstat: commandOutput("/usr/sbin/netstat", ["-rn", "-f", "inet"])) {
                guard self.reconnectStillPending(generation) else { return }
                Thread.sleep(forTimeInterval: 3)
            }
            DispatchQueue.main.async {
                self.waitingForUplink = false
                if !self.trackingMenu { self.rebuildMenu(status: self.currentStatus) }
            }
            self.waitForClient(snapshot, timeout: 45)
            // INCY reconnects to its server only after the link is up.
            Thread.sleep(forTimeInterval: 3)
            self.finishReconnect(snapshot, generation: generation, holdingBusy: false)
        }
    }

    /// Background thread only.
    func reconnectStillPending(_ generation: Int) -> Bool {
        DispatchQueue.main.sync { self.sleepGeneration == generation && self.pendingReconnect != nil && !self.terminating }
    }

    /// Restart Tailscale on demand: the same cycle as sleep/wake, without sleeping.
    @objc func reconnectTailscale(_ sender: Any?) {
        guard pendingReconnect == nil, !commandInProgress, !loginInProgress,
              currentStatus?.backendState == "Running" else { return }
        let snapshot = makeReconnectSnapshot()
        pendingReconnect = snapshot
        commandInProgress = true
        updateDashboard()
        let generation = sleepGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            self.takeTailscaleDown()
            Thread.sleep(forTimeInterval: 2)
            self.finishReconnect(snapshot, generation: generation, holdingBusy: true)
        }
    }

    /// Waits for the INCY TUN / local proxy seen before sleep. Background thread
    /// only. Gives up after `timeout` (the user may have switched modes) and
    /// lets `up` try anyway.
    func waitForClient(_ snapshot: ReconnectSnapshot, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let proxy = snapshot.proxyPort.map { isPortOpen($0) } ?? true
            let tunnel = !snapshot.clientTunnel || clientTunnelPresent(ifconfig: commandOutput("/sbin/ifconfig", []))
            if proxy && tunnel { return }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    /// Background thread only.
    func finishReconnect(_ snapshot: ReconnectSnapshot, generation: Int, holdingBusy: Bool) {
        let proceed = DispatchQueue.main.sync { () -> Bool in
            // Another sleep started: its own wake will resume this snapshot.
            guard self.sleepGeneration == generation, !self.terminating else {
                if holdingBusy { self.commandInProgress = false }
                return false
            }
            // The user connected or logged in meanwhile; their action wins.
            guard holdingBusy || (self.pendingReconnect != nil && !self.loginInProgress && !self.commandInProgress) else {
                self.pendingReconnect = nil
                return false
            }
            self.commandInProgress = true
            self.updateDashboard()
            return true
        }
        guard proceed else { return }

        let result = restoreTailscale(snapshot)

        DispatchQueue.main.async {
            self.pendingReconnect = nil
            self.waitingForUplink = false
            self.commandInProgress = false
            // The outcome notification below replaces the generic connected/disconnected one.
            self.previousBackendState = nil
            self.notifyReconnectOutcome(result, snapshot: snapshot)
            self.refresh()
            // A reconnect can succeed while the network is still broken around it.
            self.scheduleHealthCheck(after: 5)
        }
    }

    /// Brings Tailscale back as in `snapshot` and verifies it, cycling once
    /// more on failure. Background thread only.
    func restoreTailscale(_ snapshot: ReconnectSnapshot) -> (ok: Bool, outcome: String) {
        if fetchStatus()?.backendState == "NeedsLogin" {
            return (false, L("Tailscale needs login. Open Tailbar to sign in."))
        }
        var outcome = ""
        for attempt in 0..<2 {
            if attempt > 0 {
                takeTailscaleDown()
                Thread.sleep(forTimeInterval: 3)
            }
            let result = bringTailscaleUp(restoring: snapshot)
            outcome = result.output
            if result.ok && waitForRunning(timeout: 20) && exitNodeAnswers(snapshot.exitNodeTarget) {
                return (true, outcome)
            }
        }
        return (false, outcome)
    }

    func notifyReconnectOutcome(_ result: (ok: Bool, outcome: String), snapshot: ReconnectSnapshot) {
        if result.ok {
            postNotification(title: L("Tailscale reconnected"), body: snapshot.exitNodeTarget == nil ? nil : L("Exit node restored"))
        } else {
            let detail = result.outcome.trimmingCharacters(in: .whitespacesAndNewlines)
            postNotification(title: L("Couldn't reconnect Tailscale"),
                             body: (detail.isEmpty ? "" : detail + "\n") + L("Check INCY / Happ, then use Repair Network."))
        }
    }

    /// `down` keeps prefs, exit node included, so a bare `up` (which only sets
    /// WantRunning) restores the previous state. Fall back to `up --reset`.
    func bringTailscaleUp(restoring snapshot: ReconnectSnapshot) -> (ok: Bool, output: String) {
        let plain = runTailscale(["up"])
        if plain.exitCode == 0 { return (true, plain.output) }
        let reset = runTailscale(["up", "--reset"])
        guard reset.exitCode == 0 else { return (false, reset.output.isEmpty ? plain.output : reset.output) }
        restorePrefsAfterReset(snapshot.prefs, exitNodeTarget: snapshot.exitNodeTarget)
        return (true, reset.output)
    }

    func waitForRunning(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if fetchStatus()?.backendState == "Running" { return true }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        return false
    }

    /// A tailnet-level ping (DERP counts), not an internet or public-IP check.
    func exitNodeAnswers(_ target: String?) -> Bool {
        guard let target = target, target.contains(".") || target.contains(":") else { return true }
        for _ in 0..<3 {
            if runTailscale(["ping", "-c", "1", "--timeout=5s", "--until-direct=false", target]).exitCode == 0 { return true }
            Thread.sleep(forTimeInterval: 2)
        }
        return false
    }
}
