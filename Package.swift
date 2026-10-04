// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JustContinue",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "JustContinue", targets: ["JustContinue"]),
    ],
    targets: [
        // Discovery, log parsing, terminal adapters and the resume engine. No UI.
        .target(name: "JustContinueCore"),
        // The menu-bar app.
        .executableTarget(name: "JustContinue", dependencies: ["JustContinueCore"]),
        .testTarget(name: "JustContinueCoreTests", dependencies: ["JustContinueCore"]),
    ]
)
