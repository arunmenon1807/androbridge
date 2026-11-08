import Foundation

/// Server-level adb commands (not tied to one device): listing devices,
/// wireless pairing and connecting, mDNS discovery.
///
/// This is the `ADBConnectionService` from the design: every adb invocation in the app
/// goes through `run`, which only accepts an argument array.
public final class ADBClient: @unchecked Sendable {
    public let adbURL: URL
    private let runner: ProcessRunner

    public init(adbURL: URL) {
        self.adbURL = adbURL
        self.runner = ProcessRunner(executable: adbURL)
    }

    /// Runs `adb <arguments>`.
    @discardableResult
    public func run(_ arguments: [String], timeout: TimeInterval? = 30) async throws -> ProcessResult {
        try await runner.run(arguments, timeout: timeout)
    }

    /// Runs `adb -s <serial> <arguments>`.
    @discardableResult
    public func run(serial: String, _ arguments: [String], timeout: TimeInterval? = 30) async throws -> ProcessResult {
        try await runner.run(["-s", serial] + arguments, timeout: timeout)
    }

    public func startServer() async throws {
        let result = try await run(["start-server"], timeout: 20)
        if !result.succeeded {
            throw DeviceError.commandFailed("Could not start the adb server: \(result.stderrString)")
        }
    }

    public func version() async throws -> String {
        let result = try await run(["version"], timeout: 10)
        return result.stdoutString.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    public func devices() async throws -> [ADBDevice] {
        let result = try await run(["devices", "-l"], timeout: 15)
        guard result.succeeded else {
            throw DeviceError.commandFailed(result.stderrString)
        }
        return ADBOutputParser.parseDevices(result.stdoutString)
    }

    // MARK: Wireless debugging (Android 11+)

    /// `adb pair HOST:PORT CODE`. The pairing port and code come from
    /// Settings → Developer options → Wireless debugging → Pair device with pairing code.
    public func pair(host: String, port: Int, code: String) async throws -> String {
        guard Self.isValidHost(host), (1...65535).contains(port) else {
            throw DeviceError.commandFailed("Enter a valid IP address and port.")
        }
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else {
            throw DeviceError.commandFailed("The pairing code is the 6-digit number shown on the phone.")
        }
        let result = try await run(["pair", "\(host):\(port)", digits], timeout: 30)
        let text = result.stdoutString + result.stderrString
        if result.succeeded && text.lowercased().contains("successfully paired") {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw DeviceError.commandFailed("Pairing failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    /// `adb connect HOST:PORT`. Note the connect port differs from the pairing port.
    public func connect(host: String, port: Int) async throws {
        guard Self.isValidHost(host), (1...65535).contains(port) else {
            throw DeviceError.commandFailed("Enter a valid IP address and port.")
        }
        let result = try await run(["connect", "\(host):\(port)"], timeout: 20)
        let text = (result.stdoutString + result.stderrString).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("connected to") && !lower.contains("failed") && !lower.contains("unable") {
            return
        }
        throw DeviceError.commandFailed("Couldn’t connect: \(text)")
    }

    public func disconnect(serial: String) async throws {
        try await run(["disconnect", serial], timeout: 10)
    }

    /// Services advertised by phones with Wireless debugging on, via adb's built-in mDNS.
    public func mdnsServices() async throws -> [ADBOutputParser.MDNSService] {
        let result = try await run(["mdns", "services"], timeout: 10)
        return ADBOutputParser.parseMDNSServices(result.stdoutString)
    }

    /// Accepts IPv4 dotted quads and simple hostnames. Rejects anything that could be
    /// mistaken for an adb option.
    public static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, !host.hasPrefix("-"), host.count <= 253 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
