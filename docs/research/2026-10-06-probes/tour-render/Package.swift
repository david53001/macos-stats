// swift-tools-version: 6.0
// Built in $TMPDIR by run.sh (never in the repo): the real MacStatsCore + CAppleSensors, and the
// app's views (Sources/MacStatsApp/*.swift minus the @main) compiled into the Probe target.
import PackageDescription
let package = Package(
    name: "TourRenderProbe",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CAppleSensors", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "MacStatsCore", dependencies: ["CAppleSensors"]),
        .executableTarget(name: "Probe", dependencies: ["MacStatsCore"]),
    ],
    swiftLanguageModes: [.v5]
)
