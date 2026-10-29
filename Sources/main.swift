import AppKit
import Foundation
import ServiceManagement
import UserNotifications

let tailscaleBin = "/opt/homebrew/opt/tailscale/bin/tailscale"
let tailscaleSocket = "/var/run/tailscaled.socket"

// MARK: - status --json model

struct TSSelf: Decodable {
    let UserID: Int64?
    let TailscaleIPs: [String]?
    let DNSName: String?
    let Online: Bool?
}

struct TSPeer: Decodable {
    let UserID: Int64?
    let ID: String?
    let HostName: String?
    let DNSName: String?
    let TailscaleIPs: [String]?
    let Online: Bool?
    let LastSeen: String?
    let Relay: String?
    let ExitNodeOption: Bool?
    let OS: String?
    let Tags: [String]?
    let RxBytes: Int64?
    let TxBytes: Int64?
}

struct TSExitNodeStatus: Decodable {
    let ID: String?
    let Online: Bool?
}

/// Tailbar's own status glyph, drawn in code: a 3×3 dot grid whose lit dots
/// form a bridge (deck = middle row, piers = bottom corners). Indices are
/// row-major with row 0 at the top. No third-party artwork or logo geometry.
enum TailbarGlyph {
    static let bridge: Set<Int> = [3, 4, 5, 6, 8]
    /// Top centre: traffic leaves through an exit node.
    static let exitMast = 1
    /// Health warning: the centre of the deck is drawn as a ring.
    static let warningSpot = 4
    /// The connecting animation builds the bridge pier to pier, then clears it
    /// from the first pier, always leaving at least one dot lit.
    static let buildOrder = [6, 3, 4, 5, 8]
    static var frameCount: Int { buildOrder.count * 2 - 1 }

    static func connectingFrame(_ frame: Int) -> Set<Int> {
        let step = frame % frameCount
        let order = buildOrder
        return step < order.count ? Set(order[...step]) : Set(order[(step - order.count + 1)...])
    }
}

struct TSTailnet: Decodable {
    let Name: String?
}

struct TSStatus: Decodable {
    var backendState: String?
    let selfNode: TSSelf?
    let peer: [String: TSPeer]?
    let exitNodeStatus: TSExitNodeStatus?
    let currentTailnet: TSTailnet?
    let user: [String: TSUser]?
    let health: [String]?
    let authURL: String?

    enum CodingKeys: String, CodingKey {
        case backendState = "BackendState"
        case selfNode = "Self"
        case peer = "Peer"
        case exitNodeStatus = "ExitNodeStatus"
        case currentTailnet = "CurrentTailnet"
        case user = "User"
        case health = "Health"
        case authURL = "AuthURL"
    }
}

struct TSUser: Decodable {
    let LoginName: String?
    let DisplayName: String?
}

// MARK: - debug prefs model (undocumented but stable enough for local UI state)

struct TSPrefs: Decodable {
    let ExitNodeID: String?
    let ExitNodeAllowLANAccess: Bool?
    let AdvertiseRoutes: [String]?
    let RouteAll: Bool?
    let CorpDNS: Bool?
    let ShieldsUp: Bool?
    let WantRunning: Bool?
    let LoggedOut: Bool?
}

func fetchPrefs() -> TSPrefs? {
    let (output, _) = runTailscale(["debug", "prefs"])
    guard let data = output.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(TSPrefs.self, from: data)
}

struct TSProfile: Decodable {
    let id: String
    let account: String
    let tailnet: String
    let selected: Bool
}

func fetchProfiles() -> [TSProfile] {
    let (output, _) = runTailscale(["switch", "--list", "--json"])
    guard let data = output.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([TSProfile].self, from: data)) ?? []
}

func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var idx = 0
    while value >= 1024 && idx < units.count - 1 {
        value /= 1024
        idx += 1
    }
    return String(format: idx == 0 ? "%.0f %@" : "%.1f %@", value, units[idx])
}

// MARK: - CLI helper

@discardableResult
func runTailscale(_ args: [String], timeout: TimeInterval? = nil) -> (output: String, exitCode: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tailscaleBin)
    // There is also an official Tailscale Network Extension installed on
    // this Mac. Pin this UI to the Homebrew daemon it is designed to manage;
    // otherwise the CLI can discover the other installation and the menu
    // falls back to "Unknown" or controls a different node identity.
    process.arguments = ["--socket=\(tailscaleSocket)"] + args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return ("", -1)
    }
    let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    deadline.schedule(deadline: .now() + (timeout ?? (args.first == "up" ? 120 : 12)))
    deadline.setEventHandler { if process.isRunning { process.terminate() } }
    deadline.resume()
    defer { deadline.cancel() }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(data: data, encoding: .utf8) ?? ""
    return (output, process.terminationStatus)
}

func fetchStatus() -> TSStatus? {
    // tailscale exits 1 when the daemon is stopped but still prints useful
    // JSON, and status --json returns a stale cached peer list when the
    // daemon is down — callers must gate on backendState, not exit code.
    let (output, _) = runTailscale(["status", "--json"])
    guard let data = output.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(TSStatus.self, from: data)
}

// MARK: - formatting helpers

func displayName(dnsName: String?, fallback: String) -> String {
    guard let dnsName = dnsName, !dnsName.isEmpty else { return fallback }
    let trimmed = dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
    return trimmed.components(separatedBy: ".").first ?? trimmed
}

func relativeLastSeen(_ iso: String?) -> String {
    guard let iso = iso else { return "" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = formatter.date(from: iso)
    if date == nil {
        formatter.formatOptions = [.withInternetDateTime]
        date = formatter.date(from: iso)
    }
    guard let date = date else { return "" }
    let interval = -date.timeIntervalSinceNow
    if interval < 60 { return L("seen just now") }
    if interval < 3600 { return L(format: "seen %ldm ago", Int(interval / 60)) }
    if interval < 86400 { return L(format: "seen %ldh ago", Int(interval / 3600)) }
    return L(format: "seen %ldd ago", Int(interval / 86400))
}

// MARK: - app delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var currentStatus: TSStatus?
    var currentPrefs: TSPrefs?
    var currentProfiles: [TSProfile] = []
    var refreshing = false
    var previousBackendState: String?
    var previousExitNodeID: String?
    var proxyStatus = L("Checking…")
    var clientTransport = ClientTransportStatus()
    var transportDot: TransportDotView?
    var workspaceObservers: [NSObjectProtocol] = []
    var routeStatus = L("Route not checked yet")
    var dashboard: DashboardController?
    var eventProcess: Process?
    var eventPipe: Pipe?
    var eventParser = JSONObjectStream()
    var eventRefresh: DispatchWorkItem?
    var terminating = false
    var refreshAgain = false
    var stateRevision = 0
    var trackingMenu = false
    var commandInProgress = false
    var animationTimer: Timer?
    var animationFrame = 0
    var loginInProgress = false
    var sleepObserver: SystemSleepObserver?
    /// Set while Tailscale is down for a sleep/wake or manual reconnect cycle.
    var pendingReconnect: ReconnectSnapshot?
    var waitingForUplink = false
    var healthTimer: Timer?
    var healthCheckRunning = false
    var networkHealth = NetworkHealthReport()
    var problemSince: Date?
    var autoRepairAttempts = 0
    var lastAutoRepair: Date?
    var repairGaveUpNotified = false
    var repairingNetwork = false
    var lastInternetProbe = Date.distantPast
    var sleepGeneration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = matrixIcon(.dim)
        statusItem.button?.image?.isTemplate = true
        if let button = statusItem.button {
            let dot = TransportDotView(frame: button.bounds)
            dot.autoresizingMask = [.width, .height]
            button.addSubview(dot)
            transportDot = dot
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

        // The menu-bar app is only a UI. Do not change the daemon state when
        // the UI launches: this would disconnect an already-working VPN and
        // discard an active exit node every time the app is restarted.
        refresh()
        startEventWatcher()
        timer = Timer(timeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)
        buildApplicationMenu()
        startSleepWakeHandling()
        startNetworkHealthMonitor()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        // Cold launch is menu-bar only. A subsequent Dock/open event is
        // handled by applicationShouldHandleReopen and presents the window.
    }

    func menuWillOpen(_ menu: NSMenu) {
        trackingMenu = true
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        trackingMenu = false
        rebuildMenu(status: currentStatus)
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for entry in menu.items {
            (entry.view as? MenuConnectionHeader)?.setMenuHighlighted(entry === item)
        }
    }

    func refresh() {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        let revision = stateRevision
        let clients = ClientTransportStatus.runningClientsNow()
        DispatchQueue.global(qos: .userInitiated).async {
            let status = fetchStatus()
            let prefs = fetchPrefs()
            let profiles = fetchProfiles()
            let port = [10808, 10809, 10820].first { self.isPortOpen($0) }
            let proxy = port.map { "\($0 == 10808 ? "INCY" : "Happ") · 127.0.0.1:\($0)" } ?? L("not detected")
            let route = self.readRouteStatus(status)
            DispatchQueue.main.async {
                if self.stateRevision != revision {
                    self.refreshing = false
                    self.refreshAgain = false
                    self.refresh()
                    return
                }
                self.notifyOnChanges(newStatus: status)
                self.currentStatus = status
                self.currentPrefs = prefs
                self.currentProfiles = profiles
                self.proxyStatus = proxy
                self.clientTransport = ClientTransportStatus(runningClients: clients, proxyPort: port, checked: true)
                self.routeStatus = route
                if !self.trackingMenu { self.rebuildMenu(status: status) }
                self.applyIconUpdate(status: status)
                self.updateDashboard()
                self.refreshing = false
                if self.refreshAgain { self.refreshAgain = false; self.refresh() }
            }
        }
    }

    // MARK: icon — see TailbarGlyph. An 18×18 template image: dot centres at
    // 3.6 / 9 / 14.4 pt, radius 1.8 pt; unlit dots at 40 % opacity.

    enum MatrixState {
        case dim
        case connected
        case exitNode(online: Bool)
        case warning
        case wave(frame: Int)
    }

    func matrixIcon(_ state: MatrixState) -> NSImage {
        var lit = Set<Int>()
        var ring: Int?
        switch state {
        case .dim:
            break
        case .connected:
            lit = TailbarGlyph.bridge
        case .exitNode(let online):
            lit = TailbarGlyph.bridge
            if online { lit.insert(TailbarGlyph.exitMast) } else { ring = TailbarGlyph.exitMast }
        case .warning:
            lit = TailbarGlyph.bridge.subtracting([TailbarGlyph.warningSpot])
            ring = TailbarGlyph.warningSpot
        case .wave(let frame):
            lit = TailbarGlyph.connectingFrame(frame)
        }

        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let radius: CGFloat = 1.8
            for index in 0..<9 {
                let center = NSPoint(x: 3.6 + CGFloat(index % 3) * 5.4, y: 14.4 - CGFloat(index / 3) * 5.4)
                let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                if index == ring {
                    NSColor.black.setStroke()
                    let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                    path.lineWidth = 1
                    path.stroke()
                } else {
                    NSColor.black.withAlphaComponent(lit.contains(index) ? 1 : 0.4).setFill()
                    NSBezierPath(ovalIn: rect).fill()
                }
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    func updateIcon(status: TSStatus?) {
        guard let button = statusItem.button else { return }

        var base: NSImage
        var description: String

        if let status = status, let state = status.backendState {
            switch state {
            case "Running":
                if status.exitNodeStatus?.ID != nil {
                    let online = status.exitNodeStatus?.Online ?? true
                    base = matrixIcon(.exitNode(online: online))
                    description = online ? L("Tailscale: connected, exit node active") : L("Tailscale: exit node unreachable")
                } else {
                    base = matrixIcon(.connected)
                    description = L("Tailscale: connected")
                }
                stopAnimating()
            case "Starting":
                startAnimatingIfNeeded()
                base = matrixIcon(.wave(frame: animationFrame))
                description = L("Tailscale: connecting…")
            default:
                // Stopped, NeedsLogin, NoState, ...: all shown as disconnected;
                // the tooltip and menu say which.
                base = matrixIcon(.dim)
                description = state == "NeedsLogin" ? L("Tailscale: needs login") : L("Tailscale: disconnected")
                stopAnimating()
            }
        } else {
            base = matrixIcon(.dim)
            description = L("Tailscale: unknown")
            stopAnimating()
        }

        // "Health" always includes routine status lines like "Tailscale is
        // stopped." while disconnected — only surface it as a warning when
        // we're otherwise Running but something's actually wrong (e.g. a
        // relay is unreachable).
        if status?.backendState == "Running", let health = status?.health, !health.isEmpty {
            description += " — " + (health.count == 1 ? L(format: "%ld health warning", health.count) : L(format: "%ld health warnings", health.count))
            base = matrixIcon(.warning)
        }

        base.isTemplate = true
        base.accessibilityDescription = description
        button.image = base
        transportDot?.indicator = clientTransport.indicator
        button.toolTip = description + "\n" + clientTransport.menuSummary
    }

    // Never hold a stale connecting state for a cosmetic minimum duration.
    func applyIconUpdate(status: TSStatus?) {
        updateIcon(status: status)
    }

    // Redraws the current wave frame directly, without re-deriving state from
    // (possibly stale) currentStatus. Only refresh()'s call to updateIcon —
    // which has genuinely fresh status — is allowed to stop the animation;
    // if the timer tick also re-evaluated stale status it could see a
    // pre-click "Stopped" and call stopAnimating() before a single frame
    // had a chance to show, which is exactly what was happening before.
    func renderWaveFrame() {
        guard let button = statusItem.button else { return }
        let icon = matrixIcon(.wave(frame: animationFrame))
        icon.isTemplate = true
        icon.accessibilityDescription = L("Tailscale: connecting…")
        button.image = icon
    }

    func startAnimatingIfNeeded() {
        guard animationTimer == nil else { return }
        renderWaveFrame()
        animationTimer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.animationFrame = (self.animationFrame + 1) % TailbarGlyph.frameCount
            self.renderWaveFrame()
        }
        RunLoop.main.add(animationTimer!, forMode: .common)
    }

    func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationFrame = 0
    }

    // MARK: menu

    func rebuildMenu(status: TSStatus?) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let state = currentPrefs?.LoggedOut == true ? "NeedsLogin" : (status?.backendState ?? "Unknown")
        let busy = loginInProgress || commandInProgress
        let title = busy ? L("Updating…") : (["Running": L("Connected"), "Stopped": L("Disconnected"), "Starting": L("Connecting…"), "NeedsLogin": L("Needs login"), "Unknown": L("Unknown")][state] ?? state)
        let header = NSMenuItem()
        header.view = MenuConnectionHeader(state: title, connected: state == "Running",
            enabled: !busy && ["Running", "Stopped", "NeedsLogin"].contains(state)) { [weak self, weak menu] in
                menu?.cancelTracking()
                guard let self = self else { return }
                if state == "NeedsLogin" { self.startConnectOrLogin() }
                else { self.toggleConnection(NSMenuItem()) }
            }
        menu.addItem(header)
        menu.addItem(.separator())

        let accountName = currentProfiles.first(where: { $0.selected })?.account ?? status?.currentTailnet?.Name ?? L("Account")
        let account = NSMenuItem(title: accountName, action: nil, keyEquivalent: "")
        let accountTitle = NSMutableAttributedString(string: accountName + "\n", attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium)])
        accountTitle.append(NSAttributedString(string: status?.currentTailnet?.Name ?? L("Account"), attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
        account.attributedTitle = accountTitle
        account.image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor(white: 0.16, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        account.submenu = buildAccountMenu()
        menu.addItem(account)
        menu.addItem(.separator())

        if let me = status?.selfNode, let ip = me.TailscaleIPs?.first {
            let name = displayName(dnsName: me.DNSName, fallback: L("This Mac"))
            let device = NSMenuItem(title: L(format: "This Device: %@ (%@)", name, ip), action: #selector(copyToClipboard(_:)), keyEquivalent: "")
            device.target = self
            device.representedObject = ip
            device.toolTip = L("Copy this device's Tailscale address")
            menu.addItem(device)
        }
        let network = NSMenuItem(title: L("Network Devices"), action: nil, keyEquivalent: "")
        let devices = NSMenu()
        let peers = status?.peer?.values.sorted {
            displayName(dnsName: $0.DNSName, fallback: $0.HostName ?? "") <
            displayName(dnsName: $1.DNSName, fallback: $1.HostName ?? "")
        } ?? []
        for peer in peers { devices.addItem(peerMenuItem(peer)) }
        network.submenu = devices
        network.isEnabled = state == "Running" && !peers.isEmpty
        menu.addItem(network)
        menu.addItem(.separator())

        let exit = NSMenuItem(title: L("Exit Nodes"), action: nil, keyEquivalent: "")
        exit.submenu = buildExitNodeMenu(status: status)
        exit.isEnabled = state == "Running" && !busy
        menu.addItem(exit)
        if !networkHealth.problems.isEmpty && !repairingNetwork {
            let warning = NSMenuItem(title: networkHealth.line, action: #selector(repairNetwork(_:)), keyEquivalent: "")
            warning.target = self
            warning.isEnabled = !busy && pendingReconnect == nil
            warning.toolTip = L("Click to repair: stop Tailscale, restart Wi-Fi, reconnect")
            menu.addItem(warning)
        }
        if repairingNetwork {
            let repairing = NSMenuItem(title: L("Repairing network…"), action: nil, keyEquivalent: "")
            repairing.isEnabled = false
            menu.addItem(repairing)
        } else if pendingReconnect != nil {
            let title = waitingForUplink ? L("Tailscale reconnects when Wi-Fi is back") : L("Reconnecting Tailscale…")
            let waiting = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            waiting.isEnabled = false
            menu.addItem(waiting)
        } else {
            let reconnect = NSMenuItem(title: L("Reconnect Tailscale"), action: #selector(reconnectTailscale(_:)), keyEquivalent: "")
            reconnect.target = self
            reconnect.isEnabled = state == "Running" && !busy
            reconnect.toolTip = L("Disconnect, wait for the network and INCY / Happ, then connect again")
            menu.addItem(reconnect)
            let repair = NSMenuItem(title: L("Repair Network"), action: #selector(repairNetwork(_:)), keyEquivalent: "")
            repair.target = self
            repair.isEnabled = !busy
            repair.toolTip = L("Stop Tailscale, restart Wi-Fi, wait for INCY / Happ, then restore Tailscale")
            menu.addItem(repair)
        }
        menu.addItem(.separator())
        let transport = NSMenuItem(title: clientTransport.menuSummary, action: nil, keyEquivalent: "")
        transport.isEnabled = false
        transport.toolTip = clientTransport.explanation
        menu.addItem(transport)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: L("Settings…"), action: #selector(showSettingsWindow(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let open = NSMenuItem(title: L("Open Tailbar"), action: #selector(showDashboard(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quit"), action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self
        quit.toolTip = L("Quit the interface; VPN stays active")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    func buildAccountMenu() -> NSMenu {
        let menu = buildSwitchAccountMenu()
        menu.addItem(.separator())
        let admin = NSMenuItem(title: L("Admin console…"), action: #selector(openAdminConsole), keyEquivalent: "")
        admin.target = self
        menu.addItem(admin)
        let logout = NSMenuItem(title: L("Log out"), action: #selector(logOut), keyEquivalent: "")
        logout.target = self
        menu.addItem(logout)
        return menu
    }

    func buildSwitchAccountMenu() -> NSMenu {
        let submenu = NSMenu()
        if currentProfiles.isEmpty {
            let item = NSMenuItem(title: L("(unavailable)"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
            return submenu
        }
        for profile in currentProfiles {
            let item = NSMenuItem(title: "\(profile.account) — \(profile.tailnet)", action: #selector(switchAccount(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            item.state = profile.selected ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    func buildExitNodeMenu(status: TSStatus?) -> NSMenu {
        let submenu = NSMenu()
        let activeID = status?.exitNodeStatus?.ID

        let noneItem = NSMenuItem(title: L("None"), action: #selector(selectExitNode(_:)), keyEquivalent: "")
        noneItem.target = self
        noneItem.representedObject = ""
        noneItem.state = (activeID == nil) ? .on : .off
        submenu.addItem(noneItem)

        let allPeers: [TSPeer] = status?.peer.map { Array($0.values) } ?? []
        let candidates = allPeers.filter { $0.ExitNodeOption == true }
            .sorted { displayName(dnsName: $0.DNSName, fallback: $0.HostName ?? "") < displayName(dnsName: $1.DNSName, fallback: $1.HostName ?? "") }

        if !candidates.isEmpty {
            submenu.addItem(NSMenuItem.separator())
            for peer in candidates {
                let name = displayName(dnsName: peer.DNSName, fallback: peer.HostName ?? L("unknown"))
                let item = NSMenuItem(title: name, action: #selector(selectExitNode(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = peer.TailscaleIPs?.first ?? ""
                item.state = (peer.ID != nil && peer.ID == activeID) ? .on : .off
                submenu.addItem(item)
            }
        }

        submenu.addItem(NSMenuItem.separator())

        let allowLAN = NSMenuItem(title: L("Allow local network access"), action: #selector(toggleAllowLAN(_:)), keyEquivalent: "")
        allowLAN.target = self
        allowLAN.state = (currentPrefs?.ExitNodeAllowLANAccess == true) ? .on : .off
        submenu.addItem(allowLAN)

        let advertise = NSMenuItem(title: L("Run this device as exit node"), action: #selector(toggleAdvertiseExitNode(_:)), keyEquivalent: "")
        advertise.target = self
        advertise.state = (currentPrefs?.AdvertiseRoutes?.contains("0.0.0.0/0") == true) ? .on : .off
        submenu.addItem(advertise)

        return submenu
    }

    func isPortOpen(_ port: Int) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-z", "-w1", "127.0.0.1", "\(port)"]
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    func peerMenuItem(_ peer: TSPeer) -> NSMenuItem {
        let name = displayName(dnsName: peer.DNSName, fallback: peer.HostName ?? L("unknown"))
        let online = peer.Online == true
        let dot = online ? "●" : "○"
        let osTag = peer.OS.map { " [\($0)]" } ?? ""
        let title = "\(dot) \(name)\(osTag)"

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let statusLine = NSMenuItem(title: online ? L("Online") : relativeLastSeen(peer.LastSeen), action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        submenu.addItem(statusLine)

        if let ip = peer.TailscaleIPs?.first {
            let ipLine = NSMenuItem(title: ip, action: nil, keyEquivalent: "")
            ipLine.isEnabled = false
            submenu.addItem(ipLine)
        }

        if let relay = peer.Relay, !relay.isEmpty {
            let relayItem = NSMenuItem(title: L(format: "Relay: %@", relay), action: nil, keyEquivalent: "")
            relayItem.isEnabled = false
            submenu.addItem(relayItem)
        }

        if let tx = peer.TxBytes, let rx = peer.RxBytes, tx + rx > 0 {
            let trafficItem = NSMenuItem(title: "↑ \(formatBytes(tx))   ↓ \(formatBytes(rx))", action: nil, keyEquivalent: "")
            trafficItem.isEnabled = false
            submenu.addItem(trafficItem)
        }

        submenu.addItem(NSMenuItem.separator())

        if let ip = peer.TailscaleIPs?.first {
            let copyIP = NSMenuItem(title: L("Copy IP"), action: #selector(copyToClipboard(_:)), keyEquivalent: "")
            copyIP.target = self
            copyIP.representedObject = ip
            submenu.addItem(copyIP)

            let pingItem = NSMenuItem(title: L("Ping"), action: #selector(pingPeer(_:)), keyEquivalent: "")
            pingItem.target = self
            pingItem.representedObject = ip
            submenu.addItem(pingItem)

            let openItem = NSMenuItem(title: L("Open in browser"), action: #selector(openInBrowser(_:)), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = ip
            submenu.addItem(openItem)

            let sendFileItem = NSMenuItem(title: L("Send file…"), action: #selector(sendFileToPeer(_:)), keyEquivalent: "")
            sendFileItem.target = self
            sendFileItem.representedObject = ip
            submenu.addItem(sendFileItem)
        }

        if let dnsName = peer.DNSName, !dnsName.isEmpty {
            let copyDNS = NSMenuItem(title: L("Copy DNS name"), action: #selector(copyToClipboard(_:)), keyEquivalent: "")
            copyDNS.target = self
            copyDNS.representedObject = dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
            submenu.addItem(copyDNS)
        }

        item.submenu = submenu
        return item
    }

    // MARK: actions

    @objc func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    @objc func toggleConnection(_ sender: NSMenuItem) {
        guard !commandInProgress && !loginInProgress else { return }
        let isRunning = currentStatus?.backendState == "Running"
        if isRunning {
            commandInProgress = true
            updateDashboard()
            DispatchQueue.global(qos: .userInitiated).async {
                let (output, code) = runTailscale(["down"])
                DispatchQueue.main.async {
                    self.commandInProgress = false
                    if code != 0 { self.showConnectError(output) }
                    self.refresh()
                }
            }
        } else {
            startConnectOrLogin()
        }
    }

    // Shared by the Connect toggles, which also sign in when needed. Guards
    // against firing a second `tailscale up --reset` while one is already
    // in flight: each `up` call cancels any previous one still waiting on
    // browser auth (surfaces as "context canceled" / a fresh AuthURL each
    // time), so a second click while mid-login was silently restarting the
    // login instead of completing it. If a login is already in progress,
    // just re-open whatever AuthURL is currently pending.
    func startConnectOrLogin() {
        if loginInProgress {
            DispatchQueue.global(qos: .userInitiated).async {
                if let status = fetchStatus(), let urlString = status.authURL, !urlString.isEmpty, let url = URL(string: urlString) {
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
            }
            return
        }
        // Connecting by hand ends a pending sleep/wake reconnect.
        pendingReconnect = nil

        // The wrapper automatically prefers a local proxy when present and
        // unsets HTTP(S)_PROXY when none is available. Absence is not an error:
        // direct access works on ordinary networks. Let tailscaled verify it.
        loginInProgress = true
        updateDashboard()
        // Cached state only on the main thread. All CLI/network work is below.
        let prefsBefore = currentPrefs
        let statusBefore = currentStatus
        let exitNodeTargetBefore = exitNodeTarget(of: statusBefore)
        DispatchQueue.global(qos: .userInitiated).async {
            let detectedPort = [10808, 10809, 10820].first { self.isPortOpen($0) }
            DispatchQueue.global(qos: .userInitiated).async { self.pollAndOpenAuthURL() }
            // bare "up" fails with "requires mentioning all non-default
            // flags" whenever persisted prefs (accept-routes, exit-node
            // LAN access, ...) differ from tailscale's own defaults —
            // which they usually do, since Settings and the exit-node menu
            // set them via `tailscale set`. --reset sidesteps that instead
            // of silently failing, but it also resets those prefs to
            // tailscale's own defaults (accept-routes off, accept-dns on,
            // shields-up off) — restore whatever the user had before, so
            // every Connect/Log in doesn't quietly drop subnet routing etc.
            let (output, code) = runTailscale(["up", "--reset"])
            if code != 0 {
                let hint = detectedPort == nil ? "\n\n" + L("Connecting without a local proxy failed. If your network blocks Tailscale, start INCY or Happ and connect again.") : ""
                DispatchQueue.main.async { self.showConnectError(output + hint) }
            } else {
                restorePrefsAfterReset(prefsBefore, exitNodeTarget: exitNodeTargetBefore)
            }
            DispatchQueue.main.async {
                self.loginInProgress = false
                self.refresh()
            }
        }
    }

    func showConnectError(_ output: String) {
        let alert = NSAlert()
        alert.messageText = L("Couldn't connect")
        alert.informativeText = output.isEmpty ? L("tailscale up failed with no output.") : output
        alert.alertStyle = .warning
        alert.runModal()
    }

    // `tailscale up` obtains a login URL from the control server but, unlike
    // running it in an interactive terminal, doesn't reliably auto-open it
    // in a browser when invoked from a plain Process() like ours. Poll
    // status for a few seconds and open it ourselves as soon as it appears.
    func pollAndOpenAuthURL() {
        var openedURL: String?
        for _ in 0..<24 {
            if let status = fetchStatus(), let urlString = status.authURL, !urlString.isEmpty {
                if openedURL != urlString, let url = URL(string: urlString) {
                    openedURL = urlString
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
            } else if openedURL != nil {
                return // AuthURL cleared — login completed (or cancelled)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    @objc func switchAccount(_ sender: NSMenuItem) {
        guard let profileID = sender.representedObject as? String else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            runTailscale(["switch", profileID])
            DispatchQueue.main.async { self.refresh() }
        }
    }

    @objc func logOut(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = L("Log out of Tailscale?")
        alert.informativeText = L("This disconnects and invalidates this device's key. You'll need to re-authenticate to reconnect.")
        alert.addButton(withTitle: L("Log Out"))
        alert.addButton(withTitle: L("Cancel"))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let (output, code) = runTailscale(["logout"])
            DispatchQueue.main.async {
                self.loginInProgress = false
                if code != 0 {
                    self.showConnectError(output.isEmpty ? L(format: "tailscale logout failed (exit code %d).", code) : output)
                }
                self.refresh()
            }
        }
    }

    @objc func copyToClipboard(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc func openInBrowser(_ sender: NSMenuItem) {
        guard let ip = sender.representedObject as? String, let url = URL(string: "http://\(ip)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openAdminConsole(_ sender: NSMenuItem) {
        if let url = URL(string: "https://login.tailscale.com/admin/machines") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func selectExitNode(_ sender: NSMenuItem) {
        guard !commandInProgress, !loginInProgress, let target = sender.representedObject as? String else { return }
        commandInProgress = true
        updateDashboard()
        let allowLAN = currentPrefs?.ExitNodeAllowLANAccess == true
        DispatchQueue.global(qos: .userInitiated).async {
            let (output, code) = runTailscale(["set", "--exit-node=\(target)", "--exit-node-allow-lan-access=\(allowLAN)"])
            DispatchQueue.main.async {
                self.commandInProgress = false
                if code != 0 { self.showConnectError(output) }
                self.refresh()
            }
        }
    }

    @objc func toggleAllowLAN(_ sender: NSMenuItem) {
        let newValue = !(currentPrefs?.ExitNodeAllowLANAccess == true)
        DispatchQueue.global(qos: .userInitiated).async {
            runTailscale(["set", "--exit-node-allow-lan-access=\(newValue)"])
            DispatchQueue.main.async { self.refresh() }
        }
    }

    @objc func toggleAdvertiseExitNode(_ sender: NSMenuItem) {
        let newValue = !(currentPrefs?.AdvertiseRoutes?.contains("0.0.0.0/0") == true)
        DispatchQueue.global(qos: .userInitiated).async {
            runTailscale(["set", "--advertise-exit-node=\(newValue)"])
            DispatchQueue.main.async { self.refresh() }
        }
    }

    @objc func togglePref(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let prefs = currentPrefs
        DispatchQueue.global(qos: .userInitiated).async {
            switch key {
            case "accept-routes":
                let newVal = !(prefs?.RouteAll == true)
                runTailscale(["set", "--accept-routes=\(newVal)"])
            case "accept-dns":
                let newVal = !(prefs?.CorpDNS == true)
                runTailscale(["set", "--accept-dns=\(newVal)"])
            case "allow-incoming":
                let currentlyAllowed = (prefs?.ShieldsUp == false)
                let newAllowed = !currentlyAllowed
                runTailscale(["set", "--shields-up=\(!newAllowed)"])
            default:
                break
            }
            DispatchQueue.main.async { self.refresh() }
        }
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // reflect whatever the actual status ends up being on next refresh
        }
        refresh()
    }

    @objc func sendFileToPeer(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? String else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = L("Send file via Taildrop")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let (output, code) = runTailscale(["file", "cp", url.path, "\(target):"])
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = code == 0 ? L("File sent") : L("Send failed")
                alert.informativeText = output.isEmpty ? "\(url.lastPathComponent) → \(target)" : output
                alert.alertStyle = code == 0 ? .informational : .warning
                alert.runModal()
            }
        }
    }

    // MARK: notifications

    func notifyOnChanges(newStatus: TSStatus?) {
        let newBackendState = newStatus?.backendState
        let newExitID = newStatus?.exitNodeStatus?.ID
        // A reconnect cycle reports its own outcome; skip the down/up churn.
        guard pendingReconnect == nil else {
            previousBackendState = newBackendState
            previousExitNodeID = newExitID
            return
        }

        if let prev = previousBackendState, let new = newBackendState, prev != new {
            if new == "Running" {
                postNotification(title: L("Tailscale connected"), body: nil)
            } else if prev == "Running" {
                postNotification(title: L("Tailscale disconnected"), body: L(format: "State: %@", new))
            }
        }

        if previousBackendState != nil, previousExitNodeID != newExitID {
            if let id = newExitID {
                let name = newStatus?.peer?.values.first(where: { $0.ID == id })
                    .map { displayName(dnsName: $0.DNSName, fallback: $0.HostName ?? L("unknown")) } ?? L("unknown")
                postNotification(title: L("Exit node enabled"), body: name)
            } else if previousExitNodeID != nil {
                postNotification(title: L("Exit node disabled"), body: nil)
            }
        }

        previousBackendState = newBackendState
        previousExitNodeID = newExitID
    }

    func postNotification(title: String, body: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let body = body { content.body = body }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    @objc func pingPeer(_ sender: NSMenuItem) {
        guard let ip = sender.representedObject as? String else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let (output, _) = runTailscale(["ping", "-c", "3", ip])
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = L(format: "Ping %@", ip)
                alert.informativeText = output.isEmpty ? L("No output") : output
                alert.alertStyle = .informational
                alert.runModal()
            }
        }
    }
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--self-test") {
    runInterfaceSelfTests()
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
