import Foundation

/// File operations on one phone over ADB (USB or Wi-Fi). Implements `DeviceConnection`.
///
/// Read operations run `adb shell` with every path quoted by `ShellQuoting`.
/// Transfers use `adb pull` / `adb push`, which take paths as separate argv entries.
public final class AndroidDevice: DeviceConnection, @unchecked Sendable {
    public let serial: String
    public let transportName = "ADB"
    private let client: ADBClient

    public init(serial: String, client: ADBClient) {
        self.serial = serial
        self.client = client
    }

    // MARK: Shell helper

    /// Runs one command line on the device and returns stdout. Throws a typed error
    /// on failure. `adb shell` returns the remote exit code (adb ≥ 1.0.39).
    @discardableResult
    func shell(_ commandLine: String, path: String? = nil, timeout: TimeInterval? = 60,
               allowFailure: Bool = false) async throws -> ProcessResult {
        let result = try await client.run(serial: serial, ["shell", commandLine], timeout: timeout)
        if !result.succeeded && !allowFailure {
            let text = result.stderrString.isEmpty ? result.stdoutString : result.stderrString
            throw ADBOutputParser.classifyError(text, path: path)
        }
        // adb itself failing (device gone) can also surface with exit code 1 and text on stderr.
        if result.exitCode != 0, allowFailure {
            let err = result.stderrString.lowercased()
            if err.contains("no devices") || err.contains("device offline") || err.contains("not found")
                && err.contains("device") || err.contains("unauthorized") {
                throw ADBOutputParser.classifyError(result.stderrString, path: path)
            }
        }
        return result
    }

    // MARK: DeviceConnection

    public func details() async throws -> DeviceDetails {
        let cmd = "getprop ro.product.manufacturer; getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.version.sdk"
        let out = try await shell(cmd, timeout: 15).stdoutString
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func line(_ i: Int) -> String { i < lines.count ? lines[i] : "" }
        return DeviceDetails(manufacturer: line(0), model: line(1), androidVersion: line(2), sdkLevel: Int(line(3)))
    }

    public func list(_ path: String) async throws -> [FileItem] {
        let dir = RemotePath.normalize(path)
        // `stat -L` follows symlinks so /sdcard-style links show as folders.
        // Per-entry errors (broken links, permission) go to stderr and are ignored
        // as long as the directory itself is readable.
        // `find .` after `cd` (not `find DIR`): find doesn't follow a symlinked starting
        // point, and /sdcard is a symlink on every Android version.
        let cmd = "cd \(ShellQuoting.quote(dir)) && find . -mindepth 1 -maxdepth 1 -exec stat -L -c \(ShellQuoting.quote(ADBOutputParser.statFormat)) {} +"
        let result = try await shell(cmd, path: dir, timeout: 60, allowFailure: true)
        let items = ADBOutputParser.parseListing(result.stdoutString, directory: dir)
        if result.exitCode != 0 && items.isEmpty {
            let err = result.stderrString
            // An empty folder makes find exit 0; failure with no output means the cd/find failed.
            if err.lowercased().contains("permission denied") { throw DeviceError.permissionDenied(dir) }
            if err.lowercased().contains("no such file") { throw DeviceError.notFound(dir) }
            if !err.isEmpty { throw ADBOutputParser.classifyError(err, path: dir) }
        }
        return items
    }

    public func stat(_ path: String) async throws -> FileItem? {
        let p = RemotePath.normalize(path)
        let cmd = "stat -L -c \(ShellQuoting.quote(ADBOutputParser.statFormat)) -- \(ShellQuoting.quote(p))"
        let result = try await shell(cmd, path: p, timeout: 15, allowFailure: true)
        if result.exitCode != 0 {
            if result.stderrString.lowercased().contains("no such file") { return nil }
            if result.stderrString.lowercased().contains("permission denied") { throw DeviceError.permissionDenied(p) }
            throw ADBOutputParser.classifyError(result.stderrString, path: p)
        }
        return ADBOutputParser.parseListing(result.stdoutString, directory: RemotePath.parent(p)).first
    }

    public func exists(_ path: String) async throws -> Bool {
        try await stat(path) != nil
    }

    public func makeDirectory(_ path: String) async throws {
        let p = RemotePath.normalize(path)
        guard SafetyPolicy.isWritableLocation(p) else { throw DeviceError.permissionDenied(p) }
        guard RemotePath.isValidName(RemotePath.name(p)) else { throw DeviceError.invalidName(RemotePath.name(p)) }
        if try await exists(p) { throw DeviceError.alreadyExists(p) }
        try await shell(ShellQuoting.command("mkdir", ["--", p]), path: p)
    }

    /// Creates `path` and any missing parents (used when pushing nested folders).
    func makeDirectories(_ path: String) async throws {
        let p = RemotePath.normalize(path)
        guard SafetyPolicy.isWritableLocation(p) else { throw DeviceError.permissionDenied(p) }
        try await shell(ShellQuoting.command("mkdir", ["-p", "--", p]), path: p)
    }

    public func rename(_ path: String, to newPath: String) async throws {
        let src = RemotePath.normalize(path)
        let dst = RemotePath.normalize(newPath)
        guard !SafetyPolicy.isProtected(src) else { throw DeviceError.protectedPath(src) }
        guard SafetyPolicy.isWritableLocation(dst) else { throw DeviceError.permissionDenied(dst) }
        guard RemotePath.isValidName(RemotePath.name(dst)) else { throw DeviceError.invalidName(RemotePath.name(dst)) }
        // Never overwrite: check first, and use mv -n as a second guard.
        if try await exists(dst) { throw DeviceError.alreadyExists(dst) }
        try await shell(ShellQuoting.command("mv", ["-n", "--", src, dst]), path: src)
        guard try await exists(dst) else {
            throw DeviceError.commandFailed("Rename didn’t complete on the device.")
        }
    }

    public func delete(_ path: String) async throws {
        let p = RemotePath.normalize(path)
        guard !SafetyPolicy.isProtected(p) else { throw DeviceError.protectedPath(p) }
        try await shell(ShellQuoting.command("rm", ["-rf", "--", p]), path: p, timeout: 600)
        if try await exists(p) {
            throw DeviceError.commandFailed("Some items in “\(RemotePath.name(p))” couldn’t be deleted.")
        }
    }

    public func copy(_ path: String, to destination: String) async throws {
        let src = RemotePath.normalize(path)
        let dst = RemotePath.normalize(destination)
        guard SafetyPolicy.isWritableLocation(dst) else { throw DeviceError.permissionDenied(dst) }
        if try await exists(dst) { throw DeviceError.alreadyExists(dst) }
        try await shell(ShellQuoting.command("cp", ["-R", "-p", "--", src, dst]), path: src, timeout: nil)
    }

    public func storageInfo(_ path: String) async throws -> StorageInfo? {
        let result = try await shell(ShellQuoting.command("df", ["-k", RemotePath.normalize(path)]),
                                     timeout: 15, allowFailure: true)
        return ADBOutputParser.parseDF(result.stdoutString)
    }

    public func pull(_ remotePath: String, to localDestination: URL) async throws {
        let src = RemotePath.normalize(remotePath)
        // -a keeps the original modification time.
        let result = try await client.run(serial: serial, ["pull", "-a", src, localDestination.path], timeout: nil)
        if !result.succeeded {
            throw ADBOutputParser.classifyError(result.stderrString + result.stdoutString, path: src)
        }
    }

    public func push(_ localSource: URL, to remoteDestination: String) async throws {
        let dst = RemotePath.normalize(remoteDestination)
        guard SafetyPolicy.isWritableLocation(dst) else { throw DeviceError.permissionDenied(dst) }
        let result = try await client.run(serial: serial, ["push", localSource.path, dst], timeout: nil)
        if !result.succeeded {
            throw ADBOutputParser.classifyError(result.stderrString + result.stdoutString, path: dst)
        }
    }

    public func sizeManifest(_ path: String) async throws -> [String: Int64] {
        let p = RemotePath.normalize(path)
        guard let item = try await stat(p) else { throw DeviceError.notFound(p) }
        if !item.isDirectory {
            return [item.name: item.size]
        }
        let cmd = "cd \(ShellQuoting.quote(p)) && find . -type f -exec stat -c \(ShellQuoting.quote("%s\t%n")) {} +"
        let result = try await shell(cmd, path: p, timeout: 300)
        return ADBOutputParser.parseSizeManifest(result.stdoutString)
    }

    public func hashManifest(_ path: String) async throws -> [String: String] {
        let p = RemotePath.normalize(path)
        guard let item = try await stat(p) else { throw DeviceError.notFound(p) }
        if !item.isDirectory {
            let result = try await shell(ShellQuoting.command("sha256sum", ["--", p]), path: p, timeout: nil)
            guard let hash = result.stdoutString.split(separator: " ").first, hash.count == 64 else {
                throw DeviceError.commandFailed("Couldn’t compute a checksum on the device.")
            }
            return [item.name: hash.lowercased()]
        }
        let cmd = "cd \(ShellQuoting.quote(p)) && find . -type f -exec sha256sum {} +"
        let result = try await shell(cmd, path: p, timeout: nil)
        return ADBOutputParser.parseSha256Manifest(result.stdoutString)
    }
}
