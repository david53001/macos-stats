import Foundation

/// Time-left estimate that tracks the real drain and holds up when usage swings.
///
/// macOS's figure divides the charge left by roughly the last minute of draw, so a quiet
/// minute promises 13 h and a busy one 3 h. This blends averages of the whole-Mac draw (which
/// already sums every app, the display and the GPU), fed **only** awake on-battery intervals
/// (see `gaugeInterval`; the caller skips plugged-in time and intervals that span sleep):
/// - **short**: the last few minutes (5-minute time constant), so a sustained load step shows;
/// - **session**: the energy-weighted mean since unplugging (kept across sleep), pulled toward
/// - **typical**: how this Mac usually drains on battery (3-hour time constant over awake
///   on-battery seconds, persisted), which counts like `priorSeconds` of session evidence.
///
/// Expected draw = ½ short + ½ (session ⊕ typical). History (2026-10-05): an older version
/// learned "typical" from every reading, plugged in or across sleep, which settled at 2.5 W on
/// a Mac that really drains ~5.5 W awake on battery; with half the weight it showed 7–8 h where
/// ~5 h 20 m was true. That value is not migrated (new persistence keys).
public struct BatteryEstimator: Equatable {
    public static let shortTau: TimeInterval = 5 * 60
    public static let typicalTau: TimeInterval = 3 * 3600
    /// How much session time the typical average is worth as a prior.
    public static let priorSeconds: TimeInterval = 20 * 60
    /// Until the session has this much data, macOS's own figure (if it has one) is shown.
    public static let settleSeconds: TimeInterval = 2 * 60

    public private(set) var shortWatts: Double?
    public private(set) var sessionWh: Double = 0
    public private(set) var sessionSeconds: TimeInterval = 0
    public private(set) var typicalWatts: Double?
    /// Awake on-battery seconds the typical average is built on.
    public private(set) var typicalSeconds: TimeInterval

    public init(typicalWatts: Double? = nil, typicalSeconds: TimeInterval = 0) {
        let valid = typicalWatts.map { $0 > 0 && $0.isFinite } ?? false
        self.typicalWatts = valid ? typicalWatts : nil
        self.typicalSeconds = valid ? max(0, typicalSeconds) : 0
    }

    /// One awake on-battery interval: `seconds` long at an average of `watts`.
    public mutating func ingest(watts: Double, seconds: TimeInterval) {
        guard watts > 0, watts.isFinite, seconds > 0, seconds.isFinite else { return }
        shortWatts = Self.blend(shortWatts, watts, step: seconds, tau: Self.shortTau)
        sessionWh += watts * seconds / 3600
        sessionSeconds += seconds
        typicalWatts = Self.blend(typicalWatts, watts, step: seconds, tau: Self.typicalTau)
        typicalSeconds += seconds
    }

    /// Plugged in: the next unplug starts a new session. Typical is kept.
    public mutating func endSession() {
        shortWatts = nil
        sessionWh = 0
        sessionSeconds = 0
    }

    /// Mean draw since unplugging (W), or nil with no session data.
    public var sessionAverageWatts: Double? {
        sessionSeconds > 0 ? sessionWh * 3600 / sessionSeconds : nil
    }

    /// The session mean, pulled toward typical as if typical were `priorSeconds` of data.
    private var baseWatts: Double? {
        switch (sessionAverageWatts, typicalWatts) {
        case let (session?, typical?):
            return (sessionSeconds * session + Self.priorSeconds * typical) / (sessionSeconds + Self.priorSeconds)
        case let (session?, nil): return session
        case let (nil, typical?): return typical
        case (nil, nil): return nil
        }
    }

    /// The draw the estimate assumes for the rest of the charge (W), or nil with no data.
    public var expectedWatts: Double? {
        guard let base = baseWatts else { return shortWatts }
        guard let short = shortWatts else { return base }
        return 0.5 * short + 0.5 * base
    }

    /// Minutes until empty for `remainingWh` of charge. Right after unplugging (under
    /// `settleSeconds` of data) macOS's own figure is used when it has one.
    public func minutesLeft(remainingWh: Double, macOSMinutes: Int?) -> Int? {
        if sessionSeconds < Self.settleSeconds, let m = macOSMinutes, m > 0 { return m }
        guard let watts = expectedWatts, watts > 0.1, remainingWh > 0 else { return nil }
        return Int((remainingWh / watts * 60).rounded())
    }

    /// Time-weighted exponential average: a reading `step` seconds long moves the average by
    /// 1 − e^(−step/τ). The very first reading seeds it.
    private static func blend(_ average: Double?, _ value: Double, step: TimeInterval,
                              tau: TimeInterval) -> Double {
        guard let average else { return value }
        let alpha = 1 - exp(-step / tau)
        return average + alpha * (value - average)
    }
}
