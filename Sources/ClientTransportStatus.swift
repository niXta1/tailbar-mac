import AppKit

enum TransportIndicator {
    case none
    case clientOnly
    case proxyReady
}

struct ClientTransportStatus {
    var runningClients: [String] = []
    var proxyPort: Int?
    var checked = false

    static func runningClientsNow() -> [String] {
        let apps = NSWorkspace.shared.runningApplications
        return [("INCY", "llc.itdev.incy"), ("Happ", "com.happ.www")].compactMap { name, id in
            apps.contains { $0.bundleIdentifier == id } ? name : nil
        }
    }
    var clientLine: String {
        guard checked else { return L("Checking INCY / Happ…") }
        guard !runningClients.isEmpty else { return L("INCY / Happ not running") }
        return L(format: "%@ running", runningClients.joined(separator: " + "))
    }
    var modeLine: String {
        guard checked else { return L("Automatic connection mode") }
        return proxyPort.map { L(format: "Auto · local proxy :%ld", $0) } ?? L("Auto · no local proxy")
    }
    var indicator: TransportIndicator {
        guard checked else { return .none }
        if proxyPort != nil { return .proxyReady }
        return runningClients.isEmpty ? .none : .clientOnly
    }
    var menuSummary: String {
        guard checked else { return L("INCY / Happ: checking…") }
        let clients = runningClients.joined(separator: " + ")
        if let port = proxyPort {
            return clients.isEmpty ? L(format: "Local proxy :%ld available", port) : L(format: "%@ · proxy :%ld available", clients, port)
        }
        return clients.isEmpty ? L("INCY / Happ not running · direct") : L(format: "%@ running · no local proxy", clients)
    }
    var explanation: String {
        if let port = proxyPort {
            return L(format: "TCP port 127.0.0.1:%ld is open. The wrapper prefers this local proxy. A port check does not confirm CONNECT support, authentication or internet access.", port)
        }
        return L("No local proxy detected. Connecting without one is allowed. This does not guarantee that other system VPN/TUN interfaces are bypassed. If your network blocks Tailscale, start INCY or Happ.")
    }
}
