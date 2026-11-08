import AppKit
import AndroBridgeCore
import SwiftUI
import UniformTypeIdentifiers

extension FileItem {
    var modifiedSortKey: Date { modified ?? .distantPast }
    var sizeSortKey: Int64 { isDirectory ? -1 : size }

    var kindDescription: String {
        if isDirectory { return "Folder" }
        if let type = UTType(filenameExtension: fileExtension), let d = type.localizedDescription {
            return d.prefix(1).uppercased() + d.dropFirst()
        }
        return fileExtension.isEmpty ? "Document" : fileExtension.uppercased() + " file"
    }

    var utType: UTType {
        isDirectory ? .folder : (UTType(filenameExtension: fileExtension) ?? .data)
    }
}

enum Format {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func size(_ n: Int64) -> String { bytes.string(fromByteCount: n) }

    static func speed(_ bps: Double) -> String { bytes.string(fromByteCount: Int64(bps)) + "/s" }

    static func duration(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: seconds) ?? ""
    }

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
}

/// Caches Finder icons per file type (looking up an icon per row is slow).
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: FileItem) -> NSImage {
        let key = item.isDirectory ? "public.folder" : item.utType.identifier
        if let img = cache[key] { return img }
        let img = NSWorkspace.shared.icon(for: item.utType)
        cache[key] = img
        return img
    }
}
