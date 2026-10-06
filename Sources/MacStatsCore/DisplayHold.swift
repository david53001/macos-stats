import Foundation

/// Display holds: the *shown* number keeps its old value until a new reading moves clearly
/// away from it, so a value sitting on a rounding boundary doesn't flip every update. The
/// stored readings (history, alerts) stay exact; only what is printed is held, within the
/// bound each function states. See `docs/research/2026-10-06-stability-diagnosis.md` §5.4.

/// The value to show: `shown` (the last shown value, already quantised to `step`) unless `value`
/// moved at least max(band × step, relBand × |shown|) away from it; then `value` quantised to `step`.
/// nil `shown` → quantised `value`. The error is bounded: |result − value| ≤ max(band × step, relBand × |shown|)
/// (and ≤ step / 2 when the value passes).
public func heldValue(shown: Double?, value: Double, step: Double, band: Double = 0.75,
                      relBand: Double = 0) -> Double {
    guard step > 0, value.isFinite else { return value }
    let quantised = (value / step).rounded() * step
    guard let shown else { return quantised }
    let threshold = max(band * step, relBand * abs(shown))
    return abs(value - shown) < threshold ? shown : quantised
}

/// Memory card + Memory breakdown header/parts as ONE unit: returns `shown` unchanged while
/// |value.used − shown.used| < `step` (0.1 GiB) and the pressure level is the same. Otherwise it returns `value`.
/// A pressure change always passes at once. Holding the whole sample keeps App + Wired + Compressed adding up to Used.
public func heldMemory(shown: MemorySample?, value: MemorySample, step: UInt64 = 107_374_182) -> MemorySample {
    guard let shown, shown.pressure == value.pressure, shown.totalBytes == value.totalBytes else { return value }
    let moved = shown.usedBytes > value.usedBytes ? shown.usedBytes - value.usedBytes
                                                  : value.usedBytes - shown.usedBytes
    return moved < step ? shown : value
}

/// Network rate hold. Step = the printed precision of the shown unit (1 KB/s, or 0.1 MB/s at
/// ≥ 999.5 KB/s, matching `formattedRate`), band 1.5, relBand 0.15. The KB/s ↔ MB/s switch is held the same way.
/// A value that passes is quantised to its own unit's precision.
public func heldRate(shown: Double?, value: Double) -> Double {
    func step(_ bps: Double) -> Double { bps >= 999_500 ? 100_000 : 1_000 }
    let quantised = (value / step(value)).rounded() * step(value)
    guard let shown else { return quantised }
    let threshold = max(1.5 * step(shown), 0.15 * abs(shown))
    return abs(value - shown) < threshold ? shown : quantised
}

/// Battery time left in minutes, held with step = `formatTimeLeft`'s rounding at that length
/// (1 min under 15 min, 5 under 2 h, 15 under 6 h, else 60) and band 0.75: `shown` stays while
/// `minutes` is within 0.75 × the shown length's step of it, else `minutes` (which
/// `formatTimeLeft` rounds as before, so the wording at each length is unchanged).
public func heldTimeLeft(shown: Int?, minutes: Int) -> Int {
    guard let shown else { return minutes }
    let step: Double = switch shown {
    case ..<15: 1
    case ..<120: 5
    case ..<360: 15
    default: 60
    }
    return Double(abs(minutes - shown)) < 0.75 * step ? shown : minutes
}

/// Time to full: falls freely; rises only when `minutes` ≥ shown + 2 (a countdown never ticks up by one).
public func heldTimeToFull(shown: Int?, minutes: Int) -> Int {
    guard let shown, minutes > shown else { return minutes }
    return minutes >= shown + 2 ? minutes : shown
}
