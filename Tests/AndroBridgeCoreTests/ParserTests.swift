import XCTest
@testable import AndroBridgeCore

final class ParserTests: XCTestCase {
    func testParsesUSBWirelessAndUnauthorizedDevices() {
        let output = """
        List of devices attached
        1A2B3C4D5E             device usb:1-1 product:husky model:Pixel_8_Pro device:husky transport_id:3
        192.168.1.20:41235     device product:husky model:Pixel_8_Pro device:husky transport_id:4
        9XYZ                   unauthorized usb:2-1 transport_id:5
        ZZZ                    no permissions (missing udev rules? user is in the plugdev group); see [http://developer.android.com/tools/device.html] usb:1-2 transport_id:6
        emulator-5554          offline transport_id:7

        """
        let d = ADBOutputParser.parseDevices(output)
        XCTAssertEqual(d.count, 5)
        XCTAssertEqual(d[0].serial, "1A2B3C4D5E")
        XCTAssertEqual(d[0].state, .device)
        XCTAssertEqual(d[0].displayName, "Pixel 8 Pro")
        XCTAssertEqual(d[0].connectionKind, .usb)
        XCTAssertEqual(d[1].connectionKind, .wireless)
        XCTAssertEqual(d[2].state, .unauthorized)
        XCTAssertNil(d[2].model)
        XCTAssertEqual(d[3].state, .noPermissions)
        XCTAssertEqual(d[3].transportID, "6")
        XCTAssertEqual(d[4].state, .offline)
        XCTAssertEqual(d[4].connectionKind, .emulator)
    }

    func testEmptyDeviceList() {
        XCTAssertTrue(ADBOutputParser.parseDevices("List of devices attached\n\n").isEmpty)
        XCTAssertTrue(ADBOutputParser.parseDevices("* daemon not running; starting now at tcp:5037\n* daemon started successfully\nList of devices attached\n").isEmpty)
    }

    func testParsesListingWithSpacesTabsAndUnicode() {
        let out = [
            "directory\t4096\t1700000000\t./DCIM",
            "regular file\t12345\t1700000100\t./My Holiday 'Video'.mp4",
            "regular empty file\t0\t1700000200\t./empty.txt",
            "regular file\t7\t1700000300\t./naïve 日本語 😀.txt",
            "regular file\t9\t1700000400\t./tab\there.txt",
            "garbage line",
        ].joined(separator: "\n")
        let items = ADBOutputParser.parseListing(out, directory: "/sdcard/")
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(items[0].path, "/sdcard/DCIM")
        XCTAssertTrue(items[0].isDirectory)
        XCTAssertEqual(items[0].size, 0)
        XCTAssertEqual(items[1].name, "My Holiday 'Video'.mp4")
        XCTAssertEqual(items[1].size, 12345)
        XCTAssertEqual(items[1].modified, Date(timeIntervalSince1970: 1700000100))
        XCTAssertEqual(items[1].fileExtension, "mp4")
        XCTAssertEqual(items[2].kind, .file)
        XCTAssertEqual(items[3].name, "naïve 日本語 😀.txt")
        XCTAssertEqual(items[4].name, "tab\there.txt")
    }

    func testParsesAbsolutePathListing() {
        let items = ADBOutputParser.parseListing("regular file\t5\t1\t/sdcard/Download/a b.txt", directory: "/sdcard/Download")
        XCTAssertEqual(items.first?.name, "a b.txt")
        XCTAssertEqual(items.first?.path, "/sdcard/Download/a b.txt")
    }

    func testParsesDF() {
        let out = """
        Filesystem     1K-blocks    Used Available Use% Mounted on
        /dev/fuse        6082144 4660440   1279492  79% /storage/emulated
        """
        let info = ADBOutputParser.parseDF(out)
        XCTAssertEqual(info?.totalBytes, 6082144 * 1024)
        XCTAssertEqual(info?.availableBytes, 1279492 * 1024)
        XCTAssertNil(ADBOutputParser.parseDF("nonsense"))
    }

    func testParsesManifests() {
        let sha = """
        98ea6e4f216f2fb4b69fff9b3a44842c38686ca685f3f55dc48c5d3fb1107be4  ./a.txt
        3828eeee974aa7486e7acc258e5c73a0115e168444d6688deb8d5d1306d1f57d  ./sub dir/ünï cødé 'q'.txt
        """
        let h = ADBOutputParser.parseSha256Manifest(sha)
        XCTAssertEqual(h.count, 2)
        XCTAssertEqual(h["sub dir/ünï cødé 'q'.txt"], "3828eeee974aa7486e7acc258e5c73a0115e168444d6688deb8d5d1306d1f57d")
        let s = ADBOutputParser.parseSizeManifest("3\t./a.txt\n14\t./sub dir/x y.txt\n")
        XCTAssertEqual(s, ["a.txt": 3, "sub dir/x y.txt": 14])
    }

    func testParsesMDNS() {
        let out = """
        List of discovered mdns services
        adb-1A2B3C-xYz12\t_adb-tls-connect._tcp\t192.168.1.20:41235
        adb-1A2B3C-xYz12\t_adb-tls-pairing._tcp\t192.168.1.20:37011
        """
        let s = ADBOutputParser.parseMDNSServices(out)
        XCTAssertEqual(s.count, 2)
        XCTAssertTrue(s[0].isConnect)
        XCTAssertTrue(s[1].isPairing)
        XCTAssertEqual(s[0].address, "192.168.1.20:41235")
    }

    func testClassifiesErrors() {
        XCTAssertEqual(ADBOutputParser.classifyError("adb: error: device unauthorized."), .unauthorized)
        XCTAssertEqual(ADBOutputParser.classifyError("adb: no devices/emulators found"), .deviceDisconnected)
        XCTAssertEqual(ADBOutputParser.classifyError("error: device 'X' not found"), .deviceDisconnected)
        XCTAssertEqual(ADBOutputParser.classifyError("ls: /data: Permission denied", path: "/data"), .permissionDenied("/data"))
        XCTAssertEqual(ADBOutputParser.classifyError("No space left on device"), .noSpace)
        XCTAssertEqual(ADBOutputParser.classifyError("stat: 'x': No such file or directory", path: "x"), .notFound("x"))
    }
}
