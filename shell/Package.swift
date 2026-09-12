// swift-tools-version: 6.0
import PackageDescription

// ADR 0008: the engine is WKWebView; the shell implements the brain protocol
// natively (BrainBridge.swift). The Rust/Servo host in ../host is dormant.
let package = Package(
    name: "Bowser",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "SurfaceKit")],
    targets: [
        .target(name: "BackendRuntime", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "BowserBackendHost", dependencies: ["BackendRuntime"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "BowserRuntimeTool", dependencies: ["BackendRuntime"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "IconRendering"),
        .executableTarget(name: "BowserIconWorker", dependencies: ["IconRendering"]),
        .executableTarget(
            name: "Bowser",
            dependencies: [.product(name: "BowserSurfaceKit", package: "SurfaceKit")],
            path: "Sources/Bowser",
            resources: [.copy("Resources/ProfileCharacters")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "BowserTests",
            dependencies: ["Bowser", "IconRendering"],
            path: "Tests/BowserTests"
        ),
    ]
)
