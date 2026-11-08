// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AndroBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AndroBridge", targets: ["AndroBridge"]),
        .library(name: "AndroBridgeCore", targets: ["AndroBridgeCore"]),
    ],
    targets: [
        // All device, transfer and file logic. No UI. Unit-tested.
        .target(name: "AndroBridgeCore", path: "Sources/AndroBridgeCore"),
        // The SwiftUI macOS app.
        .executableTarget(
            name: "AndroBridge",
            dependencies: ["AndroBridgeCore"],
            path: "Sources/AndroBridge"
        ),
        // Pure logic tests: no phone needed.
        .testTarget(
            name: "AndroBridgeCoreTests",
            dependencies: ["AndroBridgeCore"],
            path: "Tests/AndroBridgeCoreTests"
        ),
        // Talks to a real device or emulator over ADB. Skipped unless
        // ANDROBRIDGE_DEVICE_TESTS=1 is set (see README).
        .testTarget(
            name: "DeviceIntegrationTests",
            dependencies: ["AndroBridgeCore"],
            path: "Tests/DeviceIntegrationTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
