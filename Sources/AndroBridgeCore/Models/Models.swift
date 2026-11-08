import Foundation

// MARK: - Devices

public enum DeviceState: String, Sendable, Codable, Equatable {
    /// Connected and authorized; file operations work.
    case device
    /// USB debugging is on, but this Mac's RSA key has not been accepted on the phone.
    case unauthorized
    /// adb cannot open the USB device (usually another app holds it).
    case noPermissions = "no permissions"
    /// adb sees the device but it is not responding (booting, or the connection is stale).
    case offline
    case recovery
    case sideload
    case bootloader
    case unknown

    public init(adbValue: String) {
        if adbValue.hasPrefix("no permissions") { self = .noPermissions; return }
        self = DeviceState(rawValue: adbValue) ?? .unknown
    }

    public var isReady: Bool { self == .device }

    public var displayName: String {
        switch self {
        case .device: return "Connected"
        case .unauthorized: return "Waiting for authorization"
        case .noPermissions: return "No USB permission"
        case .offline: return "Offline"
        case .recovery: return "Recovery mode"
        case .sideload: return "Sideload mode"
        case .bootloader: return "Bootloader"
        case .unknown: return "Unknown"
        }
    }
}

public enum ConnectionKind: String, Sendable, Codable {
    case usb
    case wireless
    case emulator
}

/// One line of `adb devices -l`.
public struct ADBDevice: Identifiable, Hashable, Sendable {
    public var id: String { serial }
    public let serial: String
    public let state: DeviceState
    public let model: String?
    public let product: String?
    public let deviceName: String?
    public let transportID: String?
    public let usbPath: String?

    public init(serial: String, state: DeviceState, model: String? = nil, product: String? = nil,
                deviceName: String? = nil, transportID: String? = nil, usbPath: String? = nil) {
        self.serial = serial
        self.state = state
        self.model = model
        self.product = product
        self.deviceName = deviceName
        self.transportID = transportID
        self.usbPath = usbPath
    }

    public var connectionKind: ConnectionKind {
        if serial.hasPrefix("emulator-") { return .emulator }
        // Wireless serials are "ip:port" or an mDNS service name.
        if serial.contains(":") || serial.contains("._adb-tls-connect.") { return .wireless }
        return .usb
    }

    /// Human-friendly name; `model` uses underscores ("Pixel_8_Pro").
    public var displayName: String {
        if let model, !model.isEmpty { return model.replacingOccurrences(of: "_", with: " ") }
        return serial
    }
}

/// Facts read from the phone with `getprop`.
public struct DeviceDetails: Sendable, Equatable {
    public var manufacturer: String
    public var model: String
    public var androidVersion: String
    public var sdkLevel: Int?

    public init(manufacturer: String, model: String, androidVersion: String, sdkLevel: Int?) {
        self.manufacturer = manufacturer
        self.model = model
        self.androidVersion = androidVersion
        self.sdkLevel = sdkLevel
    }
}

// MARK: - Files

public enum FileKind: String, Sendable, Codable {
    case file
    case directory
    case symlink
    case other
}

/// A file or folder on either side (the Mac or the phone).
public struct FileItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    /// Absolute path. Local: POSIX path on the Mac. Remote: absolute path on the device.
    public let path: String
    public let name: String
    public let kind: FileKind
    public let size: Int64
    public let modified: Date?

    public init(path: String, name: String, kind: FileKind, size: Int64, modified: Date?) {
        self.path = path
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
    }

    public var isDirectory: Bool { kind == .directory }
    public var isHidden: Bool { name.hasPrefix(".") }

    public var fileExtension: String {
        guard !isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }
}

public struct StorageInfo: Sendable, Equatable {
    public let totalBytes: Int64
    public let usedBytes: Int64
    public let availableBytes: Int64

    public init(totalBytes: Int64, usedBytes: Int64, availableBytes: Int64) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
    }

    public var fractionUsed: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }
}

// MARK: - Errors

public enum DeviceError: Error, LocalizedError, Equatable {
    case adbNotFound
    case deviceDisconnected
    case unauthorized
    case permissionDenied(String)
    case notFound(String)
    case alreadyExists(String)
    case invalidName(String)
    case protectedPath(String)
    case noSpace
    case verificationFailed(String)
    case commandFailed(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .adbNotFound:
            return "adb (Android Platform Tools) was not found. Install it with “brew install --cask android-platform-tools”, or set its location in Settings."
        case .deviceDisconnected:
            return "The phone was disconnected. Reconnect the cable (or Wi-Fi) and try again."
        case .unauthorized:
            return "The phone hasn’t authorized this Mac yet. Unlock it and tap “Allow” on the USB debugging prompt."
        case .permissionDenied(let path):
            return "Android doesn’t allow access to “\(path)”. Apps’ private folders (like Android/data) are restricted."
        case .notFound(let path):
            return "“\(path)” no longer exists."
        case .alreadyExists(let path):
            return "An item named “\(RemotePath.name(path))” already exists."
        case .invalidName(let name):
            return "“\(name)” isn’t a valid name. Avoid / \\ : * ? \" < > |."
        case .protectedPath(let path):
            return "AndroBridge won’t delete or replace “\(path)” because it’s a top-level storage folder."
        case .noSpace:
            return "There isn’t enough free space on the destination."
        case .verificationFailed(let why):
            return "The copied data didn’t match the original (\(why)). The source was left untouched."
        case .commandFailed(let message):
            return message
        case .unsupported(let what):
            return what
        }
    }
}
