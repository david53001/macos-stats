import Foundation

/// Time to full, measured instead of taken from macOS.
///
/// macOS's `AvgTimeToFull` jumps around (132 → 96 → 112 → 82 min within minutes), implies
/// about half the measured charge current, and ignores an active charge limit: at 74 % with an
/// 85 % limit it said 82 min while charging stopped ~25 min later. Here: the charge current is
/// measured (gauge `Amperage`), the target is the charge limit when one is active, and the
/// charger's slowdown near full (constant-voltage phase) is modelled with a knee and a taper.

/// Smoothed charge current (mA) from the gauge's positive `Amperage` readings.
public struct ChargeCurrent: Equatable {
    public static let tau: TimeInterval = 5 * 60
    public private(set) var milliamps: Double?

    public init() {}

    /// One gauge reading `seconds` after the previous one (0 seeds). Non-positive currents
    /// (discharging, held) are ignored.
    public mutating func ingest(milliamps value: Int, seconds: TimeInterval) {
        guard value > 0 else { return }
        guard let average = milliamps else { milliamps = Double(value); return }
        let alpha = 1 - exp(-max(0, seconds) / Self.tau)
        milliamps = average + alpha * (Double(value) - average)
    }

    public mutating func reset() { milliamps = nil }
}

/// Minutes to charge from `currentMAh` to `targetPercent` of `maxMAh` at `chargeMA`, or nil
/// when there's no usable current or the target is already reached.
///
/// Below `knee` the charger holds a constant current; above it the current tapers, averaging
/// `taper` × the constant-current rate. Above the knee the measured current is already the
/// tapered one, so it is used as is. Checked against this Mac's pmset log (63 → 85 % in 35 min
/// at ~1980 mA, vs 29 min at constant current): knee 0.8 / taper 0.45 predicts 37 min.
public func minutesToTarget(currentMAh: Int, maxMAh: Int, chargeMA: Double, targetPercent: Int,
                            knee: Double = 0.8, taper: Double = 0.45) -> Int? {
    guard chargeMA >= 50, maxMAh > 0 else { return nil }
    let current = Double(currentMAh), full = Double(maxMAh)
    let target = Double(min(100, max(1, targetPercent))) / 100 * full
    let kneeMAh = knee * full
    guard current < target else { return nil }
    let constant = max(0, min(target, kneeMAh) - current) / chargeMA
    let taperRate = current >= kneeMAh ? chargeMA : chargeMA * taper
    let tapered = max(0, target - max(current, kneeMAh)) / taperRate
    return max(1, Int(((constant + tapered) * 60).rounded()))
}

/// `minutesToTarget` from the percent macOS shows. The charge limit is in that percent, which
/// runs a few points off the gauge's raw charge (71 % shown at 3004 / 4431 mAh = 67.8 % raw):
/// aiming at raw 85 % would overshoot an 85 % limit by ~4 points (~+12 min). So the charge is
/// placed at `percent` of `maxMAh`; the remaining distance and the knee are in the same terms.
public func minutesToTarget(percent: Int, maxMAh: Int, chargeMA: Double, targetPercent: Int,
                            knee: Double = 0.8, taper: Double = 0.45) -> Int? {
    guard percent < targetPercent else { return nil }
    let currentMAh = Int((Double(min(100, max(0, percent))) / 100 * Double(maxMAh)).rounded())
    return minutesToTarget(currentMAh: currentMAh, maxMAh: maxMAh, chargeMA: chargeMA,
                           targetPercent: targetPercent, knee: knee, taper: taper)
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
