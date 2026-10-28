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
        guard checked else { return "Checking INCY / Happ…" }
        guard !runningClients.isEmpty else { return "INCY / Happ not running" }
        return runningClients.joined(separator: " + ") + " running"
    }
    var modeLine: String {
        guard checked else { return "Automatic connection mode" }
        return proxyPort.map { "Auto · local proxy :\($0)" } ?? "Auto · no local proxy"
    }
    var indicator: TransportIndicator {
        guard checked else { return .none }
        if proxyPort != nil { return .proxyReady }
        return runningClients.isEmpty ? .none : .clientOnly
    }
    var menuSummary: String {
        guard checked else { return "INCY / Happ: checking…" }
        let clients = runningClients.joined(separator: " + ")
        if let port = proxyPort {
            return clients.isEmpty ? "Local proxy :\(port) available" : "\(clients) · proxy :\(port) available"
        }
        return clients.isEmpty ? "INCY / Happ not running · direct" : "\(clients) running · no local proxy"
    }
    var explanation: String {
        if let port = proxyPort {
            return "TCP port 127.0.0.1:\(port) is open. The wrapper prefers this local proxy. A port check does not confirm CONNECT support, authentication or internet access."
        }
        return "No local proxy detected. Connecting without one is allowed. This does not guarantee that other system VPN/TUN interfaces are bypassed. If your network blocks Tailscale, start INCY or Happ."
    }
}
