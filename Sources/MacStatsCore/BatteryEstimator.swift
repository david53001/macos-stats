import Foundation

/// Time-left estimate that tracks the real drain and holds up when usage swings.
///
/// macOS's figure divides the charge left by roughly the last minute of draw, so a quiet
/// minute promises 13 h and a busy one 3 h. This blends averages of the whole-Mac draw (which
/// already sums every app, the display and the GPU), fed **only** awake on-battery intervals
/// (see `gaugeInterval`; the caller skips plugged-in time and intervals that span sleep):
/// - **short**: the last ten minutes or so (10-minute time constant), so a sustained load
///   step shows;
/// - **recent**: the last hour or so of this session (60-minute time constant), pulled toward
/// - **typical**: how this Mac usually drains on battery (12-hour time constant over awake
///   on-battery seconds, persisted), which counts like `priorSeconds` of session evidence.
///
/// Expected draw = w·short + (1 − w)·(recent ⊕ typical). w is `shortWeightUp` when the short
/// average is above the rest (the load rose: follow it, so time left never lags a real load on
/// the optimistic side) and `shortWeightDown` when below (a quiet stretch: count it, but don't
/// promise hours on one quiet minute). Going down, w is also phased in over the session's first
/// `shortRampSeconds`, the minutes right after unplugging where one quiet reading moved the
/// estimate 438 → 494 min.
///
/// Tuning (2026-10-05, round 3): replayed on 5 days of this Mac's own on-battery history
/// (powerlog `PLBatteryAgent_EventBackward_Battery`, 14 sessions, 2 666 gauge readings, drain per
/// interval from the coulomb counter `PassedCharge`) and scored against the drain that really
/// followed (next 60 / 120 min, and the rest of the session). The previous constants (5 / 30 min,
/// 3 h, 0.6 both ways) were off by a mean |log ratio| of 36 % and moved 22 % per 10 awake
/// minutes on average (p90 52 %); these are off by 33 % and move 16 % (p90 38 %), on either half
/// of the history alone too. Trusting the long-run average much more scores better on that
/// history (31 %, 12 %) but read up to 45–57 % pessimistic for the first half hour of a light
/// session after heavy use, so the search was limited to settings that stay within 25 % of a
/// synthetic load change after 30 minutes in both directions (pinned in `TimeLeftReplayTests`).
///
/// History (2026-10-05): an older version learned "typical" from every reading, plugged in or
/// across sleep, which settled at 2.5 W on a Mac that really drains ~5.5 W awake on battery;
/// with half the weight it showed 7–8 h where ~5 h 20 m was true. That value is not migrated
/// (new persistence keys). Then the middle term was the mean since unplugging, which never
/// forgets: an hour of idle (1.7 W) before real use (5.5 W) still read +28 % after 40 minutes
/// of use.
public struct BatteryEstimator: Equatable {
    public static let shortTau: TimeInterval = 10 * 60
    public static let recentTau: TimeInterval = 60 * 60
    /// Weight of the short average in the expected draw (the rest goes to recent ⊕ typical)
    /// when it is above the rest, and when below (that one reached over `shortRampSeconds`).
    public static let shortWeightUp = 0.8
    public static let shortWeightDown = 0.6
    public static let shortRampSeconds: TimeInterval = 10 * 60
    public static let typicalTau: TimeInterval = 12 * 3600
    /// How much session time the typical average is worth as a prior.
    public static let priorSeconds: TimeInterval = 20 * 60
    /// Until the session has this much data, the typical drain (or, with none yet, macOS's own
    /// figure) gives the time left.
    public static let settleSeconds: TimeInterval = 2 * 60

    public private(set) var shortWatts: Double?
    public private(set) var recentWatts: Double?
    /// Energy and awake seconds since unplugging (the shown session average; not the estimate).
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
        shortWatts = Self.blend(shortWatts, watts, step: seconds, prior: sessionSeconds, tau: Self.shortTau)
        recentWatts = Self.blend(recentWatts, watts, step: seconds, prior: sessionSeconds, tau: Self.recentTau)
        sessionWh += watts * seconds / 3600
        sessionSeconds += seconds
        typicalWatts = Self.blend(typicalWatts, watts, step: seconds, prior: typicalSeconds, tau: Self.typicalTau)
        typicalSeconds += seconds
    }

    /// Plugged in: the next unplug starts a new session. Typical is kept.
    public mutating func endSession() {
        shortWatts = nil
        recentWatts = nil
        sessionWh = 0
        sessionSeconds = 0
    }

    /// Mean draw since unplugging (W), or nil with no session data.
    public var sessionAverageWatts: Double? {
        sessionSeconds > 0 ? sessionWh * 3600 / sessionSeconds : nil
    }

    /// The recent average, pulled toward typical as if typical were `priorSeconds` of data.
    private var baseWatts: Double? {
        switch (recentWatts, typicalWatts) {
        case let (recent?, typical?):
            return (sessionSeconds * recent + Self.priorSeconds * typical) / (sessionSeconds + Self.priorSeconds)
        case let (recent?, nil): return recent
        case let (nil, typical?): return typical
        case (nil, nil): return nil
        }
    }

    /// The draw the estimate assumes for the rest of the charge (W), or nil with no data.
    public var expectedWatts: Double? {
        guard let base = baseWatts else { return shortWatts }
        guard let short = shortWatts else { return base }
        let weight = short >= base ? Self.shortWeightUp
            : Self.shortWeightDown * min(1, sessionSeconds / Self.shortRampSeconds)
        return weight * short + (1 - weight) * base
    }

    /// Minutes until empty for `remainingWh` of charge. Right after unplugging (under
    /// `settleSeconds` of data) one gauge reading can be a spike (9.5 W against a 1.8 W
    /// average), so the typical drain is used alone when it rests on at least `priorSeconds`
    /// of earlier use; without that, macOS's own figure; without either, nil ("Calculating…"):
    /// on a first-ever launch one 0.6 W interval read "66h 51m".
    public func minutesLeft(remainingWh: Double, macOSMinutes: Int?) -> Int? {
        var watts = expectedWatts
        if sessionSeconds < Self.settleSeconds {
            if let typical = typicalWatts, typicalSeconds - sessionSeconds >= Self.priorSeconds { watts = typical }
            else if let m = macOSMinutes, m > 0 { return m }
            else { return nil }
        }
        guard let watts, watts > 0.1, remainingWh > 0 else { return nil }
        return Int((remainingWh / watts * 60).rounded())
    }

    /// Time-weighted exponential average, bias-corrected: a reading `step` seconds long, after
    /// `prior` seconds already in the average, moves it by (1 − e^(−step/τ)) / (1 − e^(−(prior+step)/τ)).
    /// Long after the start that is the plain 1 − e^(−step/τ); early on it is close to a running
    /// mean, so the first reading counts only for its own duration. (Seeding with the first
    /// reading at full weight let one 9.5 W unplug spike, followed by 1.8 W, read −66 % after
    /// 10 minutes and −50 % after 30; a 12 W build tail on first launch still held the persisted
    /// typical at 7.3 W after 3 h at 4.6 W.)
    private static func blend(_ average: Double?, _ value: Double, step: TimeInterval,
                              prior: TimeInterval, tau: TimeInterval) -> Double {
        guard let average else { return value }
        let alpha = (1 - exp(-step / tau)) / (1 - exp(-(max(0, prior) + step) / tau))
        return average + alpha * (value - average)
    }
}
