// swift-tools-version: 6.0
import PackageDescription

// Absolute path is deliberate: single-machine target (ADR 0006).
let rustRelease = "/Users/gezim/projects/bowser-browser/target/aarch64-apple-darwin/release"

let package = Package(
    name: "Bowser",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "CBowserHost", path: "Sources/CBowserHost"),
        .executableTarget(
            name: "Bowser",
            dependencies: ["CBowserHost"],
            path: "Sources/Bowser",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(rustRelease)",
                    "-lbowser_host",
                    "-Xlinker", "-rpath", "-Xlinker", rustRelease,
                ])
            ]
        ),
    ]
)
