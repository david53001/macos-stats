// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "R2BProbe",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CAppleSensors", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "MacStatsCore", dependencies: ["CAppleSensors"]),
        .executableTarget(name: "Probe", dependencies: ["MacStatsCore"]),
    ],
    swiftLanguageModes: [.v5]
)
