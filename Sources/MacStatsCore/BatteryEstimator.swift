import Foundation

/// Time-left estimate that holds up when usage swings between light and heavy apps.
///
/// macOS's figure divides the charge left by roughly the last minute of draw, so a quiet
/// minute (reading, idle) promises 13 h and a busy one 3 h. This blends two averages of the
/// whole-Mac draw (which already sums every app, the display and the GPU):
/// - **recent**: this unplugged session, time-weighted with a 10-minute time constant;
/// - **typical**: how this Mac is usually used, a 3-hour time constant over all awake time,
///   persisted across launches. It learns while plugged in too: the whole-Mac draw measures
///   the same apps either way (charging power is metered separately).
/// Typical earns up to half the weight as evidence builds up (its first hour).
public struct BatteryEstimator: Equatable {
    public static let recentTau: TimeInterval = 10 * 60
    public static let typicalTau: TimeInterval = 3 * 3600
    /// Seconds of readings before `typical` gets its full (half) weight.
    public static let typicalRampSeconds: TimeInterval = 3600
    public static let typicalMaxWeight = 0.5
    /// One reading never counts for more than this, so a gap (sleep, a stalled gauge)
    /// can't let a single sample swamp the average.
    public static let maxStep: TimeInterval = 5 * 60

    public private(set) var recentWatts: Double?
    public private(set) var typicalWatts: Double?
    /// Seconds of readings the typical average is built on (capped by `maxStep` per reading).
    public private(set) var typicalSeconds: TimeInterval
    private var lastRecentTime: TimeInterval?
    private var lastTypicalTime: TimeInterval?

    public init(typicalWatts: Double? = nil, typicalSeconds: TimeInterval = 0) {
        self.typicalWatts = typicalWatts
        self.typicalSeconds = typicalWatts == nil ? 0 : typicalSeconds
    }

    /// Feed one average-draw reading. Every reading teaches `typical`; only on-battery ones
    /// feed `recent`, and anything else ends the session, so the next unplug starts `recent`
    /// fresh from its first reading.
    public mutating func ingest(watts: Double, at time: TimeInterval, discharging: Bool) {
        if !discharging { recentWatts = nil; lastRecentTime = nil }
        guard watts > 0, watts.isFinite else { return }

        let typicalStep = Self.step(since: lastTypicalTime, to: time)
        lastTypicalTime = time
        typicalWatts = Self.blend(typicalWatts, watts, step: typicalStep, tau: Self.typicalTau)
        typicalSeconds += typicalStep

        guard discharging else { return }
        let recentStep = Self.step(since: lastRecentTime, to: time)
        lastRecentTime = time
        recentWatts = Self.blend(recentWatts, watts, step: recentStep, tau: Self.recentTau)
    }

    private static func step(since last: TimeInterval?, to time: TimeInterval) -> TimeInterval {
        last.map { min(max(time - $0, 0), maxStep) } ?? 0
    }

    /// The draw the estimate assumes for the rest of the charge (W), or nil with no data.
    public var expectedWatts: Double? {
        guard let recent = recentWatts else { return nil }
        guard let typical = typicalWatts else { return recent }
        let w = Self.typicalMaxWeight * min(1, typicalSeconds / Self.typicalRampSeconds)
        return (1 - w) * recent + w * typical
    }

    /// Minutes until empty for `remainingWh` of charge, or nil with no data yet.
    public func minutesLeft(remainingWh: Double) -> Int? {
        guard let watts = expectedWatts, watts > 0.1, remainingWh > 0 else { return nil }
        return Int((remainingWh / watts * 60).rounded())
    }

    /// Time-weighted exponential average: a reading `step` seconds after the last moves the
    /// average by 1 − e^(−step/τ). The very first reading seeds it.
    private static func blend(_ average: Double?, _ value: Double, step: TimeInterval,
                              tau: TimeInterval) -> Double {
        guard let average else { return value }
        let alpha = 1 - exp(-step / tau)
        return average + alpha * (value - average)
    }
}
