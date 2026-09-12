// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SurfaceKit", platforms: [.macOS(.v15)],
    products: [.library(name: "BowserSurfaceKit", type: .dynamic, targets: ["BowserSurfaceKit"])],
    targets: [.target(name: "BowserSurfaceKit")])
