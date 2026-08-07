// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "fand",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FandCore", targets: ["FandCore"]),
        .executable(name: "fand", targets: ["fand"]),
        .executable(name: "fanctl", targets: ["fanctl"]),
    ],
    targets: [
        .target(name: "FandCore"),
        .executableTarget(name: "fand", dependencies: ["FandCore"]),
        .executableTarget(name: "fanctl", dependencies: ["FandCore"]),
        .testTarget(name: "FandCoreTests", dependencies: ["FandCore"]),
    ]
)
