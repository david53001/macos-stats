import Foundation

/// Display holds: the *shown* number keeps its old value until a new reading moves clearly
/// away from it, so a value sitting on a rounding boundary doesn't flip every update. The
/// stored readings (history, alerts) stay exact; only what is printed is held, within the
/// bound each function states. See `docs/research/2026-10-06-stability-diagnosis.md` §5.4.

/// The value to show: `shown` (the last shown value, already quantised to `step`) unless `value`
/// moved at least max(band × step, min(relBand × |shown|, cap)) away from it; then `value` quantised to
/// `step`. nil `shown` → quantised `value`. The error is bounded by that threshold (and ≤ step / 2 when
/// the value passes).
public func heldValue(shown: Double?, value: Double, step: Double, band: Double = 0.75,
                      relBand: Double = 0, cap: Double = .infinity) -> Double {
    guard step > 0, value.isFinite else { return value }
    let quantised = (value / step).rounded() * step
    guard let shown else { return quantised }
    let threshold = max(band * step, min(relBand * abs(shown), cap))
    return abs(value - shown) < threshold ? shown : quantised
}

/// A breakdown row's printed value, read once a scan: `heldValue`, but a reading that passes the hold
/// is shown only when the previous reading passed it in the same direction too, or when it moved at
/// least twice the hold's threshold. So a one-scan blip never prints and an A→B→A flip takes two scans
/// each way; a real change shows one scan later, a big one at once. nil `shown` → quantised `value`.
public struct HeldReading: Equatable, Sendable {
    public private(set) var shown: Double
    /// The last reading passed the hold, in this direction.
    private var pending: FloatingPointSign?

    public init(_ value: Double, step: Double) {
        shown = step > 0 && value.isFinite ? (value / step).rounded() * step : value
    }

    public mutating func update(_ value: Double, step: Double, band: Double = 0.75, relBand: Double = 0,
                                cap: Double = .infinity) {
        guard step > 0, value.isFinite else { return }
        let threshold = max(band * step, min(relBand * abs(shown), cap))
        let moved = value - shown
        guard abs(moved) >= threshold else { pending = nil; return }
        if abs(moved) >= 2 * threshold || pending == moved.sign {
            shown = (value / step).rounded() * step
            pending = nil
        } else {
            pending = moved.sign
        }
    }
}

/// The cards' minimum dwell: a held card value that would change waits until it has been shown
/// `dwell` seconds (`since` nil = no wait), unless the reading made a `bigMove`, which never waits.
public func dwellAllows(since: TimeInterval?, now: TimeInterval, dwell: TimeInterval = cardDwellSeconds,
                        bigMove: Bool) -> Bool {
    guard let since, !bigMove else { return true }
    return now - since >= dwell
}

/// Memory card + Memory breakdown header/parts as ONE unit: returns `shown` unchanged while
/// `value.used` is less than `step` (0.1 GiB) from the figure `shown` prints (its used, rounded to
/// `step`) and the pressure level is the same. Otherwise it returns `value`. Measured from the printed
/// figure, so a ±0.1 GiB swing can't flip the text back. A pressure change always passes at once.
/// Holding the whole sample keeps App + Wired + Compressed adding up to Used.
public func heldMemory(shown: MemorySample?, value: MemorySample, step: UInt64 = 107_374_182) -> MemorySample {
    guard let shown, shown.pressure == value.pressure, shown.totalBytes == value.totalBytes else { return value }
    let s = Double(step)
    let printed = (Double(shown.usedBytes) / s).rounded() * s
    return abs(Double(value.usedBytes) - printed) < s ? shown : value
}

/// Network rate hold. Step = the printed precision of the shown unit (1 KB/s, or 0.1 MB/s at
/// ≥ 999.5 KB/s, matching `formattedRate`), band 2 (a few KB/s of background chatter, mostly ↑, stays
/// put), relBand 0.15 (the card's ↑ line uses 0.2: small uploads jitter more). The KB/s ↔ MB/s switch
/// is held the same way. A value that passes is quantised to its own unit's precision.
public func heldRate(shown: Double?, value: Double, relBand: Double = 0.15) -> Double {
    func step(_ bps: Double) -> Double { bps >= 999_500 ? 100_000 : 1_000 }
    let quantised = (value / step(value)).rounded() * step(value)
    guard let shown else { return quantised }
    let threshold = max(2 * step(shown), relBand * abs(shown))
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
