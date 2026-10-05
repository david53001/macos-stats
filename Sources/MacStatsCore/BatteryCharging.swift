import Foundation

/// Time to full, measured instead of taken from macOS.
///
/// macOS's `AvgTimeToFull` jumps around (132 → 96 → 112 → 82 min within minutes), implies
/// about half the measured charge current, and ignores an active charge limit: at 74 % with an
/// 85 % limit it said 82 min while charging stopped ~25 min later. Here: the charge current is
/// measured (gauge `Amperage`), the target is the charge limit when one is active, and the
/// way the current falls as the battery fills is modelled (`minutesToTarget`).

/// Smoothed charge current (mA) from the gauge's positive `Amperage` readings: a time-weighted,
/// bias-corrected exponential average like `BatteryEstimator`'s. The first reading after
/// plug-in is often a transient (1096 mA, then 2278 mA 43 s later on Sep 28; 827 → 1894 mA on
/// Oct 1), so it seeds the average but is not reported, and the next reading replaces it.
public struct ChargeCurrent: Equatable {
    public static let tau: TimeInterval = 5 * 60
    private var average: Double?
    /// Seconds of readings the average spans (0 until a second reading).
    public private(set) var seconds: TimeInterval = 0

    public init() {}

    /// The average, once it rests on at least two readings.
    public var milliamps: Double? { seconds > 0 ? average : nil }

    /// One gauge reading `seconds` after the previous one (0 seeds, or skips a reading that
    /// doesn't follow an awake interval). Non-positive currents (discharging, held) are ignored.
    public mutating func ingest(milliamps value: Int, seconds step: TimeInterval) {
        guard value > 0 else { return }
        guard let average else { self.average = Double(value); return }
        guard step > 0 else { return }
        let alpha = (1 - exp(-step / Self.tau)) / (1 - exp(-(seconds + step) / Self.tau))
        self.average = average + alpha * (Double(value) - average)
        seconds += step
    }

    public mutating func reset() {
        average = nil
        seconds = 0
    }
}

/// Charging is taken to end when the current has tapered to the capacity over this many hours
/// (C/20, ~220 mA here), the usual Li-ion termination current.
public let chargeTerminationHours = 20.0

/// Minutes to charge from `currentMAh` of `maxMAh` (the gauge's raw charge,
/// `AppleRawCurrentCapacity` / `AppleRawMaxCapacity`) to `targetPercent` shown, at a measured
/// `chargeMA`; nil when there's no usable current or a limit target is already reached.
///
/// Model, as a function of the raw charge level s (0…1): the current is
/// I(s) = I₀ (1 − `decline`·s) up to `knee`, then falls linearly to 0 at s = 1 (the
/// constant-voltage phase), continuous at the knee. I₀ is inferred from the measured current
/// and the model's factor at the present s, and the time is ∫ full · ds / I(s), so the estimate
/// is continuous in the charge level (the previous knee/taper formula said 60 min at 79 % and
/// 26 min at 80 %). Targets: while charging, macOS shows ⌊raw⌋ + 1 (440 of 457 powerlog
/// readings; 16 of the other 17 are the first 4 minutes after plug-in, where the shown percent
/// still holds the higher discharging value) and an 85 % limit stopped charging at raw 84.00–84.02 % in all five
/// sessions that reached it, so a limit `T` is raw T − 1 %. Full is where the tapering current
/// reaches the termination current (`chargeTerminationHours`).
///
/// Calibrated 2026-10-05 on this Mac's powerlog (`/private/var/db/powerlog`, 8 charging sessions
/// from 21 % to 85 %, ~30 W adapter, ~1.5–2.2 A): the knee and decline minimise the error of
/// time-to-level predictions; replaying the 4 sessions that ended at the 85 % limit, time to the
/// limit is off by 1.7 min on average (bias −1.6 min, worst −12 min) once the current average
/// has 3 minutes of readings. No data exists above raw 85 % (the limit, and the one full charge
/// happened asleep), so the last stretch to 100 % is the physical model, not a fit.
public func minutesToTarget(currentMAh: Int, maxMAh: Int, chargeMA: Double, targetPercent: Int,
                            knee: Double = 0.8, decline: Double = 0.4) -> Int? {
    guard chargeMA >= 50, maxMAh > 0, currentMAh >= 0, knee > 0, knee < 1,
          decline >= 0, decline * knee < 1 else { return nil }
    let full = Double(maxMAh)
    let s = min(1, Double(currentMAh) / full)
    let atKnee = 1 - decline * knee                 // the factor at the knee, relative to I₀
    // Current at the knee: from I₀ below it, or back from the taper line above it.
    let kneeMA = s < knee ? chargeMA / (1 - decline * s) * atKnee : chargeMA * (1 - knee) / max(1e-9, 1 - s)

    let target: Double
    if targetPercent >= 100 {
        let terminationMA = full / chargeTerminationHours
        target = max(knee, 1 - (1 - knee) * terminationMA / kneeMA)
        if s >= target { return 1 }                 // tapered to the end: finishing now
    } else {
        target = Double(max(1, targetPercent) - 1) / 100
        guard s < target else { return nil }
    }

    var hours = 0.0
    if s < knee {                                   // ∫ ds / (I₀ (1 − d·s)) over [s, min(target, knee)]
        let base = kneeMA / atKnee, end = min(target, knee)
        hours += decline > 0
            ? full / base * (log(1 - decline * s) - log(1 - decline * end)) / decline
            : full / base * (end - s)
    }
    if target > knee {                              // ∫ ds / (I_knee (1 − s) / (1 − knee))
        hours += full * (1 - knee) / kneeMA * log((1 - max(s, knee)) / (1 - target))
    }
    return max(1, Int((hours * 60).rounded()))
}

/// The charge level macOS will stop at, learned from where charging actually stops: the state
/// goes from charging to held (not charging / charged) below 100 % (a manual charge limit or
/// Optimized Charging's hold). Only that transition counts: a full Mac left on AC drifts to
/// 95–99 % while still "charged" (pmset: AC 100 → 95 % on Sep 30), and plugging in above a limit
/// holds wherever the charge happens to be; neither is a limit. Charging past it later means
/// the limit is gone. Holds below 50 % are not taken as limits.
public func learnedChargeLimit(previous: Int?, previousState: BatteryState?, state: BatteryState,
                               percent: Int) -> Int? {
    switch state {
    case .notCharging, .charged:
        guard previousState == .charging else { return previous }
        return (50...99).contains(percent) ? percent : previous
    case .charging:
        if let previous, percent > previous { return nil }
        return previous
    case .discharging:
        return previous
    }
}

/// What powerd's charging-policy file says about a charge limit.
public enum ChargeLimitHint: Equatable {
    /// File missing, unreadable, from another boot, or in an unknown format.
    case unknown
    /// Readable, and no active policy caps the charge.
    case noLimit
    /// An active policy stops charging at this percent.
    case limit(Int)
}

/// Parses `/Library/Preferences/com.apple.powerd.charging.plist` (macOS 26): a plist whose
/// `policies` value is an NSKeyedArchiver blob of charge-control policies, each archived as a
/// dictionary with `soclimit` (percent), `terminated` and a `reason` (e.g. a manual charge
/// limit). Private format, so anything unexpected yields `.unknown`.
public func parsePowerdChargeLimit(_ data: Data?, bootSessionUUID: String?) -> ChargeLimitHint {
    guard let data,
          let outer = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let blob = outer["policies"] as? Data,
          let archive = try? PropertyListSerialization.propertyList(from: blob, format: nil) as? [String: Any],
          let objects = archive["$objects"] as? [Any] else {
        return .unknown
    }
    if let fileBoot = outer["bootSessionUUID"] as? String, let bootSessionUUID, fileBoot != bootSessionUUID {
        return .unknown   // written before this boot: may describe a policy that no longer runs
    }
    let limits = objects.compactMap { object -> Int? in
        guard let policy = object as? [String: Any],
              let limit = (policy["soclimit"] as? NSNumber)?.intValue,
              (1...99).contains(limit),
              (policy["terminated"] as? NSNumber)?.boolValue != true else { return nil }
        return limit
    }
    return limits.min().map(ChargeLimitHint.limit) ?? .noLimit
}

/// Reads powerd's charging-policy file (a few hundred bytes, world-readable). Cheap enough to
/// call when the battery percent or state changes.
public func readPowerdChargeLimit() -> ChargeLimitHint {
    let url = URL(fileURLWithPath: "/Library/Preferences/com.apple.powerd.charging.plist")
    var buffer = [CChar](repeating: 0, count: 64)
    var size = buffer.count
    let boot = sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0
        ? String(cString: buffer) : nil
    return parsePowerdChargeLimit(try? Data(contentsOf: url), bootSessionUUID: boot)
}
