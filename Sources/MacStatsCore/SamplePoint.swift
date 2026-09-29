import Foundation

/// One timestamped sparkline reading. `time` is seconds since the reference date
/// (`Date().timeIntervalSinceReferenceDate`), so points taken at different cadences (the
/// 10s idle sampler, the fast open-popover ticks) sit at their true place on a time axis.
public struct SamplePoint: Equatable, Sendable {
    public let time: TimeInterval
    public let value: Double

    public init(time: TimeInterval, value: Double) {
        self.time = time
        self.value = value
    }
}
