// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ReviewBProbe",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CAppleSensors", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "MacStatsCore", dependencies: ["CAppleSensors"]),
        .executableTarget(name: "ReviewBProbe", dependencies: ["MacStatsCore"]),
    ],
    swiftLanguageModes: [.v5]
)
