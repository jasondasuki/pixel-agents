// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PixelMenuBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PixelMenuBar", targets: ["PixelMenuBar"]),
    ],
    targets: [
        // Pure logic (hook payloads, agent state, HTTP parsing, wander model). No AppKit.
        .target(name: "PixelMenuBarCore"),
        // The menu bar app: status item, hook listener, sprites.
        .executableTarget(name: "PixelMenuBar", dependencies: ["PixelMenuBarCore"]),
        .testTarget(name: "PixelMenuBarCoreTests", dependencies: ["PixelMenuBarCore"]),
    ]
)
