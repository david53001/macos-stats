import AppKit
import Darwin
// Replicates BreakdownScanSession.scan (MacStatsApp.swift:525-546) + the CPU breakdown view's formatting.
let metricArg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "cpu"
let scans = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 6
let showTop = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 8
let metric: BreakdownMetric = metricArg == "memory" ? .memory : metricArg == "energy" ? .energy : .cpu
let scanner = BreakdownScanner()
let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
var appHasBundleID: [Int32: Bool] = [:]
func scanOnce() -> (BreakdownScanner.Result, Double) {
  let t0 = DispatchTime.now().uptimeNanoseconds
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
  let r = scanner.scan(raw, appPIDs: anchors.apps, fallbackAppPIDs: anchors.fallbacks, metric: metric, time: time, absTime: absTime, cpuTicks: ticks)
  return (r, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
}
func name(_ app: AppUsage) -> String {
  switch app.appPID {
  case BreakdownGroup.otherProcesses: return "Other processes"
  case BreakdownGroup.system: return "System"
  default: return NSRunningApplication(processIdentifier: app.appPID)?.localizedName ?? "PID \(app.appPID)"
  }
}
func pname(_ p: ProcessUsage) -> String { p.pid == BreakdownGroup.exitedProcesses ? "Exited processes" : (processName(p.pid) ?? "?") }
func fmt(_ m: BreakdownMetric, _ v: Double) -> String {
  switch m { case .cpu: return v < 9.95 ? String(format: "%.1f%%", v) : String(format: "%.0f%%", v)
  case .memory: let mb = v / 1_048_576; return mb >= 1024 ? String(format: "%.1f GB", mb/1024) : String(format: "%.0f MB", mb)
  case .energy: return String(format: "%.2f W", v) }
}
let df = DateFormatter(); df.dateFormat = "HH:mm:ss.SS"
var (r, ms) = scanOnce()
print("\(df.string(from: Date())) scan0 \(String(format: "%.1f", ms)) ms measuring=\(r.measuring)")
for i in 1...scans {
  Thread.sleep(forTimeInterval: i == 1 ? 0.5 : 1.0)
  (r, ms) = scanOnce()
  let sum = r.apps.reduce(0) { $0 + $1.value(for: metric) }
  print("\(df.string(from: Date())) scan\(i) \(String(format: "%.1f", ms)) ms header=\(r.totalCPUPercent.map { String(format: "%.1f%%", $0) } ?? "nil") rowsum=\(fmt(metric, sum)) rows=\(r.apps.count)")
  for a in r.apps.prefix(showTop) + r.apps.filter({ $0.appPID < 0 }) where r.apps.prefix(showTop).contains(a) || a.appPID < 0 {
    let am = metric == .cpu ? String(format: " (AM %.0f%%)", a.cpuPercent * cores) : ""
    print("   \(name(a)) [\(a.appPID)] \(fmt(metric, a.value(for: metric)))\(am) procs=\(a.processes.count)")
    if ProcessInfo.processInfo.environment["KIDS"] != nil {
      for p in a.processes.prefix(4) { print("      - \(pname(p)) \(p.pid) \(fmt(metric, p.value(for: metric)))\(metric == .cpu ? String(format: " (AM %.0f%%)", p.cpuPercent*cores) : "")") }
    }
  }
}
