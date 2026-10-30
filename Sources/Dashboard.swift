import AppKit
import SwiftUI
import ServiceManagement

struct DeviceRow: Identifiable {
    let id: String
    let name: String
    let dns: String
    let ips: [String]
    let online: Bool
    let isSelf: Bool
    let exitNode: Bool
    let os: String
    let group: String
    var symbol: String {
        if os == "ios" { return "iphone" }
        if os == "android" { return "smartphone" }
        if os == "macOS" { return "laptopcomputer" }
        return "desktopcomputer"
    }
}

final class DashboardModel: ObservableObject {
    @Published var status: TSStatus?
    @Published var prefs: TSPrefs?
    @Published var busy = false
    @Published var proxy = L("Checking…")
    @Published var route = L("Not checked")
    @Published var transport = ClientTransportStatus()
    @Published var section = "Devices"
    @Published var query = ""
    @Published var selected: String?
    @Published var sheet: String?
    @Published var hideDock = UserDefaults.standard.bool(forKey: "hideDockWhenClosed")
    @Published var reconnectAcrossSleep = true
    @Published var autoRepair = true
    @Published var networkHealth = L("Network not checked yet")
    var onConnect: (() -> Void)?
    var onExit: ((String) -> Void)?
    var onHideDock: ((Bool) -> Void)?
    var onPing: ((String) -> Void)?
    var onPreference: ((String) -> Void)?
    var onLaunchAtLogin: (() -> Void)?
    var onAccount: (() -> Void)?
    var onReconnectAcrossSleep: ((Bool) -> Void)?
    var onReconnect: (() -> Void)?
    var onAutoRepair: ((Bool) -> Void)?
    var onRepairNetwork: (() -> Void)?

    var running: Bool { status?.backendState == "Running" && prefs?.LoggedOut != true }
    var canConnect: Bool { !busy && ["Running", "Stopped", "NeedsLogin"].contains(status?.backendState ?? "") }
    var stateTitle: String {
        if busy { return L("Updating…") }
        if prefs?.LoggedOut == true { return L("Needs login") }
        return ["Running": L("Connected"), "Stopped": L("Disconnected"), "Starting": L("Connecting…"), "NeedsLogin": L("Needs login"), "NeedsMachineAuth": L("Needs approval")][status?.backendState ?? ""] ?? L("Service unavailable")
    }
    var account: String { status?.currentTailnet?.Name ?? "Tailbar" }
    var rows: [DeviceRow] {
        var result = (status?.peer?.values.map { peer in
            DeviceRow(id: peer.ID ?? peer.TailscaleIPs?.first ?? peer.DNSName ?? "unknown",
                      name: displayName(dnsName: peer.DNSName, fallback: peer.HostName ?? L("Device")),
                      dns: peer.DNSName ?? "", ips: peer.TailscaleIPs ?? [], online: running && peer.Online == true,
                      isSelf: false, exitNode: peer.ExitNodeOption == true, os: peer.OS ?? "",
                      group: peer.Tags?.isEmpty == false ? L("Tagged devices") : (status?.user?[String(peer.UserID ?? 0)]?.DisplayName ?? L("Network devices")))
        } ?? [])
        if let me = status?.selfNode, let ip = me.TailscaleIPs?.first {
            result.append(DeviceRow(id: "self:\(ip)", name: displayName(dnsName: me.DNSName, fallback: L("This Mac")),
                                    dns: me.DNSName ?? "", ips: me.TailscaleIPs ?? [], online: running,
                                    isSelf: true, exitNode: false, os: "macOS", group: status?.user?[String(me.UserID ?? 0)]?.DisplayName ?? L("Network devices")))
        }
        return result.sorted { a, b in
            if a.isSelf != b.isSelf { return a.isSelf }
            if a.online != b.online { return a.online }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    var filtered: [DeviceRow] {
        rows.filter {
            (section != "Exit Nodes" || $0.exitNode) &&
            (query.isEmpty || "\($0.name) \($0.dns) \($0.ips.joined(separator: " "))".localizedCaseInsensitiveContains(query))
        }
    }
    var selectedDevice: DeviceRow? { filtered.first { $0.id == selected } }
    var groups: [String] { Array(Set(filtered.map(\.group))).sorted() }
    var exitName: String {
        guard let id = status?.exitNodeStatus?.ID else { return L("None") }
        return rows.first { $0.id == id }?.name ?? L("Selected exit node")
    }
    func chooseSection(_ name: String) { section = name; query = ""; selected = nil }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

private struct ConnectionSwitch: NSViewRepresentable {
    @ObservedObject var model: DashboardModel
    final class Coordinator: NSObject {
        var action: (() -> Void)?
        @objc func change() { action?() }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ConnectionToggle {
        let control = ConnectionToggle()
        control.target = context.coordinator
        control.action = #selector(Coordinator.change)
        return control
    }
    func updateNSView(_ control: ConnectionToggle, context: Context) {
        control.state = model.running ? .on : .off
        control.isEnabled = model.canConnect
        context.coordinator.action = model.onConnect
    }
}

private struct ConnectionHeader: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        HStack(spacing: 14) {
            ConnectionSwitch(model: model).fixedSize().frame(width: 54, height: 24)
                .help(L("Connect or disconnect Tailscale"))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.account).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(model.stateTitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.leading, 10).frame(width: 360, height: 54)
    }
}

private struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 250)
            Divider()
            deviceList.frame(minWidth: 290, idealWidth: 330, maxWidth: 410)
            Divider()
            details.frame(minWidth: 270, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: Binding(get: { model.sheet != nil }, set: { if !$0 { model.sheet = nil } })) {
            ScrollView { sheetContent.frame(width: 480).padding(24) }.frame(minHeight: 440, idealHeight: 620)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { model.chooseSection("Exit Nodes") } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.exitName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(L("Exit Node")).font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.primary.opacity(0.12)))
            }.buttonStyle(.plain).padding(.bottom, 2)
            navigation("Devices", symbol: "laptopcomputer.and.iphone")
            navigation("Exit Nodes", symbol: "rectangle.portrait.and.arrow.right")
            Spacer()
            Button { model.sheet = "Diagnostics" } label: {
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(!model.transport.checked ? Color.secondary : model.transport.proxyPort != nil ? Color.green : model.transport.runningClients.isEmpty ? Color.secondary : Color.orange)
                        .frame(width: 7, height: 7).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.transport.clientLine).font(.system(size: 11, weight: .medium))
                        Text(model.transport.modeLine).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).help(model.transport.explanation)
            if !model.running {
                Text(L("Showing saved devices")).font(.system(size: 11)).foregroundStyle(.secondary).padding(10)
            }
            if model.running, let health = model.status?.health, !health.isEmpty {
                Button { model.sheet = "Diagnostics" } label: {
                    Label(L(format: "%ld connectivity warning(s)", health.count), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }.buttonStyle(.plain).padding(10)
            }
        }.padding(10).background(.ultraThinMaterial)
            .background(colorScheme == .dark ? Color.white.opacity(0.085) : Color.black.opacity(0.035))
    }

    private func navigation(_ title: String, symbol: String) -> some View {
        Button { model.chooseSection(title) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Color.accentColor).frame(width: 22)
                Text(L(title)).font(.system(size: 16, weight: .medium))
                Spacer()
            }.padding(.horizontal, 12).padding(.vertical, 10)
                .background(model.section == title ? Color.primary.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L(model.section)).font(.system(size: 23, weight: .medium)).padding(.top, 24)
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Search…"), text: $model.query).textFieldStyle(.plain).accessibilityLabel(L("Search devices"))
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(L("Clear search"))
                }
            }.padding(10).background(colorScheme == .dark ? Color.black.opacity(0.5) : Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.filtered.isEmpty {
                        Text(model.query.isEmpty ? L("No devices available") : L("No matching devices"))
                            .foregroundStyle(.secondary).padding(.vertical, 16)
                    }
                    ForEach(model.groups, id: \.self) { group in
                        let members = model.filtered.filter { $0.group == group }
                        if !members.isEmpty {
                            Text(group).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.top, 8).padding(.bottom, 5).padding(.leading, 8)
                            ForEach(members) { device in deviceButton(device) }
                        }
                    }
                }
            }
        }.padding(.horizontal, 18).padding(.bottom, 14)
    }

    private func deviceButton(_ device: DeviceRow) -> some View {
        Button { model.selected = device.id } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(device.online ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                    Text(device.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    if device.isSelf { Image(systemName: "desktopcomputer").foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                }
                Text(device.ips.first ?? L("No address")).font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 14)
            }.padding(.horizontal, 8).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                .background(model.selected == device.id ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(device.name), \(device.online ? L("online") : L("offline")), \(device.ips.first ?? "")")
    }

    @ViewBuilder private var details: some View {
        if let device = model.selectedDevice {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: device.symbol).font(.system(size: 36)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(device.name).font(.system(size: 22, weight: .semibold)).textSelection(.enabled)
                    Label(!model.running ? L("Saved status") : (device.online ? L("Connected") : L("Offline")),
                          systemImage: "circle.fill").font(.system(size: 12)).foregroundStyle(device.online ? .green : .secondary)
                    if device.isSelf { Text(L("This device")).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Addresses")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(device.ips, id: \.self) { ip in
                        HStack {
                            Text(ip).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button { model.copy(ip) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help(L(format: "Copy %@", ip))
                        }
                    }
                    if !device.dns.isEmpty {
                        Text(device.dns).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if device.exitNode {
                    let selected = model.status?.exitNodeStatus?.ID == device.id
                    Button(selected ? L("Stop using exit node") : L("Use exit node")) {
                        model.onExit?(selected ? "" : (device.ips.first ?? device.id))
                    }.disabled(!model.running || model.busy)
                }
                if !device.isSelf, let ip = device.ips.first {
                    Button(L("Ping device")) { model.onPing?(ip) }.disabled(!model.running || model.busy)
                }
                Spacer()
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else { Color.clear }
    }

    @ViewBuilder private var sheetContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(model.sheet.map { L($0) } ?? "").font(.title2.bold())
                Spacer()
                Button(L("Done")) { model.sheet = nil }.keyboardShortcut(.defaultAction)
            }
            if model.sheet == "Settings" {
                Text(L("Appearance")).font(.headline)
                Toggle(L("Hide Dock icon when all windows are closed"), isOn: Binding(get: { model.hideDock }, set: {
                    model.hideDock = $0; model.onHideDock?($0)
                }))
                Toggle(L("Launch at login"), isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { _ in model.onLaunchAtLogin?() }))
                Divider()
                Text(L("Sleep and wake")).font(.headline)
                Toggle(L("Disconnect before sleep, reconnect after wake"), isOn: Binding(get: { model.reconnectAcrossSleep }, set: {
                    model.reconnectAcrossSleep = $0; model.onReconnectAcrossSleep?($0)
                }))
                Text(L("For INCY / Happ set to keep the VPN on during sleep. Tailscale is stopped before sleep so its routes cannot trap the client's own connection, then started again once Wi-Fi and INCY / Happ are back. The exit node is kept."))
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("Reconnect Tailscale now")) { model.onReconnect?() }.disabled(!model.running || model.busy)
                Toggle(L("Detect and repair a broken network automatically"), isOn: Binding(get: { model.autoRepair }, set: {
                    model.autoRepair = $0; model.onAutoRepair?($0)
                }))
                Text(L("Covers Wi-Fi up but no internet after changing networks, quitting INCY / Happ, or turning an exit node off: a missing default route, a route into a dead tunnel, stale DNS, or an exit node that stopped answering. The repair stops Tailscale, restarts Wi-Fi, and restores Tailscale with the same exit node. At most two automatic attempts, then a notification. Checks internet reachability via captive.apple.com, the URL macOS itself uses."))
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("Repair network now")) { model.onRepairNetwork?() }.disabled(model.busy)
                Divider()
                Text(L("Network preferences")).font(.headline)
                preference(L("Use Tailscale subnets"), key: "accept-routes", value: model.prefs?.RouteAll == true)
                preference(L("Use Tailscale DNS"), key: "accept-dns", value: model.prefs?.CorpDNS == true)
                preference(L("Allow incoming connections"), key: "allow-incoming", value: model.prefs?.ShieldsUp == false)
                Text(L("Closing this window or quitting the interface leaves the VPN active."))
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text(L("Local proxy")).font(.headline)
                Text(model.proxy).textSelection(.enabled)
                Text(model.transport.clientLine).textSelection(.enabled)
                Text(model.transport.modeLine).font(.headline)
                Text(model.transport.explanation).font(.callout).foregroundStyle(.secondary)
                Text(L("Network health")).font(.headline)
                Text(model.networkHealth).textSelection(.enabled)
                Button(L("Repair network now")) { model.onRepairNetwork?() }.disabled(model.busy)
                Text(L("IPv4 route")).font(.headline)
                Text(model.route).textSelection(.enabled)
                Divider()
                Text(L("Tailscale health")).font(.headline)
                ScrollView {
                    Text((model.status?.health ?? []).isEmpty ? L("No reported warnings") : (model.status?.health ?? []).joined(separator: "\n\n"))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(maxHeight: 160)
                Text(L("A route lookup is not a connectivity or public-IP test."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func preference(_ title: String, key: String, value: Bool) -> some View {
        Toggle(title, isOn: Binding(get: { value }, set: { _ in model.onPreference?(key) }))
            .disabled(model.busy || model.prefs == nil)
    }
}

final class DashboardController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let model = DashboardModel()
    var onConnect: (() -> Void)? { didSet { model.onConnect = onConnect } }
    var onExit: ((String) -> Void)? { didSet { model.onExit = onExit } }
    var onHideDock: ((Bool) -> Void)? { didSet { model.onHideDock = onHideDock } }
    var onPing: ((String) -> Void)? { didSet { model.onPing = onPing } }
    var onPreference: ((String) -> Void)? { didSet { model.onPreference = onPreference } }
    var onLaunchAtLogin: (() -> Void)? { didSet { model.onLaunchAtLogin = onLaunchAtLogin } }
    var onAccount: (() -> Void)? { didSet { model.onAccount = onAccount } }
    var onReconnectAcrossSleep: ((Bool) -> Void)? { didSet { model.onReconnectAcrossSleep = onReconnectAcrossSleep } }
    var onReconnect: (() -> Void)? { didSet { model.onReconnect = onReconnect } }
    var onAutoRepair: ((Bool) -> Void)? { didSet { model.onAutoRepair = onAutoRepair } }
    var onRepairNetwork: (() -> Void)? { didSet { model.onRepairNetwork = onRepairNetwork } }
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Tailbar"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 840, height: 500)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("TailbarWindowV1")
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: DashboardView(model: model))
        let toolbar = NSToolbar(identifier: "TailbarToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) { onClose?() }
    func update(status: TSStatus?, prefs: TSPrefs?, busy: Bool, proxy: String, route: String) {
        model.status = status; model.prefs = prefs; model.busy = busy; model.proxy = proxy; model.route = route
    }
    func showSettings() { model.sheet = "Settings" }
    func showDiagnostics() { model.sheet = "Diagnostics" }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("connection"), .flexibleSpace, .init("diagnostics"), .init("settings"), .init("account")]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        // Explicitly opt out of Tahoe's automatic glass backing, as in
        // Apple's AppKit WWDC25 guidance for custom toolbar content.
        item.isBordered = false
        if id.rawValue == "connection" {
            item.view = NSHostingView(rootView: ConnectionHeader(model: model))
        } else {
            let symbols = ["diagnostics": "ladybug", "settings": "slider.horizontal.3", "account": "person.crop.circle.fill"]
            let labels = ["diagnostics": L("Diagnostics"), "settings": L("Settings"), "account": L("Account")]
            item.label = labels[id.rawValue] ?? ""
            item.toolTip = item.label
            item.image = NSImage(systemSymbolName: symbols[id.rawValue] ?? "circle", accessibilityDescription: item.label)
            item.target = self
            item.action = id.rawValue == "diagnostics" ? #selector(diagnosticsAction) : id.rawValue == "settings" ? #selector(settingsAction) : #selector(accountAction)
        }
        return item
    }
    @objc private func diagnosticsAction() { showDiagnostics() }
    @objc private func settingsAction() { showSettings() }
    @objc private func accountAction() { onAccount?() }
}
