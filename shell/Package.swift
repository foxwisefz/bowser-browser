// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bowser",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Bowser",
            path: "Sources/Bowser"
        )
    ]
)
