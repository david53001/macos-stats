import AppKit
import Darwin
import Foundation

// Harness replicating AppModel.procScanTick / sample / refreshBattery glue.
setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "cpu"
let cores = ProcessInfo.processInfo.activeProcessorCount

var appHasBundleID: [Int32: Bool] = [:]
func anchors() -> (apps: Set<Int32>, fallbacks: Set<Int32>) {
    var hasBundleID: [Int32: Bool] = [:]
    let a = attributionAnchors(NSWorkspace.shared.runningApplications.map { app in
        let pid = Int32(app.processIdentifier)
        let hasID = appHasBundleID[pid] ?? (app.bundleIdentifier != nil)
        hasBundleID[pid] = hasID
        return RunningAppInfo(pid: pid, hasBundleIdentifier: hasID,
                              isBackgroundOnly: app.activationPolicy == .prohibited)
    })
    appHasBundleID = hasBundleID
    return a
}

func appName(_ pid: Int32) -> String {
    if pid == BreakdownGroup.otherProcesses { return "Other processes" }
    if pid == BreakdownGroup.system { return "System" }
    return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "PID \(pid)"
}

func cpuFmt(_ c: Double) -> String { c < 9.95 ? String(format: "%.1f%%", c) : String(format: "%.0f%%", c) }

func printRows(_ r: BreakdownScanner.Result, metric: BreakdownMetric, top: Int, children: Int, watch: Set<String>) {
    var sum = 0.0
    for app in r.apps { sum += app.value(for: metric) }
    if metric == .cpu {
        print(String(format: "  header=%.1f%%  rowsum=%.1f%%  measuring=%@", r.totalCPUPercent ?? -1, sum, r.measuring ? "y" : "n"))
    }
    for (i, app) in r.apps.enumerated() {
        let name = appName(app.appPID)
        let show = i < top || watch.contains(name) || app.appPID < 0
        guard show else { continue }
        let v: String
        switch metric {
        case .cpu: v = cpuFmt(app.cpuPercent) + String(format: " (%.0f%% 1core)", app.cpuPercent * Double(cores))
        case .memory: v = String(format: "%.0f MB", Double(app.memoryBytes) / 1_048_576)
        case .energy: v = String(format: "%.2f W", app.watts)
        }
        print("  [\(i)] \(name) pid=\(app.appPID) n=\(app.processes.count) \(v)")
        for p in app.processes.prefix(children) {
            let pv: String
            switch metric {
            case .cpu: pv = cpuFmt(p.cpuPercent) + String(format: " (%.0f%% 1core)", p.cpuPercent * Double(cores))
            case .memory: pv = String(format: "%.0f MB", Double(p.memoryBytes) / 1_048_576)
            case .energy: pv = String(format: "%.2f W", p.watts)
            }
            print("      \(processName(p.pid) ?? "?") \(p.pid) \(pv)")
        }
    }
}

func cardCPU(_ a: CPUTicks, _ b: CPUTicks) -> Double { cpuBusyPercent(previous: a, current: b) }

switch mode {
case "cpu", "energy":
    // args: seconds top children watch-names...
    let seconds = args.count > 2 ? Double(args[2])! : 8
    let top = args.count > 3 ? Int(args[3])! : 8
    let children = args.count > 4 ? Int(args[4])! : 3
    let watch = Set(args.dropFirst(5))
    let metric: BreakdownMetric = mode == "cpu" ? .cpu : .energy
    let scanner = BreakdownScanner()
    let start = Date()
    var n = 0
    var lastCard = readCPUTicks()
    while Date().timeIntervalSince(start) < seconds {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let time = Date().timeIntervalSinceReferenceDate
        let absTime = mach_absolute_time()
        let ticks = readCPUTicks()
        let raw = readRawProcesses(includeEnergy: metric == .energy)
        let a = anchors()
        let r = scanner.scan(raw, appPIDs: a.apps, fallbackAppPIDs: a.fallbacks, metric: metric,
                             time: time, absTime: absTime, cpuTicks: ticks)
        let t1 = DispatchTime.now().uptimeNanoseconds
        let card = cardCPU(lastCard, ticks); lastCard = ticks
        print(String(format: "scan %d t=%.2f cost=%.2fms procs=%d card~%.1f%%", n, time.truncatingRemainder(dividingBy: 1000), Double(t1 - t0) / 1e6, raw.count, card))
        printRows(r, metric: metric, top: top, children: children, watch: watch)
        n += 1
        usleep(n == 1 ? 500_000 : 1_000_000)
    }
case "cost":
    // Cost of N steady scans with the real cadence-free loop.
    let n = args.count > 2 ? Int(args[2])! : 20
    let metric: BreakdownMetric = args.count > 3 && args[3] == "mem" ? .memory : (args.count > 3 && args[3] == "energy" ? .energy : .cpu)
    let scanner = BreakdownScanner()
    var costs: [Double] = []
    var ru0 = rusage(); getrusage(RUSAGE_SELF, &ru0)
    for i in 0..<n {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let time = Date().timeIntervalSinceReferenceDate
        let absTime = mach_absolute_time()
        let ticks = readCPUTicks()
        let raw = readRawProcesses(includeEnergy: metric == .energy)
        let a = anchors()
        _ = scanner.scan(raw, appPIDs: a.apps, fallbackAppPIDs: a.fallbacks, metric: metric, time: time,
                         absTime: absTime, cpuTicks: ticks,
                         memoryInUseBytes: metric == .memory ? memoryInUseAtFullSize(readVMRaw()) : nil)
        let t1 = DispatchTime.now().uptimeNanoseconds
        if i > 0 { costs.append(Double(t1 - t0) / 1e6) }
        usleep(200_000)
    }
    var ru1 = rusage(); getrusage(RUSAGE_SELF, &ru1)
    costs.sort()
    let cpuSec = Double(ru1.ru_utime.tv_sec - ru0.ru_utime.tv_sec + ru1.ru_stime.tv_sec - ru0.ru_stime.tv_sec)
        + Double(ru1.ru_utime.tv_usec - ru0.ru_utime.tv_usec + ru1.ru_stime.tv_usec - ru0.ru_stime.tv_usec) / 1e6
    print(String(format: "scans=%d median=%.2fms p90=%.2fms max=%.2fms totalCPU=%.3fs maxrss=%ldKB", costs.count,
                 costs[costs.count / 2], costs[Int(Double(costs.count) * 0.9)], costs.last!, cpuSec, ru1.ru_maxrss / 1024))
case "mem":
    let top = args.count > 2 ? Int(args[2])! : 10
    let children = args.count > 3 ? Int(args[3])! : 3
    let watch = Set(args.dropFirst(4))
    let vm = readVMRaw()
    let total = ProcessInfo.processInfo.physicalMemory
    let s = memorySample(raw: vm, totalBytes: total, pressureLevel: readMemoryPressureLevel())
    let gib = { (b: UInt64) in String(format: "%.2f", Double(b) / 1_073_741_824) }
    print("card used=\(gib(s.usedBytes)) GiB  total=\(gib(s.totalBytes)) GiB  pressure=\(s.pressure)  shown=\(String(format: "%.1f / %.1f GB", Double(s.usedBytes) / 1_073_741_824, Double(total) / 1_073_741_824))")
    print("vm: page=\(vm.pageSize) free=\(vm.free) active=\(vm.active) inactive=\(vm.inactive) wired=\(vm.wired) compressor=\(vm.compressed) internal=\(vm.internal) purgeable=\(vm.purgeable) compOrig=\(vm.compressedOriginal)")
    print("inUseAtFullSize=\(gib(memoryInUseAtFullSize(vm))) GiB")
    let scanner = BreakdownScanner()
    let raw = readRawProcesses()
    let a = anchors()
    let r = scanner.scan(raw, appPIDs: a.apps, fallbackAppPIDs: a.fallbacks, metric: .memory,
                         time: Date().timeIntervalSinceReferenceDate, absTime: mach_absolute_time(),
                         cpuTicks: readCPUTicks(), memoryInUseBytes: memoryInUseAtFullSize(vm))
    let rowsum = r.apps.reduce(UInt64(0)) { $0 + $1.memoryBytes }
    print("rows sum=\(gib(rowsum)) GiB  user procs=\(raw.count)  sum footprint=\(gib(raw.reduce(0) { $0 + $1.memoryBytes })) GiB")
    printRows(r, metric: .memory, top: top, children: children, watch: watch)
    print("PIDS:" + raw.map { "\($0.pid):\($0.memoryBytes)" }.joined(separator: ","))
case "battery":
    let reader = SmartBatteryReader()
    let t = reader.read()
    let b = readBattery()
    print("IOPS: \(String(describing: b))")
    if let t {
        print("telemetry: \(t)")
        print("health=\(String(describing: t.healthPercent)) remainingWh=\(String(describing: t.remainingWh)) instantW=\(String(describing: t.instantWatts))")
    }
case "owner":
    // owner of each given pid (attribution walk)
    let a = anchors()
    let raw = readRawProcesses()
    let attributor = ProcessAttributor()
    let owners = attributor.owners(for: raw, appPIDs: a.apps, fallbackAppPIDs: a.fallbacks)
    for s in args.dropFirst(2) {
        let pid = Int32(s)!
        let o = owners[pid]
        print("pid \(pid) (\(processName(pid) ?? "?")) -> \(o.map { "\(appName($0)) [\($0)]" } ?? "not in user scan")  responsible=\(String(describing: responsiblePID(for: pid)))")
    }
    print("apps: " + a.apps.sorted().map { "\($0)=\(appName($0))" }.joined(separator: ", "))
    print("fallbacks: " + a.fallbacks.sorted().map { "\($0)=\(processName($0) ?? "?")" }.joined(separator: ", "))
default:
    print("modes: cpu secs top children [watch..] | energy | cost n [mem|energy] | mem | battery | owner pids")
}
