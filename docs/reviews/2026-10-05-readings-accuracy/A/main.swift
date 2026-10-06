import Foundation
import AppKit
import Darwin

// Review harness: replicates AppModel's glue (MacStatsApp.swift) around the real MacStatsCore code.
setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "cpu"
let cores = ProcessInfo.processInfo.activeProcessorCount

func appPIDs() -> Set<Int32> {   // MacStatsApp.swift:407
    Set(NSWorkspace.shared.runningApplications.compactMap { app -> Int32? in
        app.processIdentifier > 0 ? Int32(app.processIdentifier) : nil
    })
}
func appName(_ pid: Int32) -> String {   // BreakdownView.swift:420-428
    switch pid {
    case BreakdownGroup.otherProcesses: return "Other processes"
    case BreakdownGroup.system: return "System"
    default: return NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName ?? "PID \(pid)"
    }
}
func fmtCPU(_ v: Double) -> String { v < 9.95 ? String(format: "%.1f%%", v) : String(format: "%.0f%%", v) }   // BreakdownView.swift:248
func ts() -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date()) }

switch mode {
case "cpu", "energy":
    // args: cpu <scans> <childrenToShow> <dumpfile?>
    let metric: BreakdownMetric = mode == "cpu" ? .cpu : .energy
    let scans = args.count > 2 ? Int(args[2])! : 6
    let showKids = args.count > 3 ? Int(args[3])! : 5
    let dump = args.count > 4 ? args[4] : nil
    let scanner = BreakdownScanner()
    var lastRaw: [RawProcess] = []
    var lastResult: BreakdownScanner.Result?
    for i in 0..<scans {
        if i == 1 { Thread.sleep(forTimeInterval: breakdownFirstRescanDelay) }
        else if i > 1 { Thread.sleep(forTimeInterval: breakdownScanInterval) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        // procScanTick order (MacStatsApp.swift:400-413)
        let time = Date().timeIntervalSinceReferenceDate
        let absTime = mach_absolute_time()
        let ticks = readCPUTicks()
        let raw = readRawProcesses(includeEnergy: metric == .energy)
        let pids = appPIDs()
        let r = scanner.scan(raw, appPIDs: pids, metric: metric, time: time, absTime: absTime, cpuTicks: ticks)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        lastRaw = raw; lastResult = r
        if r.measuring { print("[\(ts())] scan \(i): measuring (\(raw.count) procs, \(String(format: "%.1f", ms)) ms)"); continue }
        let sum = r.apps.reduce(0) { $0 + (metric == .cpu ? $1.cpuPercent : $1.watts) }
        print("[\(ts())] scan \(i): header \(r.totalCPUPercent.map { String(format: "%.1f%%", $0) } ?? "-") rows-sum \(String(format: "%.2f", sum)) procs \(raw.count) scan \(String(format: "%.1f", ms)) ms")
        for a in r.apps.prefix(12) {
            let v = metric == .cpu ? fmtCPU(a.cpuPercent) : String(format: "%.2f W", a.watts)
            print("   \(appName(a.appPID).padding(toLength: 26, withPad: " ", startingAt: 0)) \(v.padding(toLength: 8, withPad: " ", startingAt: 0)) n=\(a.processes.count)")
            if a.processes.count > 1, (metric == .cpu ? a.cpuPercent >= 1 : a.watts >= 0.1) {
                for p in a.processes.prefix(showKids) {
                    let pv = metric == .cpu ? fmtCPU(p.cpuPercent) + String(format: " (%.0f%% core)", p.cpuPercent * Double(cores)) : String(format: "%.2f W", p.watts)
                    print("       - \((processName(p.pid) ?? "?").padding(toLength: 30, withPad: " ", startingAt: 0)) \(p.pid) \(pv)")
                }
            }
        }
    }
    if let dump, let r = lastResult {
        var out = "pid\tppid\towner\townerName\tresp\tcpuMachinePct\tfootprintMB\tname\n"
        let byPid = Dictionary(lastRaw.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        for a in r.apps { for p in a.processes {
            out += "\(p.pid)\t\(byPid[p.pid]?.ppid ?? 0)\t\(a.appPID)\t\(appName(a.appPID))\t\(responsiblePID(for: p.pid) ?? 0)\t\(String(format: "%.3f", p.cpuPercent))\t\(String(format: "%.1f", Double(p.memoryBytes) / 1048576))\t\(processName(p.pid) ?? "?")\n"
        } }
        try! out.write(toFile: dump, atomically: true, encoding: .utf8)
    }

case "mem":
    // Memory card (MacStatsApp.swift:147) + memory breakdown (one scan, metric .memory)
    let total = ProcessInfo.processInfo.physicalMemory
    let raw = readVMRaw()
    let m = memorySample(raw: raw, totalBytes: total, pressureLevel: readMemoryPressureLevel())
    let gib = { (b: UInt64) in String(format: "%.2f", Double(b) / 1_073_741_824) }
    print("vm pages: free \(raw.free) active \(raw.active) inactive \(raw.inactive) wired \(raw.wired) compressed \(raw.compressed) internal \(raw.internal) purgeable \(raw.purgeable) pageSize \(raw.pageSize)")
    print("card: \(gib(m.usedBytes)) / \(gib(m.totalBytes)) GB  pressure \(m.pressure)  appMem \(gib((raw.internal - raw.purgeable) * raw.pageSize)) wired \(gib(raw.wired * raw.pageSize)) compressed \(gib(raw.compressed * raw.pageSize))")
    let procs = readRawProcesses()
    let scanner = BreakdownScanner()
    let r = scanner.scan(procs, appPIDs: appPIDs(), metric: .memory, time: Date().timeIntervalSinceReferenceDate,
                         absTime: mach_absolute_time(), cpuTicks: readCPUTicks())
    let rowsSum = r.apps.reduce(UInt64(0)) { $0 + $1.memoryBytes }
    print("rows: \(r.apps.count) sum \(gib(rowsSum)) GB over \(procs.count) user processes")
    for a in r.apps.prefix(15) {
        print("   \(appName(a.appPID).padding(toLength: 26, withPad: " ", startingAt: 0)) \(String(format: "%7.0f MB", Double(a.memoryBytes) / 1048576)) n=\(a.processes.count)")
    }
    if args.count > 2 {
        var out = "pid\townerName\tfootprintBytes\tname\n"
        for a in r.apps { for p in a.processes { out += "\(p.pid)\t\(appName(a.appPID))\t\(p.memoryBytes)\t\(processName(p.pid) ?? "?")\n" } }
        try! out.write(toFile: args[2], atomically: true, encoding: .utf8)
    }

case "batt":
    guard let b = readBattery() else { print("no battery"); break }
    let reader = SmartBatteryReader()
    guard let t = reader.read() else { print("no gauge"); break }
    print("IOPS: percent \(b.percent) state \(b.state) macOS timeToEmpty \(b.timeToEmptyMinutes.map(String.init) ?? "nil") timeToFull \(b.timeToFullMinutes.map(String.init) ?? "nil")")
    print("gauge: update \(t.updateTime) V \(t.voltageMV ?? -1) mA \(t.amperageMA ?? -1) rawCur \(t.currentMAh ?? -1) rawMax \(t.rawMaxMAh ?? -1) nominal \(t.nominalMAh ?? -1) design \(t.designMAh ?? -1) cycles \(t.cycleCount ?? -1) tempC \(t.temperatureC ?? -1) adapterW \(t.adapterWatts ?? -1) sysLoad \(t.systemLoadMW ?? -1) acc \(t.accumulatedSystemLoad ?? 0) cnt \(t.systemLoadCount ?? 0)")
    print("derived: remainingWh \(String(format: "%.2f", t.remainingWh ?? -1)) instantW \(String(format: "%.2f", t.instantWatts ?? -1)) health \(t.healthPercent ?? -1)%")
    // Time-left from the app's persisted typical, if any (read-only)
    let d = UserDefaults(suiteName: "com.macstats.MacStats")
    let tw = d?.object(forKey: "batteryDrainTypicalWatts") as? Double
    let tsec = d?.double(forKey: "batteryDrainTypicalSeconds") ?? 0
    print("persisted typical: \(tw.map { String(format: "%.2f W", $0) } ?? "nil") over \(Int(tsec)) s")

case "est":
    // Replays a gauge log (lines: unix updateTime acc cnt rawCur voltage) through the estimator.
    // args: est <file> <typicalW or -> <typicalSec>
    let lines = try! String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n")
    let tw = args[3] == "-" ? nil : Double(args[3])
    var est = BatteryEstimator(typicalWatts: tw, typicalSeconds: Double(args[4]) ?? 0)
    var last: BatteryTelemetry?
    for l in lines {
        let f = l.split(separator: " ").map { String($0) }
        let t = BatteryTelemetry(updateTime: Int(f[0])!, voltageMV: Int(f[4]), amperageMA: Int(f[5]), currentMAh: Int(f[3]),
                                 systemLoadMW: Int(f[6]), accumulatedSystemLoad: UInt64(f[1]), systemLoadCount: UInt64(f[2]))
        if t.updateTime == last?.updateTime { continue }
        if let p = last, let s = gaugeInterval(from: p, to: t), let w = averageWatts(from: p, to: t) { est.ingest(watts: w, seconds: s) }
        last = t
        let mins = est.minutesLeft(remainingWh: t.remainingWh ?? 0, macOSMinutes: Int(f[7]))
        print("\(f[0]) avgW(session) \(String(format: "%.2f", est.sessionAverageWatts ?? -1)) expW \(String(format: "%.2f", est.expectedWatts ?? -1)) remWh \(String(format: "%.2f", t.remainingWh ?? -1)) left \(mins.map(String.init) ?? "nil") min macOS \(f[7])")
    }

case "timing":
    // Cost of one breakdown scan (steady state) and of the idle sample path.
    let scanner = BreakdownScanner()
    var times: [Double] = []
    for i in 0..<12 {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let raw = readRawProcesses()
        _ = scanner.scan(raw, appPIDs: appPIDs(), metric: .cpu, time: Date().timeIntervalSinceReferenceDate,
                         absTime: mach_absolute_time(), cpuTicks: readCPUTicks())
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        if i > 1 { times.append(ms) }
        Thread.sleep(forTimeInterval: 0.2)
    }
    times.sort()
    print("breakdown scan ms: min \(String(format: "%.2f", times.first!)) median \(String(format: "%.2f", times[times.count / 2])) max \(String(format: "%.2f", times.last!))")
    var t0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<100 { _ = readCPUTicks(); _ = readNetCounters(); _ = memorySample(raw: readVMRaw(), totalBytes: 1, pressureLevel: readMemoryPressureLevel()) }
    print("idle sample (cpu+net+vm) us: \(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e3 / 100))")
    t0 = DispatchTime.now().uptimeNanoseconds
    let r = SmartBatteryReader()
    for _ in 0..<100 { _ = readBattery(); _ = r.read() }
    print("battery read (IOPS + gauge) us: \(String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e3 / 100))")

case "net":
    var prev = readNetCounters(); var pt = Date()
    for _ in 0..<(args.count > 2 ? Int(args[2])! : 5) {
        Thread.sleep(forTimeInterval: 1)
        let c = readNetCounters(); let now = Date()
        let s = networkThroughput(previous: prev, current: c, secondsElapsed: now.timeIntervalSince(pt))
        print("[\(ts())] rx \(c.rxBytes) tx \(c.txBytes) down \(String(format: "%.0f", s.downBytesPerSec)) B/s up \(String(format: "%.0f", s.upBytesPerSec)) B/s")
        prev = c; pt = now
    }

case "ticks":
    let a = readCPUTicks(); let t0 = Date()
    Thread.sleep(forTimeInterval: 2)
    let b = readCPUTicks()
    print("ticks now user \(b.user) sys \(b.system) idle \(b.idle) nice \(b.nice); ticks/s \(Double(b.total - a.total) / Date().timeIntervalSince(t0))")

default: print("unknown mode")
}
