import AppKit
import CoreWLAN

// MARK: - network health and repair
//
// Moving between networks (a phone hotspot at one place, home Wi-Fi at
// another), quitting INCY / Happ, or switching an exit node off can leave the
// Mac with Wi-Fi connected but no working internet: the unscoped default route
// is gone (both clients and Tailscale's exit-node teardown remove the shared
// /0), a route still points at a dead tunnel, or DNS still points at a resolver
// that has gone away. The manual cure was "quit everything, toggle Wi-Fi".
// Detect those states and apply the same cure automatically, or on demand via
// Repair Network: stop Tailscale, restart Wi-Fi, then restore Tailscale.

enum NetworkProblem: Equatable {
    case noPrimaryRoute
    case deadTunnelRoute(String)
    case staleClientDNS
    case staleTailscaleDNS
    case exitNodeUnreachable
    case noInternet

    var summary: String {
        switch self {
        case .noPrimaryRoute: return L("Wi-Fi is up but there is no default route")
        case .deadTunnelRoute(let iface): return L(format: "Traffic is routed into a dead tunnel (%@)", iface)
        case .staleClientDNS: return L("DNS still points at INCY / Happ, which is not running")
        case .staleTailscaleDNS: return L("DNS still points at Tailscale, which is stopped")
        case .exitNodeUnreachable: return L("The exit node does not answer")
        case .noInternet: return L("No internet although Wi-Fi is up")
        }
    }
}

struct NetworkHealthReport {
    var problems: [NetworkProblem] = []
    var uplink = false
    var checked = false
    var probed = false

    var line: String {
        guard checked else { return L("Network not checked yet") }
        guard uplink else { return L("No Wi-Fi / Ethernet connection") }
        return problems.isEmpty ? L("Network OK") : "⚠ " + problems.map(\.summary).joined(separator: "; ")
    }
}

func routeRows(_ netstat: String) -> [[Substring]] {
    let lines: [Substring] = netstat.split(separator: "\n")
    let rows: [[Substring]] = lines.map { (line: Substring) -> [Substring] in line.split(whereSeparator: { $0.isWhitespace }) }
    return rows.filter { (row: [Substring]) -> Bool in row.count >= 4 }
}

/// Netif of every default route, scoped or not.
func defaultRouteInterfaces(netstat: String) -> [String] {
    var result: [String] = []
    for row in routeRows(netstat) where row[0] == "default" { result.append(String(row[3])) }
    return result
}

/// Interfaces that carry an IPv4 address.
func liveInterfaces(ifconfig: String) -> Set<String> {
    var result = Set<String>()
    var iface = ""
    for line in ifconfig.split(separator: "\n") {
        if let first = line.first, !first.isWhitespace {
            iface = String(line.prefix { $0 != ":" })
            continue
        }
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        if fields.first == "inet" { result.insert(iface) }
    }
    return result
}

/// The first resolver of the default (not scoped) configuration in `scutil --dns`.
func primaryNameserver(scutilDNS: String) -> String? {
    for line in scutilDNS.split(separator: "\n") {
        if line.contains("for scoped queries") { return nil }
        if line.contains("nameserver[0]"), let value = line.components(separatedBy: " : ").last {
            return value.trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

/// Local, side-effect-free checks on routes and DNS. `tailscaleState` is nil
/// when the daemon could not be asked.
func diagnoseNetwork(netstat: String, ifconfig: String, dns: String, tailscaleState: String?) -> [NetworkProblem] {
    let live = liveInterfaces(ifconfig: ifconfig)
    var problems: [NetworkProblem] = []

    var unscopedDefault = false
    var liveHalves = Set<String>()
    var routedInterfaces: [String] = []
    for row in routeRows(netstat) {
        let destination = String(row[0])
        let iface = String(row[3])
        if destination == "default" && !row[2].contains(Character("I")) {
            unscopedDefault = true
            routedInterfaces.append(iface)
        } else if destination == "0/1" || destination == "128.0/1" {
            routedInterfaces.append(iface)
            if live.contains(iface) { liveHalves.insert(destination) }
        }
    }
    if physicalDefaultRoutePresent(netstat: netstat), !unscopedDefault, liveHalves.count < 2 {
        problems.append(.noPrimaryRoute)
    }
    if let dead = routedInterfaces.first(where: { $0.hasPrefix("utun") && !live.contains($0) }) {
        problems.append(.deadTunnelRoute(dead))
    }

    if let server = primaryNameserver(scutilDNS: dns) {
        if (server.hasPrefix("198.18.") || server.hasPrefix("198.19.")) && !clientTunnelPresent(ifconfig: ifconfig) {
            problems.append(.staleClientDNS)
        }
        if server == "100.100.100.100", let state = tailscaleState, !["Running", "Starting"].contains(state) {
            problems.append(.staleTailscaleDNS)
        }
    }
    return problems
}

/// Any HTTP answer, a captive portal included, proves the path works; only a
/// timeout or connection failure counts. macOS probes the same URL itself.
func internetAnswers() -> Bool {
    let code = commandOutput("/usr/bin/curl", ["-s", "-m", "6", "-o", "/dev/null", "-w", "%{http_code}",
                                               "http://captive.apple.com/hotspot-detect.html"])
    return !code.isEmpty && code != "000"
}

extension AppDelegate {
    static let autoRepairNetworkKey = "autoRepairNetwork"

    var autoRepairNetwork: Bool {
        get { UserDefaults.standard.object(forKey: AppDelegate.autoRepairNetworkKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: AppDelegate.autoRepairNetworkKey) }
    }

    var networkBusy: Bool {
        commandInProgress || loginInProgress || pendingReconnect != nil || repairingNetwork
    }

    func startNetworkHealthMonitor() {
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.checkNetworkHealth() }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
        // Quitting or starting INCY / Happ is when routes and DNS get rewritten.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                if id == "llc.itdev.incy" || id == "com.happ.www" { self?.scheduleHealthCheck(after: 5) }
            })
        }
        scheduleHealthCheck(after: 10)
    }

    func scheduleHealthCheck(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.checkNetworkHealth() }
    }

    /// Background thread only. Cheap local checks first; the internet probe
    /// and exit-node ping run only when routes and DNS look sane.
    func evaluateNetworkHealth(probe: Bool = true) -> NetworkHealthReport {
        let netstat = commandOutput("/usr/sbin/netstat", ["-rn", "-f", "inet"])
        let ifconfig = commandOutput("/sbin/ifconfig", [])
        let dns = commandOutput("/usr/sbin/scutil", ["--dns"])
        let status = fetchStatus()
        var report = NetworkHealthReport(checked: true)
        report.uplink = physicalDefaultRoutePresent(netstat: netstat)
        guard report.uplink else { return report }
        report.problems = diagnoseNetwork(netstat: netstat, ifconfig: ifconfig, dns: dns, tailscaleState: status?.backendState)
        report.probed = probe
        if probe, report.problems.isEmpty, !internetAnswers(), !internetAnswers() {
            let target = status?.backendState == "Running" ? exitNodeTarget(of: status) : nil
            let stuckExit = target != nil && !exitNodeAnswers(target)
            report.problems.append(stuckExit ? NetworkProblem.exitNodeUnreachable : NetworkProblem.noInternet)
        }
        return report
    }

    func checkNetworkHealth() {
        guard !healthCheckRunning, !terminating, !networkBusy else { return }
        healthCheckRunning = true
        // Routes and DNS are checked every time; the internet probe at most once
        // a minute, unless it is confirming a problem already seen.
        let probe = problemSince != nil || Date().timeIntervalSince(lastInternetProbe) >= 60
        if probe { lastInternetProbe = Date() }
        DispatchQueue.global(qos: .utility).async {
            let report = self.evaluateNetworkHealth(probe: probe)
            DispatchQueue.main.async {
                self.healthCheckRunning = false
                self.handleHealthReport(report)
            }
        }
    }

    func handleHealthReport(_ fresh: NetworkHealthReport) {
        var report = fresh
        // A check that skipped the internet probe cannot clear a failed probe;
        // otherwise it would also reset the automatic-repair limit.
        if !report.probed, report.uplink, report.problems.isEmpty {
            report.problems = networkHealth.problems.filter { (problem: NetworkProblem) -> Bool in
                problem == .noInternet || problem == .exitNodeUnreachable
            }
        }
        let changed = report.line != networkHealth.line
        networkHealth = report
        if changed {
            updateDashboard()
            if !trackingMenu { rebuildMenu(status: currentStatus) }
        }
        guard !report.problems.isEmpty else {
            problemSince = nil
            autoRepairAttempts = 0
            repairGaveUpNotified = false
            return
        }
        guard autoRepairNetwork, !networkBusy, !terminating else { return }
        // Routes and DNS settle for a few seconds after every change: act only
        // on a problem that is still there on a second look.
        guard let since = problemSince else {
            problemSince = Date()
            scheduleHealthCheck(after: 10)
            return
        }
        guard Date().timeIntervalSince(since) >= 10 else { return }
        guard autoRepairAttempts < 2 else {
            if !repairGaveUpNotified {
                repairGaveUpNotified = true
                postNotification(title: L("Network still broken"),
                                 body: report.problems.map(\.summary).joined(separator: "\n") + "\n" + L("Automatic repair stopped. Check INCY / Happ and the exit node, then use Repair Network."))
            }
            return
        }
        if let last = lastAutoRepair, Date().timeIntervalSince(last) < 120 { return }
        autoRepairAttempts += 1
        lastAutoRepair = Date()
        if report.problems == [.exitNodeUnreachable] {
            // Routes and DNS are fine; only the tunnel to the exit node is stuck.
            reconnectTailscale(nil)
        } else {
            startNetworkRepair(automatic: true)
        }
    }

    @objc func repairNetwork(_ sender: Any?) {
        startNetworkRepair(automatic: false)
    }

    /// The manual cure, automated: stop Tailscale, restart Wi-Fi, wait for the
    /// uplink and INCY / Happ, then restore Tailscale as it was.
    func startNetworkRepair(automatic: Bool) {
        guard !networkBusy, !terminating else { return }
        let wasRunning = currentStatus?.backendState == "Running" && currentPrefs?.LoggedOut != true
        let before = wasRunning ? makeReconnectSnapshot() : nil
        let problems = networkHealth.problems
        repairingNetwork = true
        commandInProgress = true
        updateDashboard()
        if !trackingMenu { rebuildMenu(status: currentStatus) }
        DispatchQueue.global(qos: .userInitiated).async {
            var snapshot = before
            snapshot?.clientTunnel = clientTunnelPresent(ifconfig: commandOutput("/sbin/ifconfig", []))
            if wasRunning { self.takeTailscaleDown() }
            let cycled = self.restartWiFi()
            var uplink = false
            for _ in 0..<30 {
                if physicalDefaultRoutePresent(netstat: commandOutput("/usr/sbin/netstat", ["-rn", "-f", "inet"])) { uplink = true; break }
                Thread.sleep(forTimeInterval: 2)
            }
            if !uplink {
                // E.g. a phone hotspot that macOS does not rejoin by itself:
                // hand over to the wake path, which waits for Wi-Fi indefinitely.
                DispatchQueue.main.async {
                    self.repairingNetwork = false
                    self.commandInProgress = false
                    self.postNotification(title: L("Waiting for Wi-Fi"), body: L("Wi-Fi was restarted but has not reconnected. Join your network; Tailscale will follow."))
                    if let snapshot = snapshot {
                        self.pendingReconnect = snapshot
                        self.recoverAfterWake()
                    } else {
                        self.updateDashboard()
                        self.refresh()
                    }
                }
                return
            }
            var restored: (ok: Bool, outcome: String)?
            if let snapshot = snapshot {
                self.waitForClient(snapshot, timeout: 45)
                Thread.sleep(forTimeInterval: 3)
                restored = self.restoreTailscale(snapshot)
            } else {
                Thread.sleep(forTimeInterval: 3)
            }
            let after = self.evaluateNetworkHealth()
            DispatchQueue.main.async {
                self.repairingNetwork = false
                self.commandInProgress = false
                self.previousBackendState = nil
                self.networkHealth = after
                if after.problems.isEmpty {
                    self.problemSince = nil
                    self.autoRepairAttempts = 0
                    var body = cycled ? L("Wi-Fi restarted") : L("Wi-Fi could not be restarted by the app")
                    if let restored = restored {
                        body += "; " + (restored.ok ? L("Tailscale reconnected") : L(format: "Tailscale did not come back: %@", restored.outcome.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                    self.postNotification(title: L("Network repaired"), body: body)
                } else if !automatic || self.autoRepairAttempts >= 2 {
                    self.repairGaveUpNotified = true
                    var body = after.problems.map(\.summary).joined(separator: "\n")
                    if !cycled { body += "\n" + L("The app could not restart Wi-Fi; turn it off and on in Control Center.") }
                    if problems.contains(.staleClientDNS) || after.problems.contains(.staleClientDNS) {
                        body += "\n" + L("If INCY / Happ was force-quit, start it and quit it normally.")
                    }
                    self.postNotification(title: L("Network still broken"), body: body)
                }
                self.updateDashboard()
                self.refresh()
            }
        }
    }

    /// Restarts Wi-Fi when it is the uplink (or no uplink is up at all).
    /// Background thread only. Returns false when Wi-Fi was not restarted.
    func restartWiFi() -> Bool {
        guard let wifi = CWWiFiClient.shared().interface(), let name = wifi.interfaceName, wifi.powerOn() else { return false }
        let uplinks = defaultRouteInterfaces(netstat: commandOutput("/usr/sbin/netstat", ["-rn", "-f", "inet"]))
            .filter { !$0.hasPrefix("utun") }
        // An Ethernet uplink is not ours to bounce; Wi-Fi is merely idle then.
        guard uplinks.isEmpty || uplinks.contains(name) else { return false }
        do {
            try wifi.setPower(false)
            Thread.sleep(forTimeInterval: 2)
            try wifi.setPower(true)
            return true
        } catch {
            // CoreWLAN refused (e.g. "Require administrator authorization" for
            // Wi-Fi power); try the command-line route once.
            _ = commandOutput("/usr/sbin/networksetup", ["-setairportpower", name, "off"])
            Thread.sleep(forTimeInterval: 2)
            let wentOff = !wifi.powerOn()
            _ = commandOutput("/usr/sbin/networksetup", ["-setairportpower", name, "on"])
            // Never leave Wi-Fi off, whatever failed above.
            if !wifi.powerOn() { try? wifi.setPower(true) }
            return wentOff && wifi.powerOn()
        }
    }
}
