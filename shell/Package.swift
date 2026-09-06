// swift-tools-version: 6.0
import PackageDescription

// ADR 0008: the engine is WKWebView; the shell implements the brain protocol
// natively (BrainBridge.swift). The Rust/Servo host in ../host is dormant.
let package = Package(
    name: "Bowser",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "IconRendering"),
        .executableTarget(name: "BowserIconWorker", dependencies: ["IconRendering"]),
        .executableTarget(
            name: "Bowser",
            path: "Sources/Bowser",
            resources: [.copy("Resources/ProfileCharacters")]
        ),
        .testTarget(
            name: "BowserTests",
            dependencies: ["Bowser", "IconRendering"],
            path: "Tests/BowserTests"
        ),
    ]
)
