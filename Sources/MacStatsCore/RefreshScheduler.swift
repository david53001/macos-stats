import Foundation

/// Whether the user is currently looking at the popover.
public enum Visibility: Equatable {
    case idle          // popover closed — only the slow background sampler runs
    case popoverOpen   // popover open — refresh fast
}

/// The adaptive refresh interval (seconds) for a given visibility.
/// Idle is slow & cheap (alerts + a coarse history); open is 0.5s so numbers feel live.
/// Rates stay a 1s average regardless (see `rateWindowSeconds`), so the faster cadence
/// doesn't make values flicker. The per-app drill-in runs its own scan timer in AppModel.
public func refreshInterval(for visibility: Visibility) -> TimeInterval {
    switch visibility {
    case .idle: return 10.0
    case .popoverOpen: return 0.5
    }
}

/// How late macOS may fire each refresh timer, so it can coalesce our wakeups with other
/// work (saves energy). ~10% of the open cadence; the idle sampler only feeds alerts and a
/// coarse history, so it tolerates a couple of seconds.
public func refreshTolerance(for visibility: Visibility) -> TimeInterval {
    switch visibility {
    case .idle: return 2.0
    case .popoverOpen: return 0.05
    }
}

/// Slower tiers for the reads that cost more than a counter snapshot. Last values are kept
/// in between; both are also read once as the popover opens.
public let temperatureInterval: TimeInterval = 2.0   // IOHID thermal event copies
public let batteryInterval: TimeInterval = 10.0      // IOPowerSources dictionary parse; changes slowly

/// Hovering the menu-bar icon takes an extra idle sample; skip it if one was taken this recently.
public let prewarmMinInterval: TimeInterval = 1.0

/// The CPU breakdown shows "Measuring…" until its second process scan (a delta needs two), so
/// that scan comes quickly; later scans settle to `breakdownScanInterval`.
public let breakdownFirstRescanDelay: TimeInterval = 0.3
public let breakdownScanInterval: TimeInterval = 1.0

/// Whether a tiered read last done at `last` (nil = never) is due again at `now`.
public func isDue(last: Date?, now: Date, every interval: TimeInterval) -> Bool {
    guard let last else { return true }
    return now.timeIntervalSince(last) >= interval
}

/// Rate metrics (CPU %, network throughput) are averaged over this trailing window, regardless
/// of how fast we sample/plot. Without it, fast ticks would divide tiny sample-to-sample deltas
/// by tiny intervals, making readings jumpy. A fixed window keeps the values stable and accurate.
public let rateWindowSeconds: TimeInterval = 1.0

/// Index of the snapshot a rate should diff against, given snapshot times oldest→newest, the
/// current time, and the trailing `window`. Returns the newest snapshot still at least `window`
/// old (so the rate spans ~`window` seconds), or the oldest available when there isn't yet a
/// full window of history. The current (last) snapshot is never chosen, so the window is always
/// positive. Assumes `times` is non-empty and ascending. Generic so callers can pass a lazy map
/// without allocating an array each tick.
public func rateBaselineIndex<C: Collection>(times: C, now: TimeInterval,
                                             window: TimeInterval) -> Int where C.Element == TimeInterval {
    let cutoff = now - window
    var baseline = 0
    for (i, t) in times.enumerated() {
        if t <= cutoff { baseline = i } else { break }
    }
    return baseline
}
