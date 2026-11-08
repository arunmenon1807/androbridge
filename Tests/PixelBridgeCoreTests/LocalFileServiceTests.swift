import XCTest
@testable import PixelBridgeCore

final class LocalFileServiceTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub dir/日本"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("a b.txt"))
        try Data("wörld!".utf8).write(to: root.appendingPathComponent("sub dir/日本/ü.txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testListAndManifests() throws {
        let items = try LocalFileService.list(root).sorted { $0.name < $1.name }
        XCTAssertEqual(items.map(\.name), ["a b.txt", "sub dir"])
        XCTAssertTrue(items[1].isDirectory)
        XCTAssertEqual(items[0].size, 5)

        let sizes = try LocalFileService.sizeManifest(root)
        XCTAssertEqual(sizes["a b.txt"], 5)
        XCTAssertEqual(sizes["sub dir/日本/ü.txt"], Int64("wörld!".utf8.count))
        XCTAssertEqual(LocalFileService.totalSize(root), 5 + Int64("wörld!".utf8.count))

        let hashes = try LocalFileService.hashManifest(root)
        // sha256("hello")
        XCTAssertEqual(hashes["a b.txt"], "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual(try LocalFileService.sizeManifest(root.appendingPathComponent("a b.txt"), fileKey: "x"), ["x": 5])
    }

    func testMakeDirectoryAndRenameNeverOverwrite() throws {
        let dir = root.appendingPathComponent("New Folder")
        try LocalFileService.makeDirectory(dir)
        XCTAssertThrowsError(try LocalFileService.makeDirectory(dir))
        XCTAssertThrowsError(try LocalFileService.rename(root.appendingPathComponent("a b.txt"), to: "sub dir"))
        let renamed = try LocalFileService.rename(root.appendingPathComponent("a b.txt"), to: "c.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertThrowsError(try LocalFileService.rename(renamed, to: "x/y"))
    }

    func testHistoryStoreRoundTrip() throws {
        let store = TransferHistoryStore(fileURL: root.appendingPathComponent("h.json"))
        XCTAssertTrue(store.load().isEmpty)
        store.save([])
        XCTAssertTrue(store.load().isEmpty)
    }
}
