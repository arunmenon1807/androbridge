import XCTest
@testable import AndroBridgeCore

final class SafetyAndNamingTests: XCTestCase {
    func testShellQuotingNeutralisesMetacharacters() {
        XCTAssertEqual(ShellQuoting.quote("a b"), "'a b'")
        XCTAssertEqual(ShellQuoting.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(ShellQuoting.quote("$(rm -rf /)"), "'$(rm -rf /)'")
        XCTAssertEqual(ShellQuoting.command("rm", ["-rf", "--", "/sdcard/x; reboot"]), "rm '-rf' '--' '/sdcard/x; reboot'")
    }

    func testShellQuotingRoundTripsThroughRealShell() throws {
        // Run the quoted strings through /bin/sh and check they come back unchanged.
        let nasty = ["plain", "with space", "it's", "\"dq\"", "$HOME", "`id`", "a;b|c&d", "tab\there", "naïve 日本語 😀", "new\nline", "*?[]"]
        for value in nasty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "printf %s " + ShellQuoting.quote(value)]
            let pipe = Pipe()
            p.standardOutput = pipe
            try p.run()
            p.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(out, value)
        }
    }

    func testRemotePathHelpers() {
        XCTAssertEqual(RemotePath.join("/sdcard", "DCIM"), "/sdcard/DCIM")
        XCTAssertEqual(RemotePath.join("/sdcard/", "DCIM"), "/sdcard/DCIM")
        XCTAssertEqual(RemotePath.parent("/sdcard/DCIM/Camera"), "/sdcard/DCIM")
        XCTAssertEqual(RemotePath.parent("/sdcard"), "/")
        XCTAssertEqual(RemotePath.name("/sdcard/DCIM/"), "DCIM")
        XCTAssertEqual(RemotePath.normalize("//sdcard///DCIM/"), "/sdcard/DCIM")
        XCTAssertEqual(RemotePath.components("/storage/emulated/0"), ["storage", "emulated", "0"])
        XCTAssertTrue(RemotePath.isValidName("Holiday 2024 日本.jpg"))
        XCTAssertFalse(RemotePath.isValidName("a/b"))
        XCTAssertFalse(RemotePath.isValidName(".."))
        XCTAssertFalse(RemotePath.isValidName("what?.txt"))
        XCTAssertFalse(RemotePath.isValidName(""))
    }

    func testSafetyPolicyProtectsRootsAndStandardFolders() {
        for p in ["/", "/sdcard", "/sdcard/", "/storage/emulated/0", "/sdcard/DCIM", "/sdcard/Download",
                  "/storage/emulated/0/Pictures", "/sdcard/Android", "/sdcard/Android/data", "/data/local/tmp/x",
                  "/system/bin", "/storage/1A2B-3C4D"] {
            XCTAssertTrue(SafetyPolicy.isProtected(p), p)
        }
        for p in ["/sdcard/DCIM/Camera", "/sdcard/Download/file.pdf", "/storage/emulated/0/Music/Album",
                  "/sdcard/MyFolder", "/storage/1A2B-3C4D/Photos", "/sdcard/Android/media/com.app/x"] {
            XCTAssertFalse(SafetyPolicy.isProtected(p), p)
        }
        XCTAssertTrue(SafetyPolicy.isWritableLocation("/sdcard/Download"))
        XCTAssertFalse(SafetyPolicy.isWritableLocation("/data/local/tmp"))
        XCTAssertFalse(SafetyPolicy.isWritableLocation("/sdcardX/foo"))
    }

    func testConflictNamingMatchesFinder() {
        var taken: Set<String> = ["Photo.jpg"]
        XCTAssertEqual(ConflictNaming.uniqueName(for: "Photo.jpg", isDirectory: false) { taken.contains($0) }, "Photo 2.jpg")
        taken.insert("Photo 2.jpg")
        XCTAssertEqual(ConflictNaming.uniqueName(for: "Photo.jpg", isDirectory: false) { taken.contains($0) }, "Photo 3.jpg")
        XCTAssertEqual(ConflictNaming.uniqueName(for: "Folder.v2", isDirectory: true) { $0 == "Folder.v2" }, "Folder.v2 2")
        XCTAssertEqual(ConflictNaming.uniqueName(for: ".hidden", isDirectory: false) { $0 == ".hidden" }, ".hidden 2")
        XCTAssertEqual(ConflictNaming.uniqueName(for: "new.txt", isDirectory: false) { _ in false }, "new.txt")
    }

    func testWirelessAddressParsing() {
        XCTAssertEqual(WirelessConnectionService.parseAddress("192.168.1.20:37099")?.1, 37099)
        XCTAssertNil(WirelessConnectionService.parseAddress("192.168.1.20"))
        XCTAssertNil(WirelessConnectionService.parseAddress("-evil:5555"))
        XCTAssertNil(WirelessConnectionService.parseAddress("1.2.3.4:99999"))
        XCTAssertFalse(ADBClient.isValidHost("a b"))
    }

    func testVerificationComparison() throws {
        XCTAssertNoThrow(try FileTransferService.compare(source: ["a": 1, "b/c": 2], copy: ["b/c": 2, "a": 1]))
        XCTAssertThrowsError(try FileTransferService.compare(source: ["a": 1], copy: ["a": 2]))
        XCTAssertThrowsError(try FileTransferService.compare(source: ["a": 1, "b": 1], copy: ["a": 1]))
        XCTAssertThrowsError(try FileTransferService.compareHashes(source: ["a": "x"], copy: ["a": "y"]))
        // NFC vs NFD spellings of the same name compare equal.
        let nfc = "caf\u{00E9}.txt", nfd = "cafe\u{0301}.txt"
        XCTAssertNoThrow(try FileTransferService.compare(source: [nfc: 3], copy: [nfd: 3]))
    }
}
