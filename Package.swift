// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacStats",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Auto-updates (docs/sparkle-updates/README.md). Exact pin: the bundled framework,
        // the release tools in ~/Developer/Sparkle/2.10.0 and the appcast format must agree.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(
            name: "CAppleSensors",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(name: "MacStatsCore", dependencies: ["CAppleSensors"]),
        .executableTarget(
            name: "MacStatsApp",
            dependencies: ["MacStatsCore", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is embedded in MacStats.app/Contents/Frameworks by bundle.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
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
