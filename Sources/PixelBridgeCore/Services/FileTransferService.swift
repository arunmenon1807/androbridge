import Foundation

public enum TransferDirection: String, Codable, Sendable {
    case toMac
    case toDevice
}

public enum TransferOperation: String, Codable, Sendable {
    case copy
    case move
}

public enum ConflictResolution: String, Codable, Sendable {
    case replace
    case keepBoth
    case skip
}

/// What the user asked for: one file or folder to transfer.
public struct TransferRequest: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let direction: TransferDirection
    public let operation: TransferOperation
    /// Local POSIX path (toDevice) or device path (toMac).
    public let sourcePath: String
    /// Local folder (toMac) or device folder (toDevice).
    public let destinationDirectory: String
    public let deviceSerial: String
    public let deviceName: String

    public init(id: UUID = UUID(), direction: TransferDirection, operation: TransferOperation,
                sourcePath: String, destinationDirectory: String, deviceSerial: String, deviceName: String) {
        self.id = id
        self.direction = direction
        self.operation = operation
        self.sourcePath = sourcePath
        self.destinationDirectory = destinationDirectory
        self.deviceSerial = deviceSerial
        self.deviceName = deviceName
    }

    public var displayName: String {
        direction == .toMac ? RemotePath.name(sourcePath) : (sourcePath as NSString).lastPathComponent
    }

    /// A fresh copy with a new id, for "Retry".
    public func retried() -> TransferRequest {
        TransferRequest(direction: direction, operation: operation, sourcePath: sourcePath,
                        destinationDirectory: destinationDirectory, deviceSerial: deviceSerial, deviceName: deviceName)
    }
}

public struct ConflictContext: Sendable {
    public let request: TransferRequest
    public let existingName: String
    public let existingIsDirectory: Bool
}

public enum TransferOutcome: Sendable, Equatable {
    case completed(finalPath: String, bytes: Int64, verified: VerificationLevel)
    case skipped
    /// The copy succeeded and was verified but the source couldn't be removed (move only).
    case copiedSourceKept(finalPath: String, bytes: Int64, reason: String)
}

public enum VerificationLevel: String, Codable, Sendable {
    case size
    case sha256
}

public struct TransferOptions: Sendable {
    /// Compare SHA-256 of every file after copying (in addition to sizes).
    public var verifyChecksums: Bool
    public init(verifyChecksums: Bool = true) {
        self.verifyChecksums = verifyChecksums
    }
}

/// Performs a single verified transfer.
///
/// Safety model:
/// 1. Data is written to a hidden `.pixelbridge-….partial` item next to the destination.
/// 2. The partial copy is verified against the source (file list and sizes, plus SHA-256
///    when enabled; moves always use SHA-256).
/// 3. Only then is it renamed into place. "Replace" moves the old Mac file to the Trash
///    first; on the phone the old item is deleted only after the new copy is verified.
/// 4. For a move, the source is removed only after step 3 succeeds. Mac sources go to the Trash.
/// Cancelling or failing at any point deletes the partial item and leaves the source alone.
public final class FileTransferService: @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (_ bytesDone: Int64, _ totalBytes: Int64, _ phase: TransferPhase) -> Void
    public typealias ConflictHandler = @Sendable (ConflictContext) async -> ConflictResolution

    public init() {}

    public func perform(_ request: TransferRequest, device: DeviceConnection, options: TransferOptions,
                        onConflict: ConflictHandler, progress: @escaping ProgressHandler) async throws -> TransferOutcome {
        switch request.direction {
        case .toMac:
            return try await download(request, device: device, options: options, onConflict: onConflict, progress: progress)
        case .toDevice:
            return try await upload(request, device: device, options: options, onConflict: onConflict, progress: progress)
        }
    }

    // MARK: Phone → Mac

    private func download(_ request: TransferRequest, device: DeviceConnection, options: TransferOptions,
                          onConflict: ConflictHandler, progress: @escaping ProgressHandler) async throws -> TransferOutcome {
        let fm = FileManager.default
        let src = RemotePath.normalize(request.sourcePath)
        progress(0, 0, .preparing)
        guard let srcItem = try await device.stat(src) else { throw DeviceError.notFound(src) }
        let remoteSizes = try await device.sizeManifest(src)
        let total = remoteSizes.values.reduce(0, +)

        let destDir = URL(fileURLWithPath: request.destinationDirectory, isDirectory: true)
        guard LocalFileService.isDirectory(destDir) else { throw DeviceError.notFound(destDir.path) }
        var finalName = srcItem.name
        var replaceExisting = false
        if LocalFileService.exists(destDir.appendingPathComponent(finalName)) {
            let existing = destDir.appendingPathComponent(finalName)
            switch await onConflict(ConflictContext(request: request, existingName: finalName,
                                                    existingIsDirectory: LocalFileService.isDirectory(existing))) {
            case .skip: return .skipped
            case .keepBoth:
                finalName = ConflictNaming.uniqueName(for: finalName, isDirectory: srcItem.isDirectory) {
                    LocalFileService.exists(destDir.appendingPathComponent($0))
                }
            case .replace: replaceExisting = true
            }
        }
        if let free = LocalFileService.availableCapacity(at: destDir), free < total {
            throw DeviceError.noSpace
        }

        let staging = destDir.appendingPathComponent(".pixelbridge-\(UUID().uuidString).partial")
        let finalURL = destDir.appendingPathComponent(finalName)
        var stagingOwned = true
        defer {
            if stagingOwned { try? fm.removeItem(at: staging) }
        }

        // Progress: watch the partial item grow on disk.
        let poller = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                progress(LocalFileService.totalSize(staging), total, .transferring)
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        defer { poller.cancel() }

        try await device.pull(src, to: staging)
        poller.cancel()
        try Task.checkCancellation()
        progress(total, total, .verifying)

        // Verify.
        let localSizes = try LocalFileService.sizeManifest(staging, fileKey: srcItem.name)
        try Self.compare(source: remoteSizes, copy: localSizes)
        let useHash = options.verifyChecksums || request.operation == .move
        if useHash {
            let remoteHashes = try await device.hashManifest(src)
            let localHashes = try LocalFileService.hashManifest(staging, fileKey: srcItem.name)
            try Self.compareHashes(source: remoteHashes, copy: localHashes)
        }

        // Finalize.
        if replaceExisting, LocalFileService.exists(finalURL) {
            try LocalFileService.moveToTrash(finalURL)
        }
        guard !LocalFileService.exists(finalURL) else { throw DeviceError.alreadyExists(finalURL.path) }
        try fm.moveItem(at: staging, to: finalURL)
        stagingOwned = false
        progress(total, total, .finishing)

        let level: VerificationLevel = useHash ? .sha256 : .size
        if request.operation == .move {
            do {
                try await device.delete(src)
            } catch {
                return .copiedSourceKept(finalPath: finalURL.path, bytes: total, reason: error.localizedDescription)
            }
        }
        return .completed(finalPath: finalURL.path, bytes: total, verified: level)
    }

    // MARK: Mac → Phone

    private func upload(_ request: TransferRequest, device: DeviceConnection, options: TransferOptions,
                        onConflict: ConflictHandler, progress: @escaping ProgressHandler) async throws -> TransferOutcome {
        let srcURL = URL(fileURLWithPath: request.sourcePath)
        progress(0, 0, .preparing)
        guard LocalFileService.exists(srcURL) else { throw DeviceError.notFound(srcURL.path) }
        let isDir = LocalFileService.isDirectory(srcURL)
        let localSizes = try LocalFileService.sizeManifest(srcURL)
        let total = localSizes.values.reduce(0, +)

        let destDir = RemotePath.normalize(request.destinationDirectory)
        guard SafetyPolicy.isWritableLocation(destDir) else { throw DeviceError.permissionDenied(destDir) }
        guard let destItem = try await device.stat(destDir), destItem.isDirectory else {
            throw DeviceError.notFound(destDir)
        }
        let name = srcURL.lastPathComponent
        guard RemotePath.isValidName(name) else { throw DeviceError.invalidName(name) }

        var finalName = name
        var replaceExisting = false
        if let existing = try await device.stat(RemotePath.join(destDir, name)) {
            switch await onConflict(ConflictContext(request: request, existingName: name,
                                                    existingIsDirectory: existing.isDirectory)) {
            case .skip: return .skipped
            case .keepBoth:
                let siblings = Set(try await device.list(destDir).map(\.name))
                finalName = ConflictNaming.uniqueName(for: name, isDirectory: isDir) { siblings.contains($0) }
            case .replace:
                guard !SafetyPolicy.isProtected(RemotePath.join(destDir, name)) else {
                    throw DeviceError.protectedPath(RemotePath.join(destDir, name))
                }
                replaceExisting = true
            }
        }
        if let info = try? await device.storageInfo(destDir), info.availableBytes < total {
            throw DeviceError.noSpace
        }

        let staging = RemotePath.join(destDir, ".pixelbridge-\(UUID().uuidString).partial")
        let finalPath = RemotePath.join(destDir, finalName)
        var stagingOwned = true

        do {
            let poller = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { break }
                    if let sizes = try? await device.sizeManifest(staging) {
                        progress(sizes.values.reduce(0, +), total, .transferring)
                    }
                }
            }
            defer { poller.cancel() }
            progress(0, total, .transferring)

            try await device.push(srcURL, to: staging)
            poller.cancel()
            try Task.checkCancellation()
            progress(total, total, .verifying)

            // Verify. For a single file the device manifest is keyed by the staging name.
            let stagingName = RemotePath.name(staging)
            var remoteSizes = try await device.sizeManifest(staging)
            if !isDir, let v = remoteSizes.removeValue(forKey: stagingName) { remoteSizes[name] = v }
            try Self.compare(source: localSizes, copy: remoteSizes)
            let useHash = options.verifyChecksums || request.operation == .move
            if useHash {
                var remoteHashes = try await device.hashManifest(staging)
                if !isDir, let v = remoteHashes.removeValue(forKey: stagingName) { remoteHashes[name] = v }
                let localHashes = try LocalFileService.hashManifest(srcURL)
                try Self.compareHashes(source: localHashes, copy: remoteHashes)
            }

            // Finalize.
            if replaceExisting, try await device.stat(finalPath) != nil {
                try await device.delete(finalPath)
            }
            try await device.rename(staging, to: finalPath)
            stagingOwned = false
            progress(total, total, .finishing)

            let level: VerificationLevel = useHash ? .sha256 : .size
            if request.operation == .move {
                do {
                    try LocalFileService.moveToTrash(srcURL)
                } catch {
                    return .copiedSourceKept(finalPath: finalPath, bytes: total, reason: error.localizedDescription)
                }
            }
            return .completed(finalPath: finalPath, bytes: total, verified: level)
        } catch {
            if stagingOwned {
                // Clean up even if we were cancelled: run outside the cancelled task.
                let cleanup = Task.detached { try? await device.delete(staging) }
                _ = await cleanup.value
            }
            throw error
        }
    }

    // MARK: Verification

    static func compare(source: [String: Int64], copy: [String: Int64]) throws {
        if source.count != copy.count {
            throw DeviceError.verificationFailed("expected \(source.count) files, found \(copy.count)")
        }
        for (path, size) in source {
            guard let other = copy[path] else {
                throw DeviceError.verificationFailed("“\(path)” is missing from the copy")
            }
            if other != size {
                throw DeviceError.verificationFailed("“\(path)” is \(other) bytes, expected \(size)")
            }
        }
    }

    static func compareHashes(source: [String: String], copy: [String: String]) throws {
        if source.count != copy.count {
            throw DeviceError.verificationFailed("expected \(source.count) files, found \(copy.count)")
        }
        for (path, hash) in source where copy[path] != hash {
            throw DeviceError.verificationFailed("checksum mismatch for “\(path)”")
        }
    }
}

public enum TransferPhase: String, Codable, Sendable {
    case preparing
    case transferring
    case verifying
    case finishing
}
