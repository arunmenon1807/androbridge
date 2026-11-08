import Foundation
import Observation

public enum DefaultConflictPolicy: String, CaseIterable, Codable, Sendable {
    case ask
    case keepBoth
    case skip

    public var label: String {
        switch self {
        case .ask: return "Ask every time"
        case .keepBoth: return "Keep both (rename the new copy)"
        case .skip: return "Skip existing items"
        }
    }
}

/// A Wi-Fi device the user connected to before.
public struct RememberedWirelessDevice: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(host):\(port)" }
    public var name: String
    public var host: String
    public var port: Int
    public var lastConnected: Date

    public init(name: String, host: String, port: Int, lastConnected: Date = Date()) {
        self.name = name
        self.host = host
        self.port = port
        self.lastConnected = lastConnected
    }
}

/// App preferences, stored in UserDefaults. Nothing leaves the Mac.
@MainActor
@Observable
public final class SettingsManager {
    private let defaults: UserDefaults

    public var showHiddenFiles: Bool { didSet { defaults.set(showHiddenFiles, forKey: Keys.showHidden) } }
    public var verifyChecksums: Bool { didSet { defaults.set(verifyChecksums, forKey: Keys.verify) } }
    public var conflictPolicy: DefaultConflictPolicy { didSet { defaults.set(conflictPolicy.rawValue, forKey: Keys.conflict) } }
    public var adbPathOverride: String { didSet { defaults.set(adbPathOverride, forKey: Keys.adbPath) } }
    public var autoReconnectWireless: Bool { didSet { defaults.set(autoReconnectWireless, forKey: Keys.autoReconnect) } }
    public var rememberedWireless: [RememberedWirelessDevice] {
        didSet {
            if let data = try? JSONEncoder().encode(rememberedWireless) { defaults.set(data, forKey: Keys.wireless) }
        }
    }
    public var lastLocalPath: String { didSet { defaults.set(lastLocalPath, forKey: Keys.lastLocal) } }

    private enum Keys {
        static let showHidden = "showHiddenFiles"
        static let verify = "verifyChecksums"
        static let conflict = "conflictPolicy"
        static let adbPath = "adbPathOverride"
        static let autoReconnect = "autoReconnectWireless"
        static let wireless = "rememberedWireless"
        static let lastLocal = "lastLocalPath"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showHiddenFiles = defaults.bool(forKey: Keys.showHidden)
        verifyChecksums = defaults.object(forKey: Keys.verify) as? Bool ?? true
        conflictPolicy = DefaultConflictPolicy(rawValue: defaults.string(forKey: Keys.conflict) ?? "") ?? .ask
        adbPathOverride = defaults.string(forKey: Keys.adbPath) ?? ""
        autoReconnectWireless = defaults.object(forKey: Keys.autoReconnect) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.wireless),
           let list = try? JSONDecoder().decode([RememberedWirelessDevice].self, from: data) {
            rememberedWireless = list
        } else {
            rememberedWireless = []
        }
        lastLocalPath = defaults.string(forKey: Keys.lastLocal)
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    }

    public func remember(_ device: RememberedWirelessDevice) {
        rememberedWireless.removeAll { $0.host == device.host }
        rememberedWireless.insert(device, at: 0)
    }

    public func forget(_ device: RememberedWirelessDevice) {
        rememberedWireless.removeAll { $0.id == device.id }
    }
}
