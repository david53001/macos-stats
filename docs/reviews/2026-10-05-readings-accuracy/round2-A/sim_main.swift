import AppKit
import Darwin
// Replicates AppModel's open-popover schedule: 0.5 s tick (sample: CPU ticks, net, VM) +
// breakdown scan (immediately, +0.5 s, then every 1 s). Reports card %, header, rows.
setvbuf(stdout, nil, _IOLBF, 0)
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "12")!
let metricArg = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "cpu"
let metric: BreakdownMetric = metricArg == "mem" ? .memory : .cpu
struct Snap { let time: Date; let cpu: CPUTicks }
var snaps: [Snap] = []
var lastTickRaw: CPUTicks?
var staleTicks = 0, tickCalls = 0, staleScan = 0, scanCalls = 0, zeroCard = 0
var cards: [Double] = []
func sample() {
    let now = Date()
    let t = readCPUTicks(); tickCalls += 1
    if let l = lastTickRaw, l == t { staleTicks += 1 }
    lastTickRaw = t
    _ = readNetCounters()
    snaps.append(Snap(time: now, cpu: t))
    let base = rateBaselineIndex(times: snaps.lazy.map { $0.time.timeIntervalSinceReferenceDate }, now: now.timeIntervalSinceReferenceDate, window: rateWindowSeconds)
    if base > 0 { snaps.removeFirst(base) }
    _ = memorySample(raw: readVMRaw(), totalBytes: ProcessInfo.processInfo.physicalMemory, pressureLevel: readMemoryPressureLevel())
    guard snaps.count > 1 else { return }
    let cpu = cpuBusyPercent(previous: snaps[0].cpu, current: snaps.last!.cpu)
    if cpu == 0 || cpu >= 99 { zeroCard += 1; print("  ODD card \(cpu): base=\(snaps[0].cpu) cur=\(snaps.last!.cpu)") }
    cards.append(cpu)
    print(String(format: "  tick card=%.1f%% window=%.2fs", cpu, now.timeIntervalSince(snaps[0].time)))
}
let scanner = BreakdownScanner()
var hasID: [Int32: Bool] = [:]
var lastScanTicks: CPUTicks?
func scan() {
    let time = Date().timeIntervalSinceReferenceDate
    let absTime = mach_absolute_time()
    let ticks = readCPUTicks(); scanCalls += 1
    if let l = lastTickRaw, l == ticks { staleScan += 1 }
    if let l = lastScanTicks, l == ticks { print("  scan ticks identical to previous scan") }
    let raw = readRawProcesses()
    var h: [Int32: Bool] = [:]
    let a = attributionAnchors(NSWorkspace.shared.runningApplications.map { app in
        let pid = Int32(app.processIdentifier); let id = hasID[pid] ?? (app.bundleIdentifier != nil); h[pid] = id
        return RunningAppInfo(pid: pid, hasBundleIdentifier: id, isBackgroundOnly: app.activationPolicy == .prohibited)
    })
    hasID = h
    let r = scanner.scan(raw, appPIDs: a.apps, fallbackAppPIDs: a.fallbacks, metric: metric, time: time, absTime: absTime, cpuTicks: ticks,
                         memoryInUseBytes: metric == .memory ? memoryInUseAtFullSize(readVMRaw()) : nil)
    let users = r.apps.filter { $0.appPID != BreakdownGroup.system }.reduce(0.0) { $0 + $1.cpuPercent }
    let sys = r.apps.first { $0.appPID == BreakdownGroup.system }?.cpuPercent ?? -1
    let tickWin = lastScanTicks.map { Double(ticks.total &- $0.total) / 800 } ?? 0
    lastScanTicks = ticks
    print(String(format: "SCAN header=%.1f%% userRows=%.1f%% system=%.1f%% tickWindow≈%.2fs", r.totalCPUPercent ?? -1, users, sys, tickWin))
}
// schedule like AppModel
func tick() { sample(); RunLoop.main.add(Timer(timeInterval: 0.5, repeats: false) { _ in tick() }.with(0.05), forMode: .common) }
extension Timer { func with(_ tol: TimeInterval) -> Timer { tolerance = tol; return self } }
let burst = CommandLine.arguments.contains("burst")
sample(); if !burst { usleep(1_000_000) }; tick()
RunLoop.main.add(Timer(timeInterval: burst ? 0.01 : 2.3, repeats: false) { _ in
scan()
RunLoop.main.add(Timer(timeInterval: 0.5, repeats: false) { _ in
    scan()
    RunLoop.main.add(Timer(timeInterval: 1.0, repeats: true) { _ in scan() }.with(0.1), forMode: .common)
}.with(0.03), forMode: .common)
}, forMode: .common)
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
print("tickCalls=\(tickCalls) staleTicks=\(staleTicks) scanCalls=\(scanCalls) staleScan(==last tick)=\(staleScan) zeroCard=\(zeroCard)")
