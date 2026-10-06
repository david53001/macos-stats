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

/// Breakdown scans come every 2 s, and each row is averaged over the last `trailingWindowSeconds`.
/// CPU and energy show "Measuring…" until the second scan (a delta needs two), so their first
/// numbers already cover 2 s: shown after a 0.5 s first window, they were noise that the next scan
/// re-sorted, moving 5–8 of the top 8 rows 2.5 s after the list appeared.
/// With 1 s scans and 1 s values the CPU breakdown's top-8 order changed on every scan (59 a
/// minute) and VS Code read 0.2–7.3 % between scans; 2 s scans over a 4 s window, with the
/// ranking hysteresis, measured 5–13 order changes a minute, and halve the scan cost
/// (`docs/research/2026-10-06-stability-diagnosis.md` §4.1, variant D). Activity Monitor's own
/// default refresh is 5 s.
public let breakdownScanInterval: TimeInterval = 2.0
/// The span breakdown CPU rows (and the CPU header) are averaged over: the last four scan
/// intervals (`BreakdownScanner`). Memory rows stay instantaneous. 8 s, not 4: replaying the same
/// 5 min of live scans, the top 8 reordered 5.1 → 3.6 times a minute (with the inversion timeout),
/// scans showing a lower number above a higher one went 83 → 10 of 149, and each row's text
/// changed every 35 s instead of 15 s. Activity Monitor averages over 5 s.
public let trailingWindowSeconds: TimeInterval = 8.0
/// The Battery breakdown's rows: CPU energy is counted in lumps, so idle apps' 0.01–0.05 W
/// readings swapped places every few seconds over 4 s (and still every ~10 s over 8 s: 36 of 149
/// scans showed an inversion); over 16 s, 0 reorders and 0 inversions in the same replay.
public let energyWindowSeconds: TimeInterval = 16.0
/// A breakdown's window restarts from the latest scan interval when that interval was busier than the
/// rest of the window by this many cores' worth of CPU (`BreakdownScanner`), so a new load shows at
/// once in the rows and header, as on the CPU card. Three quarters of a core: a new one-core load clears
/// it on its first or second scan; the usual scan-to-scan wobble of a busy Mac stays averaged.
public let breakdownFastAttackCores: Double = 0.75
/// Apart from a big jump, a breakdown list (the apps, or one app's processes) reorders at most this
/// often while the pointer is away (`BreakdownDisplay`): every third 2 s scan. Activity Monitor
/// re-sorts every 5 s. Without it, apps racing at similar, bursty CPU reordered on most scans.
public let breakdownReorderDwell: TimeInterval = 5.0
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
/// 2 s, not 1 s: at 0.5 s ticks a 1 s window changed the CPU card's text 80–91 times a minute and
/// the network card's 50–103; 2 s (with the cards' display holds) measured 56–72 and 17–26
/// (`docs/research/2026-10-06-stability-diagnosis.md` §4.2). The closed-popover sampler's
/// snapshots are 10 s apart, so it is unaffected.
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
