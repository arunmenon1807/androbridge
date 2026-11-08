import CryptoKit
import Foundation

/// File operations on the Mac side.
public enum LocalFileService {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
    ]

    public static func list(_ directory: URL) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: []
        )
        return urls.compactMap { item(for: $0) }
    }

    public static func item(for url: URL) -> FileItem? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        // Follow symlinks for the kind, like Finder.
        let resolved = values.isSymbolicLink == true ? url.resolvingSymlinksInPath() : url
        let isDir = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? values.isDirectory ?? false
        let isPackage = (try? resolved.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        return FileItem(
            path: url.path,
            name: url.lastPathComponent,
            kind: isDir && !isPackage ? .directory : .file,
            size: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate
        )
    }

    public static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    public static func makeDirectory(_ url: URL) throws {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name != "/" else {
            throw DeviceError.invalidName(url.lastPathComponent)
        }
        if exists(url) { throw DeviceError.alreadyExists(url.path) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    public static func rename(_ url: URL, to newName: String) throws -> URL {
        guard !newName.isEmpty, !newName.contains("/"), newName != ".", newName != ".." else {
            throw DeviceError.invalidName(newName)
        }
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
        if exists(dest) { throw DeviceError.alreadyExists(dest.path) }
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }

    /// Moves to the Trash (recoverable) rather than deleting.
    public static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    public static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// A copy of `url` with no cached resource values.
    ///
    /// Foundation caches `resourceValues` on the underlying NSURL, and copies of a `URL`
    /// share it. The transfer progress poller and the verifier look at the same staging
    /// URL, so without this the verifier could read a size cached mid-transfer.
    static func uncached(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath)
    }

    /// Total bytes of regular files under `url` (or the file's own size).
    public static func totalSize(_ url: URL) -> Int64 {
        let url = uncached(url)
        if !isDirectory(url) {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let f = e?.nextObject() as? URL {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    /// relative path → size for every regular file. For a single file, the key is `fileKey`
    /// (defaults to the file's own name) so it can be compared with the other side.
    public static func sizeManifest(_ url: URL, fileKey: String? = nil) throws -> [String: Int64] {
        let url = uncached(url)
        if !isDirectory(url) {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return [fileKey ?? url.lastPathComponent: Int64(size)]
        }
        var result: [String: Int64] = [:]
        for (rel, file) in try regularFiles(under: url) {
            result[rel] = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        return result
    }

    public static func hashManifest(_ url: URL, fileKey: String? = nil) throws -> [String: String] {
        let url = uncached(url)
        if !isDirectory(url) {
            return [fileKey ?? url.lastPathComponent: try sha256(of: url)]
        }
        var result: [String: String] = [:]
        for (rel, file) in try regularFiles(under: url) {
            try Task.checkCancellation()
            result[rel] = try sha256(of: file)
        }
        return result
    }

    /// Streams the file through SHA-256 in 4 MB chunks (works for multi-GB videos).
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func regularFiles(under root: URL) throws -> [(String, URL)] {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        var out: [(String, URL)] = []
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) else { return [] }
        while let f = e.nextObject() as? URL {
            guard (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let full = f.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(rootPath + "/") else { continue }
            out.append((String(full.dropFirst(rootPath.count + 1)), f))
        }
        return out
    }
}

/// Finder-style "Keep Both" naming: "Photo.jpg" → "Photo 2.jpg" → "Photo 3.jpg".
public enum ConflictNaming {
    public static func uniqueName(for name: String, isDirectory: Bool, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let (stem, ext) = split(name, isDirectory: isDirectory)
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !taken(candidate) { return candidate }
            n += 1
        }
    }

    static func split(_ name: String, isDirectory: Bool) -> (String, String) {
        guard !isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }
}
