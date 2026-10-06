// Headless stability probe for MacStats (see README.md next to this file).
//
// Runs the REAL MacStatsCore pipeline with no window: the breakdown scan path of
// `BreakdownScanSession.scan` (Sources/MacStatsApp/MacStatsApp.swift) into a real `MetricsStore`
// (`beginBreakdown(.cpu)` + `setBreakdown`) at the app's cadence (first rescan after
// `breakdownFirstRescanDelay`, then every `breakdownScanInterval`), and the overview path
// (snapshots + `rateBaselineIndex(window: rateWindowSeconds)` + `store.record`) every 0.5 s.
// It counts how often what the user would read changes, and prints one key=value per line.
//
// Compiled together with Sources/MacStatsCore/*.swift (minus AppleSensorReader.swift) by run.sh.
// `-D BASELINE` builds it against a checkout from before the stability work (1ed61cf), where the
// shown values are the raw ones and there is no freeze, pin or hold.
//
// Usage: probe [seconds=90] [app=Code]
import AppKit
import Darwin

let args = CommandLine.arguments
let runSeconds = args.count > 1 ? Double(args[1]) ?? 90 : 90
let targetName = args.count > 2 ? args[2] : "Code"
let cores = Double(ProcessInfo.processInfo.activeProcessorCount)

#if BASELINE
/// `formattedValue` as it was in BreakdownView.swift at 1ed61cf.
func breakdownValueText(_ metric: BreakdownMetric, _ value: Double) -> String {
    switch metric {
    case .cpu: return value < 9.95 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
    case .memory:
        let mb = value / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    case .energy: return String(format: "%.2f W", value)
    }
}
#endif

/// A copy of the app's `BreakdownScanSession` (same anchors, clocks and order of reads).
final class ScanSession {
    let scanner = BreakdownScanner()
    var appHasBundleID: [Int32: Bool] = [:]
    /// Milliseconds per part of each scan: running-apps list, process read, `BreakdownScanner.scan`.
    var appsMs: [Double] = [], readMs: [Double] = [], scannerMs: [Double] = []

    func scan(metric: BreakdownMetric) -> BreakdownScanner.Result {
        let t0 = DispatchTime.now().uptimeNanoseconds
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
        let t1 = DispatchTime.now().uptimeNanoseconds
        let raw = readRawProcesses(includeEnergy: metric == .energy)
        let t2 = DispatchTime.now().uptimeNanoseconds
        let result = scanner.scan(raw, appPIDs: anchors.apps, fallbackAppPIDs: anchors.fallbacks,
                                  metric: metric, time: time, absTime: absTime, cpuTicks: ticks)
        let t3 = DispatchTime.now().uptimeNanoseconds
        appsMs.append(Double(t1 - t0) / 1e6)
        readMs.append(Double(t2 - t1) / 1e6)
        scannerMs.append(Double(t3 - t2) / 1e6)
        return result
    }
}

struct Snapshot {
    let time: Date
    let cpu: CPUTicks
    let net: NetCounters
}

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return s(usage.ru_utime) + s(usage.ru_stime)
}

@MainActor func runProbe() {
    let store = MetricsStore()
    let session = ScanSession()
    let totalMemory = ProcessInfo.processInfo.physicalMemory
    var snapshots: [Snapshot] = []

    // The target app: the one named on the command line, else the app with the most processes.
    var targetPID = NSWorkspace.shared.runningApplications
        .first { $0.localizedName == targetName }.map { Int32($0.processIdentifier) }

    // Overview counters.
    var lastCardTexts: (cpu: String, down: String, mem: String)?
    var cardChanges = (cpu: 0, down: 0, mem: 0)
    var wholeMacSum = 0.0, wholeMacCount = 0

    func tick(_ now: Date) {
        snapshots.append(Snapshot(time: now, cpu: readCPUTicks(), net: readNetCounters()))
        let base = rateBaselineIndex(times: snapshots.lazy.map { $0.time.timeIntervalSinceReferenceDate },
                                     now: now.timeIntervalSinceReferenceDate, window: rateWindowSeconds)
        if base > 0 { snapshots.removeFirst(base) }
        guard snapshots.count > 1, let current = snapshots.last else { return }
        let baseline = snapshots[0]
        let cpu = cpuBusyPercent(previous: baseline.cpu, current: current.cpu)
        let net = networkThroughput(previous: baseline.net, current: current.net,
                                    secondsElapsed: now.timeIntervalSince(baseline.time))
        let mem = memorySample(raw: readVMRaw(), totalBytes: totalMemory, pressureLevel: readMemoryPressureLevel())
        store.record(cpuPercent: cpu, memory: mem, network: net, time: now.timeIntervalSinceReferenceDate)
        wholeMacSum += cpu
        wholeMacCount += 1
        #if BASELINE
        let cardCPU = store.cpuPercent, cardNet = store.network, cardMem = store.memory
        #else
        let cardCPU = store.cardCPUPercent, cardNet = store.cardNetwork, cardMem = store.cardMemory
        #endif
        let texts = (cpu: "\(Int(cardCPU.rounded()))%",
                     down: formattedRate(bytesPerSecond: cardNet?.downBytesPerSec ?? 0),
                     mem: String(format: "%.1f", Double(cardMem?.usedBytes ?? 0) / 1_073_741_824))
        if let last = lastCardTexts {
            if last.cpu != texts.cpu { cardChanges.cpu += 1 }
            if last.down != texts.down { cardChanges.down += 1 }
            if last.mem != texts.mem { cardChanges.mem += 1 }
        }
        lastCardTexts = texts
    }

    func shown(_ app: AppUsage) -> Double {
        #if BASELINE
        return app.cpuPercent
        #else
        return store.shownValue(app: app.appPID) ?? app.cpuPercent
        #endif
    }

    // Breakdown counters. Per-minute figures cover the scans outside the frozen window.
    var lastTop8: [Int32]?
    var lastText: [Int32: String] = [:]
    var lastChildSet: Set<Int32>?
    var lastTargetIndex: Int?
    var counts = (order: 0, slots: 0, text: 0, targetMoves: 0, childSets: 0, frozenSlots: 0)
    var countedSeconds = 0.0
    var scanMs: [Double] = [], storeMs: [Double] = []
    var maxGap = 0.0
    var lastScanTime: Date?
    let freezeFrom = runSeconds / 2 - 10, freezeTo = runSeconds / 2 + 10
    #if !BASELINE
    var freezing = false
    #endif

    func scan(_ now: Date, elapsed: Double) {
        #if !BASELINE
        let wantFreeze = elapsed >= freezeFrom && elapsed < freezeTo
        if wantFreeze != freezing {
            freezing = wantFreeze
            store.setBreakdownPointerInside(wantFreeze, time: now.timeIntervalSinceReferenceDate)
        }
        #endif
        let t0 = DispatchTime.now().uptimeNanoseconds
        let result = session.scan(metric: .cpu)
        scanMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        let t1 = DispatchTime.now().uptimeNanoseconds
        #if BASELINE
        store.setBreakdown(result.apps, measuring: result.measuring, totalCPU: result.totalCPUPercent)
        #else
        store.setBreakdown(result.apps, measuring: result.measuring, totalCPU: result.totalCPUPercent,
                           time: now.timeIntervalSinceReferenceDate)
        #endif
        storeMs.append(Double(DispatchTime.now().uptimeNanoseconds - t1) / 1e6)
        let interval = lastScanTime.map { now.timeIntervalSince($0) } ?? 0
        lastScanTime = now
        guard !result.measuring else { return }

        let rows = store.breakdown
        if targetPID == nil || !rows.contains(where: { $0.appPID == targetPID }) {
            targetPID = rows.filter(\.isApp).max { $0.processes.count < $1.processes.count }?.appPID
        }
        // Rounds 1-2 pinned the target here (`setBreakdownPinnedApp`, as if expanded). Review round 2
        // removed the pin: the expanded app re-ranks like any row, and only the freeze holds it still.

        let top8 = Array(rows.prefix(8).map(\.appPID))
        let present = Set(rows.map(\.appPID))
        // The 20 s pointer window (frozen in the current build; the same span in the baseline) and
        // the scan right after it (the unfreeze) are counted apart from the per-minute figures.
        let inPointerWindow = elapsed >= freezeFrom && elapsed < freezeTo
        let frozenScan = elapsed >= freezeFrom && elapsed < freezeTo + 2.5
        if let last = lastTop8 {
            var slotChanges = 0, slotChangesStillPresent = 0
            for i in 0..<min(8, max(last.count, top8.count)) {
                let old = i < last.count ? last[i] : nil, new = i < top8.count ? top8[i] : nil
                if old != new {
                    slotChanges += 1
                    if let old, present.contains(old) { slotChangesStillPresent += 1 }   // not a quit
                }
            }
            if inPointerWindow {
                counts.frozenSlots += slotChangesStillPresent
            } else if !frozenScan {
                if last != top8 { counts.order += 1 }
                counts.slots += slotChanges
                countedSeconds += interval
            }
        }
        lastTop8 = top8
        if !frozenScan {
            for app in rows.prefix(8) {
                let text = breakdownValueText(.cpu, shown(app))
                if let old = lastText[app.appPID], old != text { counts.text += 1 }
            }
            if let target = targetPID, let index = rows.firstIndex(where: { $0.appPID == target }) {
                if let last = lastTargetIndex, last != index { counts.targetMoves += 1 }
                lastTargetIndex = index
                let children = Set(rows[index].processes.prefix(5).map(\.pid))
                if let last = lastChildSet, last != children { counts.childSets += 1 }
                lastChildSet = children
            }
        }
        for app in rows { lastText[app.appPID] = breakdownValueText(.cpu, shown(app)) }

        #if BASELINE
        let header = store.breakdownTotalCPU
        #else
        let header = store.breakdownShownTotalCPU
        #endif
        if let header {
            let sum = rows.reduce(0) { $0 + shown($1) }
            maxGap = max(maxGap, abs(sum - header))
        }
        if Int(elapsed) / 10 != Int(elapsed - interval) / 10, let target = targetPID,
           let row = rows.first(where: { $0.appPID == target }) {
            let name = NSRunningApplication(processIdentifier: target)?.localizedName ?? "?"
            print(String(format: "sample t=%.0f target=%@ pid=%d row_pct_mac=%.2f one_core_pct=%.0f header=%.1f",
                         elapsed, name, target, row.cpuPercent, row.cpuPercent * cores, store.breakdownTotalCPU ?? -1))
        }
    }

    store.beginBreakdown(metric: .cpu)
    let start = Date()
    let cpuStart = cpuSeconds()
    var nextTick = start
    var nextScan = start
    var scans = 0
    while true {
        let now = Date()
        let elapsed = now.timeIntervalSince(start)
        if elapsed >= runSeconds { break }
        if now >= nextTick {
            tick(now)
            nextTick = nextTick.addingTimeInterval(0.5)
        }
        if now >= nextScan {
            scan(now, elapsed: elapsed)
            scans += 1
            nextScan = scans == 1 ? start.addingTimeInterval(breakdownFirstRescanDelay)
                                  : nextScan.addingTimeInterval(breakdownScanInterval)
        }
        RunLoop.current.run(until: min(nextTick, nextScan))
    }
    let wall = Date().timeIntervalSince(start)
    let minutes = max(countedSeconds, 1) / 60
    let wallMinutes = wall / 60
    func perMin(_ n: Int, _ m: Double) -> String { String(format: "%.1f", Double(n) / m) }
    let mean = scanMs.isEmpty ? 0 : scanMs.reduce(0, +) / Double(scanMs.count)
    #if BASELINE
    print("build=baseline")
    #else
    print("build=current")
    #endif
    print(String(format: "run_seconds=%.0f counted_breakdown_seconds=%.0f cores=%.0f", wall, countedSeconds, cores))
    print("breakdown_scan_interval_s=\(breakdownScanInterval) rate_window_s=\(rateWindowSeconds)")
    print("target_app=\(targetPID.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "none")")
    print("top8_order_changes=\(perMin(counts.order, minutes))")
    print("slot_changes=\(perMin(counts.slots, minutes))")
    print("row_text_changes=\(perMin(counts.text, minutes))")
    print("target_moves=\(perMin(counts.targetMoves, minutes))")
    print("target_child_set_changes=\(perMin(counts.childSets, minutes))")
    #if BASELINE
    print("frozen_slot_changes=\(counts.frozenSlots)   # baseline: nothing freezes; same 20 s window, total")
    #else
    print("frozen_slot_changes=\(counts.frozenSlots)   # total over the 20 s pointer-in-list window")
    #endif
    print("card_cpu_changes=\(perMin(cardChanges.cpu, wallMinutes))")
    print("card_net_down_changes=\(perMin(cardChanges.down, wallMinutes))")
    print("card_mem_changes=\(perMin(cardChanges.mem, wallMinutes))")
    print(String(format: "scan_ms_mean=%.2f scan_ms_max=%.2f scans_per_s=%.2f scan_ms_per_s=%.2f",
                 mean, scanMs.max() ?? 0, Double(scans) / wall, mean * Double(scans) / wall))
    func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
    print(String(format: "scan_parts_ms_mean apps_list=%.2f process_read=%.2f scanner=%.2f store_setBreakdown=%.2f",
                 avg(session.appsMs), avg(session.readMs), avg(session.scannerMs), avg(storeMs)))
    print(String(format: "process_cpu_pct=%.2f", (cpuSeconds() - cpuStart) / wall * 100))
    print(String(format: "max_sum_gap_pp=%.2f", maxGap))
    print(String(format: "whole_mac_cpu_mean=%.1f", wholeMacCount > 0 ? wholeMacSum / Double(wholeMacCount) : 0))
}

MainActor.assumeIsolated { runProbe() }
