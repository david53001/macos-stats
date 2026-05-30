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
            dependencies: ["MacStatsCore"],
            swiftSettings: [
                // CLT-only: suppress the _Testing_Foundation cross-import overlay
                // that is triggered when both Foundation and Testing are imported.
                .unsafeFlags(["-disable-cross-import-overlays"])
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
