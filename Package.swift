// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacStats",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MacStatsCore"),
        .executableTarget(
            name: "MacStatsApp",
            dependencies: ["MacStatsCore"]
        ),
        .testTarget(
            name: "MacStatsCoreTests",
            dependencies: ["MacStatsCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
