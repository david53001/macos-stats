// Reviewer B (round 2) headless stability probe. Compiled with the CURRENT Sources/MacStatsCore.
// Runs the real scan path (copy of the app's BreakdownScanSession) into three real MetricsStores
// (CPU, Memory, Battery/energy) at the app's cadence, plus the overview path at 0.5 s.
// Phases: [0,T1) pointer outside + expanded app pinned; [T1,T2) pointer inside (freeze via the
// SAME probe closure the view sets: breakdownPointerProbe, plus setBreakdownPointerInside);
// [T2,end) outside again. Prints key=value lines.
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
    let metric: BreakdownMetric
    let store = MetricsStore()
    let session = ScanSession()
    var pointerInside = false
    var expanded: Int32?
    var collapses = 0
    var pinnedVanished = 0
    var pinnedMoves = 0
    var lastPinnedIndex: Int?
    var lastTop8: [Int32]?
    var orderChanges = 0, slotChanges = 0
    var countedSeconds = 0.0
    var rowText: [Int32: TextTrack] = [:]
    var childOrderChanges = 0
    var lastChildOrder: [Int32]?
    var misSortScans = 0, scansCounted = 0, examples = 0
    var misSortPairs = 0, misSortPairsInvolvingPinned = 0
    var relErr: [Double] = []
    var holdErrSteps: [Double] = []
    var freezeStartOrder: [Int32]?
    var freezeMoves = 0, freezeRemoved = 0, freezeAppended = 0, freezeScans = 0
    var freezeChildMoves = 0
    var freezeStartChildren: [Int32]?
    var unfreezeBurst = 0
    var lastScanTime: Date?
    var sumGap = 0.0

    init(_ m: BreakdownMetric) {
        metric = m
        store.beginBreakdown(metric: m)
        store.breakdownPointerProbe = { [unowned self] in self.pointerInside }
    }

    func step(_ s: Double) -> Double { breakdownValueStep(metric, s) }

    func scan(now: Date, elapsed: Double) {
        let wantInside = elapsed >= T1 && elapsed < T2
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

        // The user expands the app with most processes once, early, and leaves it expanded.
        if expanded == nil, elapsed < T1, collapses == 0 {
            expanded = rows.filter(\.isApp).max { $0.processes.count < $1.processes.count }?.appPID
            store.setBreakdownPinnedApp(expanded)
        }
        if let e = expanded {
            let count = rows.first { $0.appPID == e }?.processes.count ?? 0
            if count <= 1 { collapses += 1; expanded = nil; store.setBreakdownPinnedApp(nil) }
        }

        let frozenNow = pointerInside
        let inUnfreezeTail = !frozenNow && elapsed >= T2 && elapsed < T2 + 3.5
        if frozenNow {
            freezeScans += 1
            if freezeStartOrder == nil {
                freezeStartOrder = ids
                if let e = expanded { freezeStartChildren = rows.first { $0.appPID == e }?.processes.map(\.pid) }
            } else if let start = freezeStartOrder {
                for (i, k) in start.enumerated() {
                    if let j = ids.firstIndex(of: k) { if j != i { freezeMoves += 1 } } else { freezeRemoved += 1 }
                }
                freezeAppended = max(freezeAppended, ids.count - start.count)
                if let e = expanded, let sc = freezeStartChildren,
                   let now = rows.first(where: { $0.appPID == e })?.processes.map(\.pid) {
                    for (i, k) in sc.enumerated() where i < now.count && now[i] != k { freezeChildMoves += 1 }
                }
            }
        }

        let top8 = Array(ids.prefix(8))
        if let last = lastTop8 {
            var slots = 0
            for i in 0..<min(8, max(last.count, top8.count)) {
                let o = i < last.count ? last[i] : nil, n = i < top8.count ? top8[i] : nil
                if o != n { slots += 1 }
            }
            if inUnfreezeTail { unfreezeBurst += slots }
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
                // a row printed clearly higher than the row above it (> 25 % and > 2 printed steps)
                if b > a * 1.25 && b - a > 2 * step(b) {
                    let pin = rows[i].appPID == expanded || rows[i - 1].appPID == expanded
                    misSortPairs += 1
                    if pin { misSortPairsInvolvingPinned += 1 }
                    misSorted = true
                    if examples < 12 {
                        examples += 1
                        print(String(format: "MISSORT %@ t=%.0f row%d %@ shown=%@ (exact %@) above row%d %@ shown=%@ (exact %@)%@",
                                     "\(metric)", elapsed,
                                     i - 1, nm(rows[i - 1].appPID), breakdownValueText(metric, a),
                                     breakdownValueText(metric, rows[i - 1].value(for: metric)),
                                     i, nm(rows[i].appPID), breakdownValueText(metric, b),
                                     breakdownValueText(metric, rows[i].value(for: metric)), pin ? " [pinned/expanded]" : ""))
                    }
                }
            }
            if misSorted { misSortScans += 1 }
            for (i, app) in rows.prefix(8).enumerated() {
                let exact = app.value(for: metric)
                let sh = shown[i]
                holdErrSteps.append(abs(sh - exact) / step(exact))
                if exact > 0 { relErr.append(abs(sh - exact) / exact) }
                rowText[app.appPID, default: TextTrack()].see(breakdownValueText(metric, sh), count: !inUnfreezeTail)
            }
            if let e = expanded, let app = rows.first(where: { $0.appPID == e }) {
                if let idx = ids.firstIndex(of: e) {
                    if let l = lastPinnedIndex, l != idx { pinnedMoves += 1 }
                    lastPinnedIndex = idx
                }
                let co = Array(app.processes.prefix(5).map(\.pid))
                if let l = lastChildOrder, l != co { childOrderChanges += 1 }
                lastChildOrder = co
            } else if expanded != nil {
                pinnedVanished += 1
            }
        }
        if metric == .cpu, let h = store.breakdownShownTotalCPU {
            let s = rows.reduce(0) { $0 + (store.shownValue(app: $1.appPID) ?? $1.cpuPercent) }
            sumGap = max(sumGap, abs(s - h))
        }
    }

    func report() {
        let name = "\(metric)"
        let mins = max(countedSeconds, 1) / 60
        let texts = rowText.values.reduce(0) { $0 + $1.changes }
        let flips = rowText.values.reduce(0) { $0 + $1.flipBacks }
        func p(_ k: String, _ v: Any) { print("\(name).\(k)=\(v)") }
        p("counted_s", Int(countedSeconds))
        p("top8_order_changes_per_min", String(format: "%.1f", Double(orderChanges) / mins))
        p("top8_slot_changes_per_min", String(format: "%.1f", Double(slotChanges) / mins))
        p("row_text_changes_per_min_top8", String(format: "%.1f", Double(texts) / mins))
        p("row_text_flipbacks_per_min_top8", String(format: "%.1f", Double(flips) / mins))
        p("missorted_scans", "\(misSortScans)/\(scansCounted) pairs=\(misSortPairs) of_which_next_to_expanded=\(misSortPairsInvolvingPinned)")
        let sorted = holdErrSteps.sorted()
        if !sorted.isEmpty {
            p("hold_err_steps_p50_p95_max", String(format: "%.2f/%.2f/%.2f", sorted[sorted.count / 2],
                                                    sorted[Int(Double(sorted.count) * 0.95)], sorted.last!))
            let re = relErr.sorted()
            p("hold_err_rel_p95_max", String(format: "%.3f/%.3f", re[Int(Double(re.count) * 0.95)], re.last!))
        }
        p("expanded_app", expanded.map(nm) ?? "none")
        p("expanded_moves", pinnedMoves)
        p("expanded_vanished_scans", pinnedVanished)
        p("expanded_auto_collapses", collapses)
        p("expanded_child_top5_order_changes", childOrderChanges)
        p("freeze_scans", freezeScans)
        p("freeze_row_moves", freezeMoves)
        p("freeze_rows_removed", freezeRemoved)
        p("freeze_rows_appended_max", freezeAppended)
        p("freeze_child_moves", freezeChildMoves)
        p("unfreeze_3.5s_slot_changes", unfreezeBurst)
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

    let runs = [BreakdownRun(.cpu), BreakdownRun(.memory), BreakdownRun(.energy)]
    let start = Date(), c0 = cpuSeconds()
    var nextTick = start, nextScan = start, scans = 0
    while true {
        let now = Date(), el = now.timeIntervalSince(start)
        if el >= total { break }
        if now >= nextTick { tick(now); nextTick = nextTick.addingTimeInterval(0.5) }
        if now >= nextScan {
            for r in runs { r.scan(now: now, elapsed: el) }
            scans += 1
            nextScan = scans == 1 ? start.addingTimeInterval(breakdownFirstRescanDelay)
                                  : nextScan.addingTimeInterval(breakdownScanInterval)
        }
        RunLoop.current.run(until: min(nextTick, nextScan))
    }
    let wall = Date().timeIntervalSince(start), m = wall / 60
    print("run_s=\(Int(wall)) phases: outside [0,\(Int(T1))) inside [\(Int(T1)),\(Int(T2))) outside after")
    print(String(format: "card.cpu changes/min=%.1f flipbacks/min=%.1f", Double(cpuT.changes) / m, Double(cpuT.flipBacks) / m))
    let ce = cpuErr.sorted()
    print(String(format: "card.cpu held-vs-exact pp p50=%.2f p95=%.2f max=%.2f", ce[ce.count / 2], ce[Int(Double(ce.count) * 0.95)], ce.last!))
    print(String(format: "card.mem changes/min=%.1f flipbacks/min=%.1f", Double(memT.changes) / m, Double(memT.flipBacks) / m))
    print(String(format: "card.down changes/min=%.1f flipbacks/min=%.1f", Double(downT.changes) / m, Double(downT.flipBacks) / m))
    print(String(format: "card.up changes/min=%.1f flipbacks/min=%.1f", Double(upT.changes) / m, Double(upT.flipBacks) / m))
    for r in runs { r.report() }
    print(String(format: "probe_process_cpu_pct=%.2f (3 breakdown scans + overview)", (cpuSeconds() - c0) / wall * 100))
}

MainActor.assumeIsolated { runAll() }
