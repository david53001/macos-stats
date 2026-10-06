import Foundation

/// Whether the user is currently looking at the popover.
public enum Visibility: Equatable {
    case idle          // popover closed — only the slow background sampler runs
    case popoverOpen   // popover open — refresh fast
}

/// The adaptive refresh interval (seconds) for a given visibility.
/// Idle is slow & cheap (alerts + a coarse history); open is 0.5s so numbers feel live.
/// Rates stay a 2s average regardless (see `rateWindowSeconds`), so the faster cadence
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

// The breakdown's steadiness constants. What each rule does, why this value, and the test that pins
// it: docs/design/breakdown-stability.md (measurements: docs/research/2026-10-06-stability-diagnosis.md
// and the probes in docs/research/2026-10-06-probes/).

/// Breakdown scans come every 2 s. CPU and energy show "Measuring…" until the second scan (a delta
/// needs two), so their first numbers already cover 2 s. Activity Monitor refreshes every 5 s.
public let breakdownScanInterval: TimeInterval = 2.0
/// The span breakdown CPU rows (and the CPU header) are averaged over: the last four scan intervals
/// (`BreakdownScanner`). Memory rows stay instantaneous. Activity Monitor averages over 5 s.
public let trailingWindowSeconds: TimeInterval = 8.0
/// The Battery breakdown's span: CPU energy is counted in lumps, so idle apps' 0.01–0.05 W rows
/// swap places over shorter spans.
public let energyWindowSeconds: TimeInterval = 16.0
/// A breakdown's window restarts from the latest scan interval when an app used this many cores more,
/// or fewer, over that interval than over the rest of the window (`BreakdownScanner`): a load that
/// starts or ends shows in the rows and header within a scan, as on the CPU card. An app's usual
/// scan-to-scan wobble stays well under it and stays averaged.
public let breakdownFastAttackCores: Double = 0.75
/// Apart from a big jump, the app list reorders at most this often while the pointer is away
/// (`ListRanking`): every third 2 s scan. Activity Monitor re-sorts every 5 s.
public let breakdownReorderDwell: TimeInterval = 5.0
/// The same for an expanded app's process rows: every fifth scan (their values are small and bursty).
public let breakdownProcessReorderDwell: TimeInterval = 10.0
/// A breakdown's row order stays frozen this long after the pointer leaves the list (or a
/// context menu closes), so moving out and back in to click doesn't meet a reshuffle. Checked
/// against scan timestamps (`MetricsStore.setBreakdown`), not with a timer.
public let breakdownUnfreezeDelay: TimeInterval = 1.0

/// Whether a tiered read last done at `last` (nil = never) is due again at `now`.
public func isDue(last: Date?, now: Date, every interval: TimeInterval) -> Bool {
    guard let last else { return true }
    return now.timeIntervalSince(last) >= interval
}

/// Rate metrics (CPU %, network throughput) are averaged over this trailing window, regardless
/// of how fast we sample/plot. Without it, fast ticks would divide tiny sample-to-sample deltas
/// by tiny intervals, making readings jumpy. A fixed window keeps the values stable and accurate.
/// The closed-popover sampler's snapshots are 10 s apart, so it is unaffected.
public let rateWindowSeconds: TimeInterval = 2.0

/// The overview cards' text changes at most this often (the graphs stay live), unless the reading
/// jumps (`dwellAllows`): with only the holds, the CPU card's text changed about every 1.5 s.
public let cardDwellSeconds: TimeInterval = 2.0

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
