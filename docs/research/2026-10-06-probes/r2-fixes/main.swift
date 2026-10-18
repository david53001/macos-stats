// Review round 2 fixes: headless stability probe. Adapted from reviewer B's round-2 probe
// (docs/reviews/2026-10-06-stability-tour/r2-B/probe-src/stability-main.swift), plus reviewer A's
// "still pointer" case. Compiled with a checkout's Sources/MacStatsCore by run.sh; no window, no UI.
//
// Four breakdown runs at the app's cadence (scan at 0, 0.5 s, then every 2 s), all on live processes:
//   cpu, memory, energy: pointer outside, then inside for 20 s from 45 % of the run (it MOVED onto the
//     list), then outside again. The user expands the app with the most processes early and keeps it.
//   still: CPU, the pointer rests on the list from the moment it opens and never moves (the clicked
//     card sits where the list appears). Reviewer A: the order froze at the first 0.5 s scan.
// Plus the overview cards at 0.5 s ticks. Prints key=value lines.
// -D R2BASE builds against the code before the round-2 fixes (66141b1): its pointer probe returns
// a Bool and the expanded app is pinned by the store.
import AppKit
import Darwin

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let total = args.count > 1 ? Double(args[1]) ?? 150 : 150
let T1 = total * 0.45, T2 = T1 + 20

final class ScanSession {
    let scanner = BreakdownScanner()
    var appHasBundleID: [Int32: Bool] = [:]
    func scan(metric: BreakdownMetric) -> BreakdownScanner.Result {
        var hasBundleID: [Int32: Bool] = [:]
        let anchors = attributionAnchors(NSWorkspace.shared.runningApplications.map { app in
            let pid = Int32(app.processIdentifier)
            let hasID = appHasBundleID[pid] ?? (app.bundleIdentifier != nil)
            hasBundleID[pid] = hasID
            return RunningAppInfo(pid: pid, hasBundleIdentifier: hasID,
                                  isBackgroundOnly: app.activationPolicy == .prohibited)
        })
        appHasBundleID = hasBundleID
        let time = Date().timeIntervalSinceReferenceDate
        let absTime = mach_absolute_time()
        let ticks = readCPUTicks()
        let raw = readRawProcesses(includeEnergy: metric == .energy)
        return scanner.scan(raw, appPIDs: anchors.apps, fallbackAppPIDs: anchors.fallbacks,
                            metric: metric, time: time, absTime: absTime, cpuTicks: ticks)
    }
}

func cpuSeconds() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return s(u.ru_utime) + s(u.ru_stime)
}

func nm(_ k: Int32) -> String {
    k == -1 ? "Other processes" : k == -2 ? "System" : NSRunningApplication(processIdentifier: k)?.localizedName ?? "pid\(k)"
}

/// Text-change counter with flip-back (A→B→A on consecutive changes) detection.
struct TextTrack {
    var last: String?
    var prev: String?
    var changes = 0
    var flipBacks = 0
    mutating func see(_ s: String, count: Bool = true) {
        if let l = last, l != s {
            if count { changes += 1; if s == prev { flipBacks += 1 } }
            prev = l
        }
        last = s
    }
}

@MainActor final class BreakdownRun {
    let name: String
    let metric: BreakdownMetric
    let still: Bool
    let store = MetricsStore()
    let session = ScanSession()
    var pointerInside = false
    var expanded: Int32?
    var collapses = 0
    var lastTop8: [Int32]?
    var orderChanges = 0, slotChanges = 0
    var countedSeconds = 0.0
    var rowText: [Int32: TextTrack] = [:]
    var misSortScans = 0, scansCounted = 0, examples = 0
    var misSortPairs = 0, misSortPairsInvolvingExpanded = 0
    var holdErrSteps: [Double] = []
    var relErr: [Double] = []
    var freezeStartOrder: [Int32]?
    var freezeMoves = 0, freezeScans = 0
    var lastScanTime: Date?
    var sumGap = 0.0

    init(_ name: String, _ m: BreakdownMetric, still: Bool = false) {
        self.name = name
        metric = m
        self.still = still
        store.beginBreakdown(metric: m)
#if R2BASE
        store.breakdownPointerProbe = { [unowned self] in self.pointerInside }
#else
        // Moved onto the list (cpu/memory/energy) or resting where the click was (still).
        store.breakdownPointerProbe = { [unowned self] in
            BreakdownPointer(inside: self.pointerInside, moved: !self.still)
        }
#endif
    }

    func step(_ s: Double) -> Double { breakdownValueStep(metric, s) }

    func scan(now: Date, elapsed: Double) {
        let wantInside = still || (elapsed >= T1 && elapsed < T2)
        if wantInside != pointerInside {
            pointerInside = wantInside
            store.setBreakdownPointerInside(wantInside, time: now.timeIntervalSinceReferenceDate)
        }
        let r = session.scan(metric: metric)
        store.setBreakdown(r.apps, measuring: r.measuring, totalCPU: r.totalCPUPercent,
                           time: now.timeIntervalSinceReferenceDate)
        let interval = lastScanTime.map { now.timeIntervalSince($0) } ?? 0
        lastScanTime = now
        guard !store.breakdownMeasuring else { return }
        let rows = store.breakdown
        let ids = rows.map(\.appPID)

        if !still, expanded == nil, elapsed < T1, collapses == 0 {
            expanded = rows.filter(\.isApp).max { $0.processes.count < $1.processes.count }?.appPID
#if R2BASE
            store.setBreakdownPinnedApp(expanded)
#endif
        }
        if let e = expanded {
            let count = rows.first { $0.appPID == e }?.processes.count ?? 0
            if count <= 1 {
                collapses += 1; expanded = nil
#if R2BASE
                store.setBreakdownPinnedApp(nil)
#endif
            }
        }

        // A list the user is pointing at (moved onto it) must not move; a still pointer doesn't count.
        let frozenNow = pointerInside && !still
        let inUnfreezeTail = !frozenNow && !still && elapsed >= T2 && elapsed < T2 + 3.5
        if frozenNow {
            freezeScans += 1
            if let start = freezeStartOrder {
                for (i, k) in start.enumerated() { if let j = ids.firstIndex(of: k), j != i { freezeMoves += 1 } }
            } else {
                freezeStartOrder = ids
            }
        }

        let top8 = Array(ids.prefix(8))
        if let last = lastTop8 {
            var slots = 0
            for i in 0..<min(8, max(last.count, top8.count)) {
                let o = i < last.count ? last[i] : nil, n = i < top8.count ? top8[i] : nil
                if o != n { slots += 1 }
            }
            if !frozenNow && !inUnfreezeTail {
                if last != top8 { orderChanges += 1 }
                slotChanges += slots
                countedSeconds += interval
            }
        }
        lastTop8 = top8

        if !frozenNow {
            scansCounted += 1
            var misSorted = false
            let shown = rows.prefix(8).map { store.shownValue(app: $0.appPID) ?? $0.value(for: metric) }
            for i in 1..<max(1, shown.count) {
                let a = shown[i - 1], b = shown[i]
                if metric == .memory && (rows[i].appPID < 0) != (rows[i - 1].appPID < 0) { continue }
                // A row printed clearly higher than the row above it (> 25 % and > 2 printed steps).
                if b > a * 1.25 && b - a > 2 * step(b) {
                    let pin = rows[i].appPID == expanded || rows[i - 1].appPID == expanded
                    misSortPairs += 1
                    if pin { misSortPairsInvolvingExpanded += 1 }
                    misSorted = true
                    if examples < 6 {
                        examples += 1
                        print(String(format: "MISSORT %@ t=%.0f %@ %@ above %@ %@%@", name, elapsed,
                                     nm(rows[i - 1].appPID), breakdownValueText(metric, a),
                                     nm(rows[i].appPID), breakdownValueText(metric, b), pin ? " [expanded]" : ""))
                    }
                }
            }
            if misSorted { misSortScans += 1 }
            for (i, app) in rows.prefix(8).enumerated() {
                let exact = app.value(for: metric)
                holdErrSteps.append(abs(shown[i] - exact) / step(exact))
                if exact > 0.5 * step(exact) { relErr.append(abs(shown[i] - exact) / exact) }
                rowText[app.appPID, default: TextTrack()].see(breakdownValueText(metric, shown[i]),
                                                              count: !inUnfreezeTail)
            }
        }
        if metric == .cpu, let h = store.breakdownShownTotalCPU {
            let s = rows.reduce(0) { $0 + (store.shownValue(app: $1.appPID) ?? $1.cpuPercent) }
            sumGap = max(sumGap, abs(s - h))
        }
    }

    func report() {
        let mins = max(countedSeconds, 1) / 60
        let texts = rowText.values.reduce(0) { $0 + $1.changes }
        let flips = rowText.values.reduce(0) { $0 + $1.flipBacks }
        func p(_ k: String, _ v: Any) { print("\(name).\(k)=\(v)") }
        p("top8_order_changes_per_min", String(format: "%.1f", Double(orderChanges) / mins))
        p("top8_slot_changes_per_min", String(format: "%.1f", Double(slotChanges) / mins))
        p("row_text_changes_per_min_top8", String(format: "%.1f", Double(texts) / mins))
        p("row_text_flipbacks_per_min_top8", String(format: "%.1f", Double(flips) / mins))
        p("missorted_scans", "\(misSortScans)/\(scansCounted) pairs=\(misSortPairs) next_to_expanded=\(misSortPairsInvolvingExpanded)")
        let sorted = holdErrSteps.sorted()
        if !sorted.isEmpty {
            p("hold_err_steps_p50_p95_max", String(format: "%.2f/%.2f/%.2f", sorted[sorted.count / 2],
                                                    sorted[Int(Double(sorted.count) * 0.95)], sorted.last!))
        }
        let re = relErr.sorted()
        if !re.isEmpty {
            p("hold_err_rel_p95_max", String(format: "%.3f/%.3f", re[Int(Double(re.count) * 0.95)], re.last!))
        }
        if !still {
            p("expanded_app", expanded.map(nm) ?? "none")
            p("expanded_auto_collapses", collapses)
            p("freeze_scans", freezeScans)
            p("freeze_row_moves", freezeMoves)
        }
        if metric == .cpu { p("max_sum_vs_header_gap_pp", String(format: "%.2f", sumGap)) }
    }
}

struct Snap { let time: Date; let cpu: CPUTicks; let net: NetCounters }

@MainActor func runAll() {
    let overview = MetricsStore()
    let totalMem = ProcessInfo.processInfo.physicalMemory
    var snaps: [Snap] = []
    var cpuT = TextTrack(), memT = TextTrack(), downT = TextTrack(), upT = TextTrack()
    var cpuErr: [Double] = []
    @MainActor func tick(_ now: Date) {
        snaps.append(Snap(time: now, cpu: readCPUTicks(), net: readNetCounters()))
        let base = rateBaselineIndex(times: snaps.lazy.map { $0.time.timeIntervalSinceReferenceDate },
                                     now: now.timeIntervalSinceReferenceDate, window: rateWindowSeconds)
        if base > 0 { snaps.removeFirst(base) }
        guard snaps.count > 1, let cur = snaps.last else { return }
        let b = snaps[0]
        let cpu = cpuBusyPercent(previous: b.cpu, current: cur.cpu)
        let net = networkThroughput(previous: b.net, current: cur.net, secondsElapsed: now.timeIntervalSince(b.time))
        let mem = memorySample(raw: readVMRaw(), totalBytes: totalMem, pressureLevel: readMemoryPressureLevel())
        overview.record(cpuPercent: cpu, memory: mem, network: net, time: now.timeIntervalSinceReferenceDate)
        cpuT.see("\(Int(overview.cardCPUPercent.rounded()))%")
        cpuErr.append(abs(overview.cardCPUPercent - cpu))
        memT.see(String(format: "%.1f", Double(overview.cardMemory?.usedBytes ?? 0) / 1_073_741_824))
        downT.see(formattedRate(bytesPerSecond: overview.cardNetwork?.downBytesPerSec ?? 0))
        upT.see(formattedRate(bytesPerSecond: overview.cardNetwork?.upBytesPerSec ?? 0))
    }

    let runs = [BreakdownRun("cpu", .cpu), BreakdownRun("memory", .memory), BreakdownRun("energy", .energy),
                BreakdownRun("still", .cpu, still: true)]
    let start = Date(), c0 = cpuSeconds()
    var nextTick = start, nextScan = start, scans = 0
    while true {
        let now = Date(), el = now.timeIntervalSince(start)
        if el >= total { break }
        if now >= nextTick { tick(now); nextTick = nextTick.addingTimeInterval(0.5) }
        if now >= nextScan {
            for r in runs { r.scan(now: now, elapsed: el) }
            scans += 1
            nextScan = scans == 1 ? start.addingTimeInterval(firstRescanDelay)
                                  : nextScan.addingTimeInterval(breakdownScanInterval)
        }
        RunLoop.current.run(until: min(nextTick, nextScan))
    }
    let wall = Date().timeIntervalSince(start), m = wall / 60
    print("run_s=\(Int(wall)) phases: outside [0,\(Int(T1))) inside [\(Int(T1)),\(Int(T2))) outside after")
    print(String(format: "card.cpu changes/min=%.1f flipbacks/min=%.1f", Double(cpuT.changes) / m, Double(cpuT.flipBacks) / m))
    let ce = cpuErr.sorted()
    print(String(format: "card.cpu held-vs-exact pp p50=%.2f p95=%.2f max=%.2f", ce[ce.count / 2],
                 ce[Int(Double(ce.count) * 0.95)], ce.last!))
    print(String(format: "card.mem changes/min=%.1f flipbacks/min=%.1f", Double(memT.changes) / m, Double(memT.flipBacks) / m))
    print(String(format: "card.down changes/min=%.1f flipbacks/min=%.1f", Double(downT.changes) / m, Double(downT.flipBacks) / m))
    print(String(format: "card.up changes/min=%.1f flipbacks/min=%.1f", Double(upT.changes) / m, Double(upT.flipBacks) / m))
    let mean = overview.cpuHistory.reduce(0) { $0 + $1.value } / Double(max(1, overview.cpuHistory.count))
    print(String(format: "machine_cpu_mean_last_minute=%.1f", mean))
    for r in runs { r.report() }
    print(String(format: "probe_process_cpu_pct=%.2f (4 breakdown scans + overview)", (cpuSeconds() - c0) / wall * 100))
}

MainActor.assumeIsolated { runAll() }

/// The second scan's delay in the measured checkout: 0.5 s before review round 3, then one scan
/// interval ("Measuring…" until the first full scan). run.sh sets FIRST_RESCAN from the sources.
// Computed: a stored global at the end of main.swift would still be 0 when the code above runs.
var firstRescanDelay: TimeInterval {
    #if FIRST_RESCAN
    breakdownFirstRescanDelay
    #else
    breakdownScanInterval
    #endif
}
