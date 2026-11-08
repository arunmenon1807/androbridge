// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixelBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PixelBridge", targets: ["PixelBridge"]),
        .library(name: "PixelBridgeCore", targets: ["PixelBridgeCore"]),
    ],
    targets: [
        // All device, transfer and file logic. No UI. Unit-tested.
        .target(name: "PixelBridgeCore", path: "Sources/PixelBridgeCore"),
        // The SwiftUI macOS app.
        .executableTarget(
            name: "PixelBridge",
            dependencies: ["PixelBridgeCore"],
            path: "Sources/PixelBridge"
        ),
        // Pure logic tests: no phone needed.
        .testTarget(
            name: "PixelBridgeCoreTests",
            dependencies: ["PixelBridgeCore"],
            path: "Tests/PixelBridgeCoreTests"
        ),
        // Talks to a real device or emulator over ADB. Skipped unless
        // PIXELBRIDGE_DEVICE_TESTS=1 is set (see README).
        .testTarget(
            name: "DeviceIntegrationTests",
            dependencies: ["PixelBridgeCore"],
            path: "Tests/DeviceIntegrationTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
