import AppKit
import Darwin


// Replicates AppModel.procScanTick (MacStatsApp.swift:444-470) and BreakdownView naming.
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "cpu"
let scans = args.count > 2 ? Int(args[2])! : 6
let verbose = args.contains("-v")

func name(_ appPID: Int32) -> String {
    switch appPID {
    case BreakdownGroup.otherProcesses: return "Other processes"
    case BreakdownGroup.system: return mode == "mem" ? "System & other" : "System"
    default: return NSRunningApplication(processIdentifier: appPID)?.localizedName ?? "PID \(appPID)"
    }
}
let metric: BreakdownMetric = mode == "mem" ? .memory : mode == "energy" ? .energy : .cpu
let scanner = BreakdownScanner()
var appHasBundleID: [Int32: Bool] = [:]
var clock = ContinuousClock()
var costs: [Duration] = []
func scanOnce(_ i: Int) {
    let start = clock.now
    let time = Date().timeIntervalSinceReferenceDate
    let absTime = mach_absolute_time()
    let ticks = readCPUTicks()
    let raw = readRawProcesses(includeEnergy: metric == .energy)
    var hasBundleID: [Int32: Bool] = [:]
    let anchors = attributionAnchors(NSWorkspace.shared.runningApplications.map { app in
        let pid = Int32(app.processIdentifier)
        let hasID = appHasBundleID[pid] ?? (app.bundleIdentifier != nil)
        hasBundleID[pid] = hasID
        return RunningAppInfo(pid: pid, hasBundleIdentifier: hasID, isBackgroundOnly: app.activationPolicy == .prohibited)
    })
    appHasBundleID = hasBundleID
    let vm = readVMRaw()
    let result = scanner.scan(raw, appPIDs: anchors.apps, fallbackAppPIDs: anchors.fallbacks, metric: metric,
                              time: time, absTime: absTime, cpuTicks: ticks,
                              memoryInUseBytes: metric == .memory ? memoryInUseAtFullSize(vm) : nil)
    costs.append(clock.now - start)
    let wall = Date()
    let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss.SSS"
    print("=== scan \(i) at \(fmt.string(from: wall)) procs=\(raw.count) measuring=\(result.measuring) header=\(result.totalCPUPercent.map { String(format: "%.1f%%", $0) } ?? "-")")
    if metric == .memory {
        let ms = memorySample(raw: vm, totalBytes: ProcessInfo.processInfo.physicalMemory, pressureLevel: readMemoryPressureLevel())
        print(String(format: "Memory Used (card/header) = %.3f GiB; inUseAtFullSize = %.3f GiB; pressure=%@", Double(ms.usedBytes)/1073741824, Double(memoryInUseAtFullSize(vm))/1073741824, "\(ms.pressure)"))
        print("VMRaw: \(vm)")
    }
    if result.measuring { return }
    var sum = 0.0
    for app in result.apps {
        sum += app.value(for: metric)
        let v: String
        switch metric {
        case .cpu: v = String(format: "%6.2f%% (=%6.1f%% of 1 core)", app.cpuPercent, app.cpuPercent * 8)
        case .memory: v = String(format: "%8.1f MiB", Double(app.memoryBytes)/1048576)
        case .energy: v = String(format: "%6.3f W", app.watts)
        }
        if app.value(for: metric) > 0.004 || metric == .memory { print("  \(v)  \(name(app.appPID)) [\(app.appPID)] n=\(app.processes.count)") }
        if verbose || app.appPID < 0 {
            for p in app.processes.prefix(verbose ? 400 : 8) where p.value(for: metric) > (metric == .memory ? 50*1048576 : 0.05) {
                let pv: String
                switch metric {
                case .cpu: pv = String(format: "%6.2f%%", p.cpuPercent)
                case .memory: pv = String(format: "%8.1f MiB", Double(p.memoryBytes)/1048576)
                case .energy: pv = String(format: "%6.3f W", p.watts)
                }
                print("        \(pv)  \(processName(p.pid) ?? "?") [\(p.pid)]")
            }
        }
    }
    switch metric {
    case .cpu: print(String(format: "  rows sum = %.2f%%", sum))
    case .memory: print(String(format: "  rows sum = %.3f GiB", sum/1073741824))
    case .energy: print(String(format: "  rows sum = %.3f W", sum))
    }
}
scanOnce(0)
usleep(500_000)
for i in 1..<scans { scanOnce(i); if i < scans-1 { usleep(1_000_000) } }
let ms = costs.map { Double($0.components.attoseconds)/1e15 + Double($0.components.seconds)*1000 }
print("scan cost ms: " + ms.map { String(format: "%.2f", $0) }.joined(separator: " "))
