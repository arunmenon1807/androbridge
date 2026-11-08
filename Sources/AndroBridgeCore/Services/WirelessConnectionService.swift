import Foundation

/// ADB Wireless debugging (Android 11+): pair with a 6-digit code, then connect.
///
/// No ports are opened on the Mac. Pairing uses adb's TLS pairing protocol, and the
/// phone only accepts paired keys. Wireless debugging turns itself off on the phone when
/// it leaves the Wi-Fi network.
public struct WirelessConnectionService: Sendable {
    public let client: ADBClient

    public init(client: ADBClient) {
        self.client = client
    }

    public func pair(host: String, port: Int, code: String) async throws -> String {
        try await client.pair(host: host, port: port, code: code)
    }

    public func connect(host: String, port: Int) async throws {
        try await client.connect(host: host, port: port)
    }

    public func disconnect(serial: String) async throws {
        try await client.disconnect(serial: serial)
    }

    /// Phones advertising Wireless debugging on this network.
    public func discover() async -> [ADBOutputParser.MDNSService] {
        (try? await client.mdnsServices()) ?? []
    }

    /// Try each remembered device. Returns the ones that connected.
    /// The connect port changes whenever Wireless debugging is toggled, so this also
    /// looks for a fresh port for the same host via mDNS.
    public func reconnect(_ remembered: [RememberedWirelessDevice]) async -> [RememberedWirelessDevice] {
        var connected: [RememberedWirelessDevice] = []
        let advertised = await discover().filter(\.isConnect)
        for device in remembered {
            var candidates = [(device.host, device.port)]
            for svc in advertised {
                let parts = svc.address.split(separator: ":")
                if parts.count == 2, String(parts[0]) == device.host, let p = Int(parts[1]), p != device.port {
                    candidates.insert((device.host, p), at: 0)
                }
            }
            for (host, port) in candidates {
                if (try? await client.connect(host: host, port: port)) != nil {
                    var updated = device
                    updated.port = port
                    updated.lastConnected = Date()
                    connected.append(updated)
                    break
                }
            }
        }
        return connected
    }

    /// Parses "192.168.1.20:37099" into host and port.
    public static func parseAddress(_ text: String) -> (String, Int)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let host = String(trimmed[..<colon])
        guard let port = Int(trimmed[trimmed.index(after: colon)...]), (1...65535).contains(port),
              ADBClient.isValidHost(host) else { return nil }
        return (host, port)
    }
}
