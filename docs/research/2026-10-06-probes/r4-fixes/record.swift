// Records live breakdown scan RESULTS (BreakdownScanner output) for several schedules/windows,
// plus the card's 2 s CPU series at 0.5 s ticks, to JSON for offline replay of display policies.
// Usage: rec <seconds> <out.json>
import AppKit
import Foundation

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let total = Double(args.count > 1 ? args[1] : "240") ?? 240
let outPath = args.count > 2 ? args[2] : "rec.json"

struct Variant {
    let name: String
    let metric: BreakdownMetric
    let first: Double      // first rescan delay
    let window: Double
    let scanner: BreakdownScanner
    var next: Double = 0
    var n = 0
    var scans: [[String: Any]] = []
}

let foldAgents = ProcessInfo.processInfo.environment["NOFOLD"] == nil
func anchors() -> (Set<Int32>, Set<Int32>) {
    let a = attributionAnchors(NSWorkspace.shared.runningApplications.map {
        RunningAppInfo(pid: Int32($0.processIdentifier), hasBundleIdentifier: $0.bundleIdentifier != nil,
                       isBackgroundOnly: $0.activationPolicy == .prohibited,
                       isMacOSAgent: foldAgents && isMacOSAgent(path: ($0.bundleURL ?? $0.executableURL)?.path,
                                                               isRegularApp: $0.activationPolicy == .regular)) })
    return (a.apps, a.fallbacks)
}

func encode(_ r: BreakdownScanner.Result, t: Double) -> [String: Any] {
    var d: [String: Any] = ["t": t, "measuring": r.measuring]
    if let tot = r.totalCPUPercent { d["total"] = tot }
    d["apps"] = r.apps.map { a -> [String: Any] in
        ["a": a.appPID, "c": a.cpuPercent, "m": Double(a.memoryBytes), "w": a.watts,
         "p": a.processes.map { [Double($0.pid), $0.cpuPercent, Double($0.memoryBytes), $0.watts, Double($0.startTime)] }]
    }
    return d
}

var variants: [Variant] = [
    Variant(name: "cpuB8", metric: .cpu, first: 2.0, window: 8, scanner: BreakdownScanner(windowSeconds: 8)),
    Variant(name: "cpuB8slow", metric: .cpu, first: 2.0, window: 8, scanner: BreakdownScanner(windowSeconds: 8, fastAttack: false)),
    Variant(name: "energyB16", metric: .energy, first: 2.0, window: 16, scanner: BreakdownScanner(windowSeconds: 16)),
    Variant(name: "energyB16slow", metric: .energy, first: 2.0, window: 16, scanner: BreakdownScanner(windowSeconds: 16, fastAttack: false)),
    Variant(name: "memB", metric: .memory, first: 2.0, window: 0, scanner: BreakdownScanner()),
]
// A one-core burst (`yes`) from burstAt for 16 s, recorded with its pid.
let burstAt = Double(ProcessInfo.processInfo.environment["BURST_AT"] ?? "100") ?? 100
var burst: Process?
var burstInfo: [String: Any] = [:]

struct Snap { let time: Date; let cpu: CPUTicks }
var snaps: [Snap] = []
var card: [[Double]] = []
let start = Date()
var nextTick = start
var cachedAnchors = anchors()
var anchorsAt = Date()
while true {
    let now = Date(), t = now.timeIntervalSince(start)
    if t >= total { break }
    if burst == nil, t >= burstAt {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        p.standardOutput = FileHandle.nullDevice
        try? p.run(); burst = p
        burstInfo = ["pid": Int(p.processIdentifier), "start": t]
    }
    if let p = burst, p.isRunning, t >= burstAt + 16 { p.terminate(); burstInfo["stop"] = t }
    if now >= nextTick {
        snaps.append(Snap(time: now, cpu: readCPUTicks()))
        let b = rateBaselineIndex(times: snaps.lazy.map { $0.time.timeIntervalSinceReferenceDate },
                                  now: now.timeIntervalSinceReferenceDate, window: rateWindowSeconds)
        if b > 0 { snaps.removeFirst(b) }
        if snaps.count > 1 { card.append([t, cpuBusyPercent(previous: snaps[0].cpu, current: snaps.last!.cpu)]) }
        nextTick = nextTick.addingTimeInterval(0.5)
    }
    for i in variants.indices where t >= variants[i].next {
        if now.timeIntervalSince(anchorsAt) > 1 { cachedAnchors = anchors(); anchorsAt = now }
        let m = variants[i].metric
        let time = Date().timeIntervalSinceReferenceDate, absT = mach_absolute_time(), ticks = readCPUTicks()
        let raw = readRawProcesses(includeEnergy: m == .energy)
        let r = variants[i].scanner.scan(raw, appPIDs: cachedAnchors.0, fallbackAppPIDs: cachedAnchors.1, metric: m,
                                         time: time, absTime: absT, cpuTicks: ticks)
        variants[i].scans.append(encode(r, t: t))
        variants[i].n += 1
        variants[i].next = variants[i].n == 1 ? variants[i].first : variants[i].next + breakdownScanInterval
        if variants[i].n == 1 { variants[i].next = variants[i].first }
    }
    let nextScan = variants.map(\.next).min() ?? t + 0.5
    let wake = min(nextTick, start.addingTimeInterval(nextScan))
    RunLoop.current.run(until: max(Date(), wake))
}
burst?.terminate()
var out: [String: Any] = ["card": card, "burst": burstInfo]
for v in variants { out[v.name] = v.scans }
let data = try JSONSerialization.data(withJSONObject: out)
try data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) \(data.count) bytes; scans: " + variants.map { "\($0.name)=\($0.n)" }.joined(separator: " "))
