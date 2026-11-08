import Foundation

/// Pure functions that turn adb text output into models. Kept separate so they can be
/// unit-tested against captured output without a phone.
public enum ADBOutputParser {

    // MARK: adb devices -l

    /// Parses `adb devices -l`, e.g.
    /// `1A2B3C4D  device usb:1-1 product:husky model:Pixel_8_Pro device:husky transport_id:3`
    public static func parseDevices(_ output: String) -> [ADBDevice] {
        var devices: [ADBDevice] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("List of devices") || line.hasPrefix("*") { continue }
            // serial, then whitespace, then state (which may itself contain spaces:
            // "no permissions (user in plugdev group...)").
            let tokens = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard tokens.count == 2 else { continue }
            let serial = String(tokens[0])
            let rest = tokens[1].trimmingCharacters(in: .whitespaces)

            let state: DeviceState
            var attributeText: Substring
            if rest.hasPrefix("no permissions") {
                state = .noPermissions
                // Attributes, if any, follow the closing bracket of the explanation.
                if let close = rest.firstIndex(of: "]") {
                    attributeText = rest[rest.index(after: close)...]
                } else {
                    attributeText = ""
                }
            } else {
                let parts = rest.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
                state = DeviceState(adbValue: String(parts.first ?? ""))
                attributeText = parts.count > 1 ? parts[1] : ""
            }

            var attrs: [String: String] = [:]
            for token in attributeText.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                guard let colon = token.firstIndex(of: ":") else { continue }
                attrs[String(token[..<colon])] = String(token[token.index(after: colon)...])
            }
            devices.append(ADBDevice(
                serial: serial,
                state: state,
                model: attrs["model"],
                product: attrs["product"],
                deviceName: attrs["device"],
                transportID: attrs["transport_id"],
                usbPath: attrs["usb"]
            ))
        }
        return devices
    }

    // MARK: directory listing

    /// Field separator used in our `stat -c` format. A tab cannot appear in the first
    /// three fields; the name is last so a tab inside a name is still parsed correctly.
    public static let fieldSeparator: Character = "\t"

    /// The `stat` format used by `AndroidDevice.list`: type, size, mtime (epoch), path.
    public static let statFormat = "%F\t%s\t%Y\t%n"

    /// Parses lines produced by `find DIR -mindepth 1 -maxdepth 1 -exec stat -L -c FORMAT {} +`.
    /// `directory` is used to turn each `%n` into an absolute path and a name.
    public static func parseListing(_ output: String, directory: String) -> [FileItem] {
        var items: [FileItem] = []
        let base = RemotePath.normalize(directory)
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: fieldSeparator, maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4 else { continue }
            let kind = fileKind(fromStatType: String(fields[0]))
            let size = Int64(fields[1]) ?? 0
            let mtime = TimeInterval(fields[2]).map { Date(timeIntervalSince1970: $0) }
            var reported = String(fields[3])
            if reported.hasSuffix("\r") { reported.removeLast() }
            // find prints "DIR/name"; take the last component as the name.
            let name: String
            if reported.hasPrefix(base + "/") {
                name = String(reported.dropFirst(base.count + 1))
            } else if base == "/" && reported.hasPrefix("/") {
                name = String(reported.dropFirst())
            } else {
                name = RemotePath.name(reported)
            }
            guard !name.isEmpty, !name.contains("/") else { continue }
            items.append(FileItem(
                path: RemotePath.join(base, name),
                name: name,
                kind: kind,
                size: kind == .directory ? 0 : size,
                modified: mtime
            ))
        }
        return items
    }

    public static func fileKind(fromStatType type: String) -> FileKind {
        switch type {
        case "directory": return .directory
        case "regular file", "regular empty file": return .file
        case "symbolic link": return .symlink
        default: return .other
        }
    }

    // MARK: df

    /// Parses `df -k PATH` (toybox). Uses the last data line:
    /// `/dev/fuse  115249236 41853332 73264832  37% /storage/emulated`
    public static func parseDF(_ output: String) -> StorageInfo? {
        let lines = output.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("Filesystem") }
        guard let last = lines.last else { return nil }
        let cols = last.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard cols.count >= 4,
              let total = Int64(cols[1]), let used = Int64(cols[2]), let avail = Int64(cols[3])
        else { return nil }
        return StorageInfo(totalBytes: total * 1024, usedBytes: used * 1024, availableBytes: avail * 1024)
    }

    // MARK: manifests (verification)

    /// Parses `sha256sum` output (`<hex>  ./relative/path`) into relative path → hash.
    public static func parseSha256Manifest(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.count > 66 else { continue }
            let hash = String(line.prefix(64)).lowercased()
            guard hash.allSatisfy(\.isHexDigit) else { continue }
            var path = String(line.dropFirst(64)).drop(while: { $0 == " " || $0 == "*" })
            if path.hasPrefix("./") { path = path.dropFirst(2) }
            var p = String(path)
            if p.hasSuffix("\r") { p.removeLast() }
            result[p] = hash
        }
        return result
    }

    /// Parses lines of `<size>\t./relative/path` into relative path → size.
    public static func parseSizeManifest(_ output: String) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let size = Int64(parts[0]) else { continue }
            var path = Substring(parts[1])
            if path.hasPrefix("./") { path = path.dropFirst(2) }
            var p = String(path)
            if p.hasSuffix("\r") { p.removeLast() }
            result[p] = size
        }
        return result
    }

    // MARK: wireless

    public struct MDNSService: Hashable, Sendable {
        public let name: String
        public let type: String
        public let address: String
        public var isPairing: Bool { type.contains("_adb-tls-pairing") }
        public var isConnect: Bool { type.contains("_adb-tls-connect") }
    }

    /// Parses `adb mdns services`:
    /// `adb-1A2B3C4D-xYz12  _adb-tls-connect._tcp  192.168.1.20:41235`
    public static func parseMDNSServices(_ output: String) -> [MDNSService] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 3, cols[1].hasPrefix("_adb") else { return nil }
            return MDNSService(name: String(cols[0]), type: String(cols[1]), address: String(cols[2]))
        }
    }

    // MARK: errors

    /// Maps adb's error text to a typed error.
    public static func classifyError(_ text: String, path: String? = nil) -> DeviceError {
        let lower = text.lowercased()
        if lower.contains("device unauthorized") || lower.contains("unauthorized") {
            return .unauthorized
        }
        if lower.contains("no devices/emulators found") || lower.contains("device not found")
            || lower.contains("device offline") || lower.contains("not found: device")
            || lower.contains("closed") && lower.contains("protocol fault")
            || lower.contains("no devices") || lower.contains("device '") && lower.contains("not found") {
            return .deviceDisconnected
        }
        if lower.contains("permission denied") || lower.contains("operation not permitted") {
            return .permissionDenied(path ?? "")
        }
        if lower.contains("no space left") {
            return .noSpace
        }
        if lower.contains("no such file or directory") || lower.contains("does not exist") {
            return .notFound(path ?? "")
        }
        if lower.contains("file exists") {
            return .alreadyExists(path ?? "")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .commandFailed(trimmed.isEmpty ? "adb reported an unknown error." : trimmed)
    }
}
