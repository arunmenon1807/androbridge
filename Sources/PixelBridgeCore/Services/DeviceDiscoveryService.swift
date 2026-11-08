import Foundation
import Observation

/// Watches `adb devices -l` and publishes the list. Polling every 1.5 s is simple and
/// recovers by itself from adb server restarts, cable unplugs and sleep/wake.
@MainActor
@Observable
public final class DeviceDiscoveryService {
    public private(set) var devices: [ADBDevice] = []
    public private(set) var adbError: String?
    public private(set) var adbVersion: String?

    public private(set) var client: ADBClient?
    private var pollTask: Task<Void, Never>?
    private var connections: [String: AndroidDevice] = [:]

    /// Called whenever a serial appears or disappears.
    public var onChange: (([ADBDevice], [ADBDevice]) -> Void)?

    public init() {}

    /// (Re)locates adb and starts polling.
    public func start(adbOverride: String?) {
        stop()
        guard let url = ADBLocator.locate(override: adbOverride) else {
            client = nil
            devices = []
            adbError = DeviceError.adbNotFound.localizedDescription
            return
        }
        let client = ADBClient(adbURL: url)
        self.client = client
        adbError = nil
        connections = [:]
        pollTask = Task { [weak self] in
            do {
                try await client.startServer()
                let v = try await client.version()
                await MainActor.run { self?.adbVersion = v }
            } catch {
                await MainActor.run { self?.adbError = error.localizedDescription }
            }
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func refresh() async {
        guard let client else { return }
        do {
            let list = try await client.devices()
            if list != devices {
                let old = devices
                devices = list
                // Drop connections for devices that vanished.
                let live = Set(list.map(\.serial))
                connections = connections.filter { live.contains($0.key) }
                onChange?(old, list)
            }
            if adbError != nil { adbError = nil }
        } catch {
            adbError = "adb isn’t responding: \(error.localizedDescription)"
        }
    }

    /// A file-operation connection for a ready device, or nil if it's gone/unauthorized.
    public func connection(for serial: String) -> AndroidDevice? {
        guard let client, let d = devices.first(where: { $0.serial == serial }), d.state.isReady else { return nil }
        if let existing = connections[serial] { return existing }
        let c = AndroidDevice(serial: serial, client: client)
        connections[serial] = c
        return c
    }
}
