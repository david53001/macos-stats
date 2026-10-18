import AppKit
import Darwin
// Faithful copy of the app's BreakdownScanSession (MacStatsApp.swift:519-547).
final class Session {
    let scanner = BreakdownScanner()
    var appHasBundleID: [Int32: Bool] = [:]
    func scan(metric: BreakdownMetric) -> (BreakdownScanner.Result, [RawProcess]) {
        var hasBundleID: [Int32: Bool] = [:]
        let anchors = attributionAnchors(NSWorkspace.shared.runningApplications.map { app in
            let pid = Int32(app.processIdentifier)
            let hasID = appHasBundleID[pid] ?? (app.bundleIdentifier != nil)
            hasBundleID[pid] = hasID
            return RunningAppInfo(pid: pid, hasBundleIdentifier: hasID, isBackgroundOnly: app.activationPolicy == .prohibited)
        })
        appHasBundleID = hasBundleID
        let time = Date().timeIntervalSinceReferenceDate
        let absTime = mach_absolute_time()
        let ticks = readCPUTicks()
        let raw = readRawProcesses(includeEnergy: metric == .energy)
        return (scanner.scan(raw, appPIDs: anchors.apps, fallbackAppPIDs: anchors.fallbacks, metric: metric, time: time, absTime: absTime, cpuTicks: ticks), raw)
    }
}
let args = CommandLine.arguments
let metric: BreakdownMetric = args.count > 1 && args[1] == "mem" ? .memory : (args.count > 1 && args[1] == "energy" ? .energy : .cpu)
let scans = args.count > 2 ? Int(args[2])! : 10
let expand = args.count > 3 ? args[3] : ""
let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
func name(_ app: Int32) -> String {
    switch app { case -1: return "Other processes"; case -2: return "System"; default: return NSRunningApplication(processIdentifier: app)?.localizedName ?? "PID \(app)" }
}
let s = Session()
var costs: [Double] = []
let df = DateFormatter(); df.dateFormat = "HH:mm:ss.SSS"
for k in 0..<scans {
    let t0 = DispatchTime.now().uptimeNanoseconds
    let (r, raw) = s.scan(metric: metric)
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    costs.append(ms)
    let sum = r.apps.reduce(0.0) { $0 + $1.value(for: metric) }
    var out = "[\(df.string(from: Date()))] scan \(k) \(String(format: "%.1f", ms)) ms procs \(raw.count) "
    switch metric {
    case .cpu: out += "header \(r.totalCPUPercent.map { String(format: "%.1f%%", $0) } ?? "measuring") rows-sum \(String(format: "%.1f%%", sum))"
    case .memory: out += "rows-sum \(String(format: "%.2f GiB", sum / 1073741824))"
    case .energy: out += "rows-sum \(String(format: "%.2f W", sum))"
    }
    print(out)
    if !r.measuring {
        for a in r.apps.prefix(metric == .memory ? 14 : 9) {
            let v: String
            switch metric { case .cpu: v = String(format: "%5.1f%% (%4.0f%% 1-core)", a.cpuPercent, a.cpuPercent * cores)
                case .memory: v = String(format: "%7.0f MiB", Double(a.memoryBytes) / 1048576)
                case .energy: v = String(format: "%5.2f W", a.watts) }
            print("   \(name(a.appPID).padding(toLength: 26, withPad: " ", startingAt: 0)) \(v)  n=\(a.processes.count)")
            if !expand.isEmpty, name(a.appPID).contains(expand) || (expand == "ALL") {
                for p in a.processes.prefix(6) {
                    let pn = p.pid == BreakdownGroup.exitedProcesses ? "Exited processes" : (processName(p.pid) ?? "?")
                    print(String(format: "        %-28@ %6d  %5.1f%% (%4.0f%% 1-core) %7.0f MiB", pn as NSString, p.pid, p.cpuPercent, p.cpuPercent * cores, Double(p.memoryBytes)/1048576))
                }
            }
        }
    }
    if k < scans - 1 { Thread.sleep(forTimeInterval: k == 0 ? 0.5 : 1.0) }
}
costs.removeFirst()
print(String(format: "scan cost ms: mean %.2f max %.2f", costs.reduce(0,+)/Double(max(1,costs.count)), costs.max() ?? 0))
