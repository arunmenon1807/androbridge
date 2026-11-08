import Foundation

/// A phone the file manager can talk to. The ADB transport (`AndroidDevice`) implements
/// this today; a future MTP transport would implement the same protocol so the browser,
/// transfer queue and UI don't change.
public protocol DeviceConnection: AnyObject, Sendable {
    var serial: String { get }
    var transportName: String { get }

    func details() async throws -> DeviceDetails
    func list(_ path: String) async throws -> [FileItem]
    func stat(_ path: String) async throws -> FileItem?
    func makeDirectory(_ path: String) async throws
    func rename(_ path: String, to newPath: String) async throws
    func delete(_ path: String) async throws
    func copy(_ path: String, to destination: String) async throws
    func storageInfo(_ path: String) async throws -> StorageInfo?

    /// Copies a remote file or folder to `localDestination`, which must not exist yet.
    func pull(_ remotePath: String, to localDestination: URL) async throws
    /// Copies a local file or folder to `remoteDestination`, which must not exist yet.
    func push(_ localSource: URL, to remoteDestination: String) async throws

    /// relative path → size, for every regular file under `path` (or just the file).
    func sizeManifest(_ path: String) async throws -> [String: Int64]
    /// relative path → lowercase SHA-256 hex, for every regular file under `path`.
    func hashManifest(_ path: String) async throws -> [String: String]
}

/// Rules that stop PixelBridge from deleting or overwriting things it shouldn't.
public enum SafetyPolicy {
    /// Shared-storage roots. Everything PixelBridge writes or deletes must be under one.
    public static let sharedStorageRoots = ["/sdcard", "/storage/emulated/0", "/storage/self/primary"]

    /// Standard top-level folders on shared storage; never deleted or replaced wholesale.
    public static let standardFolders: Set<String> = [
        "Alarms", "Android", "Audiobooks", "DCIM", "Documents", "Download", "Movies", "Music",
        "Notifications", "Pictures", "Podcasts", "Recordings", "Ringtones",
    ]

    /// The default home on the device.
    public static let defaultRoot = "/sdcard"

    /// True if `path` is somewhere PixelBridge may create, rename or delete items.
    public static func isWritableLocation(_ path: String) -> Bool {
        let p = RemotePath.normalize(path)
        for root in sharedStorageRoots where p == root || p.hasPrefix(root + "/") {
            return true
        }
        // Removable SD cards / USB OTG drives appear as /storage/XXXX-XXXX.
        let parts = RemotePath.components(p)
        if parts.count >= 2, parts[0] == "storage", isVolumeID(parts[1]) {
            return true
        }
        return false
    }

    /// True if deleting or replacing `path` should be refused outright.
    public static func isProtected(_ path: String) -> Bool {
        let p = RemotePath.normalize(path)
        guard isWritableLocation(p) else { return true }
        let parts = RemotePath.components(p)
        // Strip the root ("/sdcard" = 1 part, "/storage/emulated/0" = 3, "/storage/XXXX-XXXX" = 2).
        let rootDepth: Int
        if p == "/sdcard" || p.hasPrefix("/sdcard/") {
            rootDepth = 1
        } else if parts.count >= 3, parts[0] == "storage", parts[1] == "emulated" || parts[1] == "self" {
            rootDepth = 3
        } else {
            rootDepth = 2
        }
        let relative = Array(parts.dropFirst(rootDepth))
        if relative.isEmpty { return true }
        if relative.count == 1 && standardFolders.contains(relative[0]) { return true }
        // Android/data and Android/obb hold other apps' files.
        if relative.first == "Android" && relative.count <= 2 { return true }
        return false
    }

    static func isVolumeID(_ s: String) -> Bool {
        // e.g. "1A2B-3C4D"
        let parts = s.split(separator: "-")
        return parts.count == 2 && parts.allSatisfy { $0.count == 4 && $0.allSatisfy(\.isHexDigit) }
    }
}
