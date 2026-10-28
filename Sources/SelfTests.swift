import AppKit

func runInterfaceSelfTests() {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        print("PASS: \(message)")
    }
    let sample = Data("{\n\t\"State\":5,\"nested\":{\"text\":\"} { \\\" Привет\"}\n}\n{\"State\":6}\n".utf8)
    var parser = JSONObjectStream()
    var events: [[String: Any]] = []
    for byte in sample { events += parser.feed(Data([byte])) }
    check(events.count == 2, "fragmented JSON and UTF-8, nested objects, escaped quotes")
    check(events.first?["State"] as? Int == 5 && events.last?["State"] as? Int == 6, "Starting → Running order preserved")
    check(parser.feed(Data("{}\n{}\n".utf8)).count == 2, "coalesced empty events")
    check(parser.feed(Data(" \n".utf8)).isEmpty, "whitespace is ignored")
    let delegate = AppDelegate()
    for state in [AppDelegate.MatrixState.dim, .connected, .exitNode(online: true), .exitNode(online: false), .warning, .wave(frame: 15)] {
        check(delegate.matrixIcon(state).tiffRepresentation != nil, "status icon renders")
    }
    check(delegate.animationTimer == nil, "no animation while idle")
    check(TailbarGlyph.bridge == [3, 4, 5, 6, 8], "connected glyph is Tailbar's bridge: middle row plus bottom corners")
    check((0..<TailbarGlyph.frameCount).allSatisfy { !TailbarGlyph.connectingFrame($0).isEmpty }, "every connecting frame shows a dot")
    check(TailbarGlyph.connectingFrame(TailbarGlyph.buildOrder.count - 1) == TailbarGlyph.bridge, "connecting animation completes the bridge")
    let fixture = Data(#"{"BackendState":"Running","Self":{"TailscaleIPs":["100.64.0.1"],"DNSName":"mac.test.","UserID":1},"Peer":{"node":{"ID":"exit1","HostName":"demo-exit","TailscaleIPs":["100.64.0.2"],"Online":true,"ExitNodeOption":true,"UserID":1}},"ExitNodeStatus":{"ID":"exit1","Online":true},"User":{"1":{"LoginName":"test@example.invalid","DisplayName":"Test owner"}}}"#.utf8)
    let model = DashboardModel()
    model.status = try! JSONDecoder().decode(TSStatus.self, from: fixture)
    check(model.rows.count == 2 && model.rows.first?.isSelf == true, "device list includes this Mac first")
    check(model.groups == ["Test owner"], "device groups use actual owner names")
    check(model.exitName == "demo-exit", "sidebar resolves selected exit node")
    model.chooseSection("Exit Nodes")
    check(model.filtered.count == 1, "exit-node section excludes regular devices")
    model.selected = "exit1"
    check(model.selectedDevice?.name == "demo-exit", "selection opens matching details")
    model.query = "100.64.0.2"
    check(model.filtered.count == 1, "search matches IP addresses")
    model.query = "absent"
    check(model.filtered.isEmpty && model.selectedDevice == nil, "filtered selection does not show a stale detail panel")
    model.status?.backendState = "Stopped"
    check(model.rows.allSatisfy { !$0.online }, "cached devices are not presented as live while stopped")
    let toggle = ConnectionToggle()
    check(toggle.intrinsicContentSize == NSSize(width: 54, height: 24), "shared switch geometry is 54 × 24 pt")
    check(toggle.frame.size == toggle.intrinsicContentSize, "switch frame and intrinsic size agree")
    toggle.state = .on
    check(toggle.state == .on, "switch exposes its actual checked state")
    let direct = ClientTransportStatus(checked: true)
    check(direct.modeLine.contains("no local proxy"), "no proxy allows automatic direct mode")
    check(direct.indicator == .none, "no client or proxy leaves native status icon unchanged")
    let appOnly = ClientTransportStatus(runningClients: ["INCY"], checked: true)
    check(appOnly.clientLine == "INCY running" && appOnly.proxyPort == nil, "running client is distinct from an available proxy")
    check(appOnly.indicator == .clientOnly, "running client gets amber status dot")
    let proxyOnly = ClientTransportStatus(proxyPort: 10808, checked: true)
    check(proxyOnly.modeLine.contains(":10808") && proxyOnly.runningClients.isEmpty, "background listener does not imply running GUI")
    check(proxyOnly.indicator == .proxyReady, "local listener gets green status dot")
    let dotCenter = TransportDotView.topLeftDotCenter(in: NSRect(x: 0, y: 0, width: 18, height: 18))
    check(abs(dotCenter.x - 3.6) < 0.001 && abs(dotCenter.y - 14.4) < 0.001, "transport dot aligns with the glyph's top-left dot")
    let incyIfconfig = "en0: flags=8863<UP> mtu 1500\n\tinet 192.0.2.10 netmask 0xffffff00\nutun4: flags=8051<UP> mtu 1500\n\tinet 198.18.0.2 --> 198.18.0.1 netmask 0xffff0000\nutun5: flags=8051<UP> mtu 1280\n\tinet 100.64.0.1 --> 100.64.0.1\n"
    check(clientTunnelPresent(ifconfig: incyIfconfig), "INCY fake-IP utun is detected")
    check(!clientTunnelPresent(ifconfig: "en0: flags=8863<UP>\n\tinet 198.18.0.2 netmask 0xffffff00\nutun5: flags=8051<UP>\n\tinet 100.64.0.1 --> 100.64.0.1\n"), "fake-IP range off a utun is not INCY TUN")
    let vpnRoutes = """
    Routing tables

    Internet:
    Destination        Gateway            Flags               Netif Expire
    0/1                utun5              USc                 utun5
    default            link#22            UCSg                utun4
    default            192.0.2.1          UGScIg                en0
    128.0/1            utun5              USc                 utun5
    """
    check(splitDefaultRoutesPresent(netstat: vpnRoutes), "route helper /1 halves are detected")
    check(physicalDefaultRoutePresent(netstat: vpnRoutes), "scoped Wi-Fi default counts as a live uplink under a VPN")
    let asleepRoutes = "Destination        Gateway            Flags               Netif Expire\ndefault            link#22            UCSg                utun4\n"
    check(!physicalDefaultRoutePresent(netstat: asleepRoutes), "tunnel-only default is not a live uplink")
    check(!splitDefaultRoutesPresent(netstat: asleepRoutes), "no /1 halves after cleanup")
    model.status = try! JSONDecoder().decode(TSStatus.self, from: fixture)
    check(exitNodeTarget(of: model.status) == "100.64.0.2", "reconnect restores the exit node by its tailnet IP")
    let incyDNS = "DNS configuration\n\nresolver #1\n  search domain[0] : example.invalid\n  nameserver[0] : 198.18.0.2\n  if_index : 18 (utun4)\n\nDNS configuration (for scoped queries)\n\nresolver #1\n  nameserver[0] : 192.0.2.1\n"
    check(primaryNameserver(scutilDNS: incyDNS) == "198.18.0.2", "default resolver is read from the unscoped DNS section")
    check(liveInterfaces(ifconfig: incyIfconfig) == ["en0", "utun4", "utun5"], "interfaces with IPv4 addresses are live")
    check(diagnoseNetwork(netstat: vpnRoutes, ifconfig: incyIfconfig, dns: incyDNS, tailscaleState: "Running").isEmpty,
          "INCY TUN + Tailscale exit node is healthy")
    let wifiOnly = "Destination        Gateway            Flags               Netif Expire\ndefault            192.0.2.1          UGScIg                en0\n"
    let wifiIfconfig = "en0: flags=8863<UP> mtu 1500\n\tinet 192.0.2.10 netmask 0xffffff00\n"
    check(diagnoseNetwork(netstat: wifiOnly, ifconfig: wifiIfconfig, dns: incyDNS, tailscaleState: "Stopped") == [.noPrimaryRoute, .staleClientDNS],
          "INCY quit: Wi-Fi up, no default route, DNS still at INCY")
    let deadTunnel = "Destination        Gateway            Flags               Netif Expire\ndefault            link#30            UCSg                utun9\ndefault            192.0.2.1          UGScIg                en0\n"
    check(diagnoseNetwork(netstat: deadTunnel, ifconfig: wifiIfconfig, dns: "", tailscaleState: nil) == [.deadTunnelRoute("utun9")],
          "default route into a tunnel without an address is dead")
    let plainWiFi = "Destination        Gateway            Flags               Netif Expire\ndefault            192.0.2.1          UGScg                en0\n"
    let tailscaleDNS = "DNS configuration\n\nresolver #1\n  nameserver[0] : 100.100.100.100\n"
    check(diagnoseNetwork(netstat: plainWiFi, ifconfig: wifiIfconfig, dns: tailscaleDNS, tailscaleState: "Stopped") == [.staleTailscaleDNS],
          "Tailscale DNS left behind while stopped")
    check(diagnoseNetwork(netstat: plainWiFi, ifconfig: wifiIfconfig, dns: tailscaleDNS, tailscaleState: nil).isEmpty,
          "unknown Tailscale state never counts as stale DNS")
    let exitOnly = "Destination        Gateway            Flags               Netif Expire\n0/1                utun5              USc                 utun5\ndefault            192.0.2.1          UGScIg                en0\n128.0/1            utun5              USc                 utun5\n"
    check(diagnoseNetwork(netstat: exitOnly, ifconfig: incyIfconfig, dns: "", tailscaleState: "Running").isEmpty,
          "live /1 halves stand in for a default route")
    print("Self-tests do not start the app UI, access the daemon, or modify VPN settings.")
}
