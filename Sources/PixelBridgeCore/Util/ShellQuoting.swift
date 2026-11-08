import Foundation

/// Quoting for commands that run inside `adb shell` on the phone.
///
/// `adb shell a b c` joins its arguments with spaces and hands the string to the phone's
/// `/system/bin/sh`. Every argument we pass therefore has to be quoted for a POSIX shell,
/// or a file called `My "Trip" $HOME.jpg` would be reinterpreted on the device.
public enum ShellQuoting {
    /// Wraps `value` in single quotes, escaping embedded single quotes as `'\''`.
    /// Inside single quotes a POSIX shell treats every other character literally.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Builds one command line from a program name and arguments, quoting every argument.
    public static func command(_ program: String, _ arguments: [String]) -> String {
        ([program] + arguments.map(quote)).joined(separator: " ")
    }
}

/// Helpers for absolute POSIX paths on the Android device.
public enum RemotePath {
    public static func join(_ base: String, _ name: String) -> String {
        if base.hasSuffix("/") { return base + name }
        return base + "/" + name
    }

    public static func parent(_ path: String) -> String {
        let trimmed = normalize(path)
        guard trimmed != "/" else { return "/" }
        guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    public static func name(_ path: String) -> String {
        let trimmed = normalize(path)
        guard trimmed != "/" else { return "/" }
        return String(trimmed.split(separator: "/", omittingEmptySubsequences: true).last ?? "")
    }

    /// Collapses duplicate slashes and removes a trailing slash.
    public static func normalize(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + parts.joined(separator: "/")
    }

    /// Path components after the leading slash, for breadcrumbs.
    public static func components(_ path: String) -> [String] {
        normalize(path).split(separator: "/").map(String.init)
    }

    /// True if `name` is a valid single file or folder name on Android shared storage.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        if name.contains("/") || name.contains("\0") { return false }
        // FAT/sdcardfs-style restrictions that shared storage enforces.
        let forbidden: Set<Character> = ["\\", ":", "*", "?", "\"", "<", ">", "|"]
        if name.contains(where: { forbidden.contains($0) }) { return false }
        return name.utf8.count <= 255
    }
}
