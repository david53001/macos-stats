import AppKit
import Darwin

// Replicates AppModel.procScanTick + BreakdownView formatting for the CPU (or memory) breakdown.
let args = CommandLine.arguments
let metric: BreakdownMetric = args.count > 1 ? (args[1] == "mem" ? .memory : args[1] == "energy" ? .energy : .cpu) : .cpu
let scans = args.count > 2 ? Int(args[2])! : 6
let showChildren = Int(ProcessInfo.processInfo.environment["KIDS"] ?? "6")!
let cores = ProcessInfo.processInfo.activeProcessorCount
let scanner = BreakdownScanner()
func name(_ appPID: Int32) -> String {
    switch appPID {
    case BreakdownGroup.otherProcesses: return "Other processes"
    case BreakdownGroup.system: return "System"
    default: return NSRunningApplication(processIdentifier: appPID)?.localizedName ?? "PID \(appPID)"
    }
}
func fmt(_ a: Double, _ m: UInt64) -> String {
    metric == .cpu ? (a < 9.95 ? String(format: "%.1f%%", a) : String(format: "%.0f%%", a))
                   : { let mb = Double(m) / 1_048_576; return mb >= 1024 ? String(format: "%.1f GB", mb/1024) : String(format: "%.0f MB", mb) }()
}
var scanCost: [Double] = []
for i in 0..<scans {
    let t0 = DispatchTime.now().uptimeNanoseconds
    let time = Date().timeIntervalSinceReferenceDate
    let absTime = mach_absolute_time()
    let ticks = readCPUTicks()
    let raw = readRawProcesses(includeEnergy: metric == .energy)
    let appPIDs = Set(NSWorkspace.shared.runningApplications.compactMap { app -> Int32? in
        app.processIdentifier > 0 ? Int32(app.processIdentifier) : nil })
    let r = scanner.scan(raw, appPIDs: appPIDs, metric: metric, time: time, absTime: absTime, cpuTicks: ticks)
    let t1 = DispatchTime.now().uptimeNanoseconds
    scanCost.append(Double(t1 - t0) / 1e6)
    let wall = Date()
    let df = DateFormatter(); df.dateFormat = "HH:mm:ss.SSS"
    print("=== scan \(i) at \(df.string(from: wall)) procs=\(raw.count) cost=\(String(format: "%.2f", scanCost.last!)) ms measuring=\(r.measuring) header=\(r.totalCPUPercent.map { String(format: "%.1f%%", $0) } ?? "-")")
    if !r.measuring {
        var sum = 0.0; var memSum: UInt64 = 0
        for app in r.apps { sum += app.cpuPercent; memSum += app.memoryBytes }
        let wsum = r.apps.reduce(0.0) { $0 + $1.watts }
        print(String(format: "rows sum cpu=%.2f%%  mem=%.0f MB  watts=%.3f W rows=%d  gauge SystemLoad=%@ W", sum, Double(memSum)/1_048_576, wsum, r.apps.count, SmartBatteryReader().read()?.instantWatts.map { String(format: "%.2f", $0) } ?? "-"))
        if metric == .energy { for app in r.apps.prefix(8) { print("  E \(name(app.appPID)) \(String(format: "%.2f W", app.watts))") } }
        for app in r.apps.prefix(Int(ProcessInfo.processInfo.environment["ROWS"] ?? "14")!) {
            print("  \(name(app.appPID).padding(toLength: 26, withPad: " ", startingAt: 0)) \(fmt(app.cpuPercent, app.memoryBytes).padding(toLength: 8, withPad: " ", startingAt: 0)) (\(String(format: "%.1f", app.cpuPercent * Double(cores)))% core) n=\(app.processes.count)")
            if app.processes.count > 1 && (app.cpuPercent > 0.5 || metric == .memory) {
                for p in app.processes.prefix(showChildren) {
                    print("      - \((processName(p.pid) ?? "?").padding(toLength: 30, withPad: " ", startingAt: 0)) \(p.pid) \(fmt(p.cpuPercent, p.memoryBytes))")
                }
            }
        }
    }
    if i < scans - 1 { RunLoop.main.run(until: Date().addingTimeInterval(i == 0 ? 0.5 : 1.0)) }
}
print("scan cost ms: \(scanCost.map { String(format: "%.2f", $0) }.joined(separator: " "))")
