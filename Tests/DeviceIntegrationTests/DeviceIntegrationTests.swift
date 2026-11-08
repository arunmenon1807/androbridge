import XCTest
@testable import AndroBridgeCore

/// End-to-end tests against a real phone or emulator over ADB.
///
/// Skipped unless `ANDROBRIDGE_DEVICE_TESTS=1`. Uses the device in
/// `ANDROBRIDGE_DEVICE_SERIAL`, or the first authorized device.
/// Everything is created under /sdcard/Download/AndroBridgeTest-<uuid> and removed afterwards.
///
///     ANDROBRIDGE_DEVICE_TESTS=1 swift test --filter DeviceIntegrationTests
final class DeviceIntegrationTests: XCTestCase {
    var client: ADBClient!
    var device: AndroidDevice!
    var remoteRoot: String!
    var localRoot: URL!
    let engine = FileTransferService()

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["ANDROBRIDGE_DEVICE_TESTS"] == "1" else {
            throw XCTSkip("Set ANDROBRIDGE_DEVICE_TESTS=1 to run tests against a connected device.")
        }
        guard let adb = ADBLocator.locate() else { throw XCTSkip("adb not found") }
        client = ADBClient(adbURL: adb)
        let devices = try await client.devices().filter { $0.state.isReady }
        let wanted = ProcessInfo.processInfo.environment["ANDROBRIDGE_DEVICE_SERIAL"]
        guard let target = devices.first(where: { wanted == nil || $0.serial == wanted }) else {
            throw XCTSkip("No authorized device connected.")
        }
        device = AndroidDevice(serial: target.serial, client: client)
        remoteRoot = "/sdcard/Download/AndroBridgeTest-\(UUID().uuidString.prefix(8))"
        try await device.makeDirectory(remoteRoot)
        localRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pb-device-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        print("Device under test: \(target.serial) (\(target.displayName))")
    }

    override func tearDown() async throws {
        if let device, let remoteRoot { try? await device.delete(remoteRoot) }
        if let localRoot { try? FileManager.default.removeItem(at: localRoot) }
    }

    private func request(_ dir: TransferDirection, _ op: TransferOperation = .copy, src: String, dest: String) -> TransferRequest {
        TransferRequest(direction: dir, operation: op, sourcePath: src, destinationDirectory: dest,
                        deviceSerial: device.serial, deviceName: "test")
    }

    private func run(_ r: TransferRequest, conflict: ConflictResolution = .keepBoth, checksums: Bool = true) async throws -> TransferOutcome {
        try await engine.perform(r, device: device, options: TransferOptions(verifyChecksums: checksums),
                                 onConflict: { _ in conflict }, progress: { _, _, _ in })
    }

    func testDetailsListingAndStorage() async throws {
        let details = try await device.details()
        XCTAssertFalse(details.model.isEmpty)
        let names = Set(try await device.list("/sdcard").map(\.name))
        XCTAssertTrue(names.contains("Download"), "got \(names)")
        let info = try await device.storageInfo("/sdcard")
        XCTAssertNotNil(info)
        XCTAssertGreaterThan(info?.totalBytes ?? 0, 0)
    }

    func testCreateRenameDeleteWithUnicodeAndSpaces() async throws {
        let folder = RemotePath.join(remoteRoot, "Nëw Földer 日本 'q' $x")
        try await device.makeDirectory(folder)
        do {
            try await device.makeDirectory(folder)
            XCTFail("expected alreadyExists")
        } catch DeviceError.alreadyExists {}
        let renamed = RemotePath.join(remoteRoot, "Renamed ✓")
        try await device.rename(folder, to: renamed)
        let listing = try await device.list(remoteRoot).map(\.name)
        XCTAssertEqual(listing, ["Renamed ✓"])
        try await device.delete(renamed)
        let afterDelete = try await device.list(remoteRoot)
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testProtectedPathsAreRefused() async throws {
        do { try await device.delete("/sdcard/DCIM"); XCTFail() } catch DeviceError.protectedPath {}
        do { try await device.delete("/sdcard"); XCTFail() } catch DeviceError.protectedPath {}
        do { try await device.makeDirectory("/data/local/tmp/pbx"); XCTFail() } catch DeviceError.permissionDenied {}
    }

    func testFileRoundTripPreservesContent() async throws {
        let name = "Höliday vidéo 'final' (1) 日本 😀.bin"
        let src = localRoot.appendingPathComponent(name)
        var bytes = Data(count: 3 * 1024 * 1024 + 17)
        bytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try bytes.write(to: src)

        let up = try await run(request(.toDevice, src: src.path, dest: remoteRoot))
        guard case .completed(let remotePath, let n, .sha256) = up else { return XCTFail("\(up)") }
        XCTAssertEqual(remotePath, RemotePath.join(remoteRoot, name))
        XCTAssertEqual(n, Int64(bytes.count))
        // No partial files left behind.
        let remoteNames = try await device.list(remoteRoot).map(\.name)
        XCTAssertEqual(remoteNames, [name])

        let back = localRoot.appendingPathComponent("back")
        try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
        let down = try await run(request(.toMac, src: remotePath, dest: back.path))
        guard case .completed(let localPath, _, .sha256) = down else { return XCTFail("\(down)") }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: localPath)), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: back.path), [name])
    }

    func testNestedFolderRoundTrip() async throws {
        let folder = localRoot.appendingPathComponent("Trip Photos 2024")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Day 1/Évening"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty-ok"), withIntermediateDirectories: true)
        for (i, rel) in ["a.jpg", "Day 1/b c.jpg", "Day 1/Évening/日本.txt", "Day 1/Évening/it's.txt"].enumerated() {
            try Data(repeating: UInt8(i), count: 1000 * (i + 1)).write(to: folder.appendingPathComponent(rel))
        }
        let up = try await run(request(.toDevice, src: folder.path, dest: remoteRoot))
        guard case .completed(let remoteFolder, let total, _) = up else { return XCTFail("\(up)") }
        XCTAssertEqual(total, 1000 + 2000 + 3000 + 4000)
        let remoteHashes = try await device.hashManifest(remoteFolder)
        XCTAssertEqual(remoteHashes, try LocalFileService.hashManifest(folder))

        let back = localRoot.appendingPathComponent("back")
        try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
        let down = try await run(request(.toMac, src: remoteFolder, dest: back.path))
        guard case .completed(let localFolder, _, _) = down else { return XCTFail("\(down)") }
        XCTAssertEqual(try LocalFileService.hashManifest(URL(fileURLWithPath: localFolder)), try LocalFileService.hashManifest(folder))
    }

    func testConflictKeepBothSkipAndReplace() async throws {
        let src = localRoot.appendingPathComponent("dup.txt")
        try Data("one".utf8).write(to: src)
        _ = try await run(request(.toDevice, src: src.path, dest: remoteRoot))
        try Data("two!".utf8).write(to: src)

        let kept = try await run(request(.toDevice, src: src.path, dest: remoteRoot), conflict: .keepBoth)
        guard case .completed(let p, _, _) = kept else { return XCTFail() }
        XCTAssertEqual(RemotePath.name(p), "dup 2.txt")

        let skipped = try await run(request(.toDevice, src: src.path, dest: remoteRoot), conflict: .skip)
        XCTAssertEqual(skipped, .skipped)

        _ = try await run(request(.toDevice, src: src.path, dest: remoteRoot), conflict: .replace)
        let sizes = try await device.sizeManifest(RemotePath.join(remoteRoot, "dup.txt"))
        XCTAssertEqual(sizes["dup.txt"], 4)
    }

    func testMoveFromDeviceDeletesSourceOnlyAfterVerifiedCopy() async throws {
        let src = localRoot.appendingPathComponent("move-me.txt")
        try Data("move".utf8).write(to: src)
        _ = try await run(request(.toDevice, src: src.path, dest: remoteRoot))
        let remote = RemotePath.join(remoteRoot, "move-me.txt")
        let dest = localRoot.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let out = try await run(request(.toMac, .move, src: remote, dest: dest.path), checksums: false)
        guard case .completed(_, _, .sha256) = out else { return XCTFail("moves always use SHA-256: \(out)") }
        let stillThere = try await device.stat(remote)
        XCTAssertNil(stillThere)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("move-me.txt"), encoding: .utf8), "move")
    }

    func testCancelledUploadLeavesNoPartialFiles() async throws {
        let src = localRoot.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: src.path, contents: nil)
        let h = try FileHandle(forWritingTo: src)
        let chunk = Data(repeating: 0xAB, count: 1024 * 1024)
        for _ in 0..<300 { h.write(chunk) }
        try h.close()

        let r = request(.toDevice, src: src.path, dest: remoteRoot)
        let task = Task { try await self.run(r) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            // A fast device can finish 300 MB in 300 ms; that's fine too.
        } catch {}
        try await Task.sleep(nanoseconds: 500_000_000)
        let names = try await device.list(remoteRoot).map(\.name)
        XCTAssertFalse(names.contains { $0.hasSuffix(".partial") }, "\(names)")
    }

    func testMissingSourceReportsClearly() async throws {
        do {
            _ = try await run(request(.toMac, src: RemotePath.join(remoteRoot, "nope.txt"), dest: localRoot.path))
            XCTFail()
        } catch DeviceError.notFound {}
    }
}

extension DeviceIntegrationTests {
    /// Large single-file download (regression: a 180 MB pull once came back short).
    func testLargeFileDownload() async throws {
        let remote = RemotePath.join(remoteRoot, "big video.mp4")
        try await device.shell("dd if=/dev/urandom of=\(ShellQuoting.quote(remote)) bs=1048576 count=180 2>/dev/null", timeout: 120)
        let out = try await run(request(.toMac, src: remote, dest: localRoot.path))
        guard case .completed(let path, let bytes, .sha256) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(bytes, 180 * 1048576)
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64
        XCTAssertEqual(size, 180 * 1048576)
    }
}
