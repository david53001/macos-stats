import Foundation

/// Whether the user is currently looking at the popover.
public enum Visibility: Equatable {
    case idle          // popover closed — only menu-bar values matter
    case popoverOpen   // popover open — refresh fast
}

/// The adaptive refresh interval (seconds) for a given visibility.
/// Idle is slow & cheap; open is 1s. (Milestone 3 adds a drilled-in case.)
public func refreshInterval(for visibility: Visibility) -> TimeInterval {
    switch visibility {
    case .idle: return 3.0
    case .popoverOpen: return 1.0
    }
}

/// Open-phase priming burst. When the popover opens, the sparklines start empty, so for
/// the first `burstSamples` samples we collect rapidly (`burstInterval` apart) to fill the
/// graph with real data within ~1 second, then settle to the normal open cadence.
/// These two constants are the single knob for the burst's feel.
public let burstInterval: TimeInterval = 0.1   // ~100ms between priming samples
public let burstSamples: Int = 10              // ~1s of burst ⇒ ~10 real points

/// Once the priming fill is done, the interval eases up to the steady cadence by multiplying
/// the gap by this factor each sample. Ramping (rather than jumping straight from `burstInterval`
/// to 1s) avoids the visible ~1s stall the hard cliff used to leave right after the fill.
public let burstGrowth: Double = 2.0

/// Interval until the next sample while the popover is open, given how many samples have
/// already been collected since it opened. Fast & dense during the priming fill, then a
/// smooth ramp up to the steady 1s cadence — see `burstGrowth`.
public func openPhaseInterval(samplesSinceOpen: Int) -> TimeInterval {
    let steady = refreshInterval(for: .popoverOpen)
    if samplesSinceOpen < burstSamples { return burstInterval }   // dense fast fill (~1s)
    let rampStep = samplesSinceOpen - burstSamples + 1            // 1, 2, 3, …
    return min(steady, burstInterval * pow(burstGrowth, Double(rampStep)))
}

/// Rate metrics (CPU %, network throughput) are averaged over this trailing window, regardless
/// of how fast we sample/plot. Without it, the fast opening fill would divide tiny sample-to-
/// sample deltas by tiny intervals, inflating readings — and the first steady sample would then
/// "drop" to the true value. A fixed window keeps the values stable and accurate throughout.
public let rateWindowSeconds: TimeInterval = 1.0

/// Index of the snapshot a rate should diff against, given snapshot times oldest→newest, the
/// current time, and the trailing `window`. Returns the newest snapshot still at least `window`
/// old (so the rate spans ~`window` seconds), or the oldest available when there isn't yet a
/// full window of history. The current (last) snapshot is never chosen, so the window is always
/// positive. Assumes `times` is non-empty and ascending.
public func rateBaselineIndex(times: [TimeInterval], now: TimeInterval, window: TimeInterval) -> Int {
    let cutoff = now - window
    var baseline = 0
    for i in 0..<times.count {
        if times[i] <= cutoff { baseline = i } else { break }
    }
    return baseline
}
