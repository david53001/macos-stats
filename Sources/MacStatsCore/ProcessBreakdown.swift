import Foundation

/// Which resource a breakdown ranks apps by.
public enum BreakdownMetric: Equatable {
    case cpu
    case memory
    /// Watts of CPU energy per app (the Battery drill-in).
    case energy
}

/// Raw per-process reading straight from libproc (one entry per user process).
public struct RawProcess: Equatable {
    public let pid: Int32
    public let ppid: Int32
    public let cpuTimeNs: UInt64    // cumulative user+system CPU time, nanoseconds
    public let memoryBytes: UInt64  // physical footprint (Activity Monitor's Memory); RSS fallback
    public let energyNj: UInt64     // cumulative CPU energy, nanojoules (0 unless requested)
    /// Cumulative CPU time (ns) of exited children this process has reaped, including their
    /// own reaped children. Lets a scan credit work done by processes that came and went
    /// between two scans.
    public let childCPUTimeNs: UInt64
    /// When the process started, in Mach absolute time (`ri_proc_start_abstime`); 0 if unknown.
    /// Tells a reused pid from the process that had it before.
    public let startTime: UInt64

    public init(pid: Int32, ppid: Int32, cpuTimeNs: UInt64, memoryBytes: UInt64, energyNj: UInt64 = 0,
                childCPUTimeNs: UInt64 = 0, startTime: UInt64 = 0) {
        self.pid = pid; self.ppid = ppid; self.cpuTimeNs = cpuTimeNs; self.memoryBytes = memoryBytes
        self.energyNj = energyNj; self.childCPUTimeNs = childCPUTimeNs; self.startTime = startTime
    }
}

/// A single process's usage, already attributed to its owning GUI app.
public struct ProcessUsage: Equatable, Identifiable {
    public let pid: Int32
    public let appPID: Int32       // owning GUI app's pid (the grouping key), or a `BreakdownGroup`
    /// Share of the whole machine (0...100, all cores together), the scale of the CPU card.
    /// Activity Monitor's per-process figure (100 % = one core) is this × the core count.
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    public let watts: Double
    /// The process's start time (see `RawProcess.startTime`), so an action can check that the
    /// pid still belongs to the same process before signalling it.
    public let startTime: UInt64

    public var id: Int32 { pid }

    public init(pid: Int32, appPID: Int32, cpuPercent: Double, memoryBytes: UInt64, watts: Double = 0,
                startTime: UInt64 = 0) {
        self.pid = pid; self.appPID = appPID; self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes
        self.watts = watts; self.startTime = startTime
    }

    public func value(for metric: BreakdownMetric) -> Double {
        switch metric {
        case .cpu: return cpuPercent
        case .memory: return Double(memoryBytes)
        case .energy: return watts
        }
    }
}

/// Group keys for breakdown rows that aren't a single app (app pids are always > 0).
public enum BreakdownGroup {
    /// The user's processes that no running app is responsible for (agents, daemons).
    public static let otherProcesses: Int32 = -1
    /// CPU the machine used outside the user's processes: the kernel, WindowServer and other
    /// users' daemons, which can't be read per process. No processes, no actions.
    public static let system: Int32 = -2
}

/// One app's summed usage across all of its processes.
public struct AppUsage: Equatable, Identifiable {
    public let appPID: Int32
    /// The app's processes, ranked by the breakdown's metric (ties by pid).
    public let processes: [ProcessUsage]
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    public let watts: Double

    public var id: Int32 { appPID }
    public var pids: [Int32] { processes.map(\.pid) }
    /// True for a real app (not the "Other processes" or "System" group).
    public var isApp: Bool { appPID > 0 }

    public init(appPID: Int32, processes: [ProcessUsage], cpuPercent: Double, memoryBytes: UInt64,
                watts: Double = 0) {
        self.appPID = appPID; self.processes = processes; self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes; self.watts = watts
    }

    public func value(for metric: BreakdownMetric) -> Double {
        switch metric {
        case .cpu: return cpuPercent
        case .memory: return Double(memoryBytes)
        case .energy: return watts
        }
    }
}

/// A process's CPU percentage between two cumulative CPU-time samples.
/// May exceed 100 on multiple cores (Activity-Monitor convention).
public func processCPUPercent(previousCPUTimeNs: UInt64, currentCPUTimeNs: UInt64, elapsedSeconds: Double) -> Double {
    guard elapsedSeconds > 0, currentCPUTimeNs >= previousCPUTimeNs else { return 0 }
    let deltaNs = Double(currentCPUTimeNs - previousCPUTimeNs)
    return max(0, deltaNs / (elapsedSeconds * 1_000_000_000) * 100)
}

/// A process's average CPU power (W) between two cumulative energy samples.
public func processWatts(previousNj: UInt64, currentNj: UInt64, elapsedSeconds: Double) -> Double {
    guard elapsedSeconds > 0, currentNj >= previousNj else { return 0 }
    return Double(currentNj - previousNj) / 1_000_000_000 / elapsedSeconds
}

/// Walks the parent-pid chain from `pid` upward until it reaches a pid that is a known
/// GUI app (`appPIDs`). Returns that app's pid, or nil if the chain ends without hitting
/// an app (e.g. a system daemon reparented to launchd). Guards against cycles and gaps.
public func owningAppPID(for pid: Int32, ppid: [Int32: Int32], appPIDs: Set<Int32>) -> Int32? {
    var current = pid
    var seen = Set<Int32>()
    while true {
        if appPIDs.contains(current) { return current }
        if seen.contains(current) { return nil }      // cycle guard
        seen.insert(current)
        guard let parent = ppid[current], parent != current else { return nil }
        current = parent
    }
}

/// Groups already-attributed process usages by their owning app (or group), sums CPU%,
/// memory and watts, and returns the rows sorted descending by the chosen metric, each with
/// its processes ranked the same way.
public func aggregate(_ processes: [ProcessUsage], by metric: BreakdownMetric) -> [AppUsage] {
    var byApp: [Int32: (procs: [ProcessUsage], cpu: Double, mem: UInt64, watts: Double)] = [:]
    for p in processes {
        var entry = byApp[p.appPID] ?? (procs: [], cpu: 0, mem: 0, watts: 0)
        entry.procs.append(p)
        entry.cpu += p.cpuPercent
        entry.mem += p.memoryBytes
        entry.watts += p.watts
        byApp[p.appPID] = entry
    }
    let apps = byApp.map { appPID, e in
        AppUsage(appPID: appPID, processes: e.procs.sorted { ranksBefore($0.value(for: metric), $0.pid,
                                                                         $1.value(for: metric), $1.pid) },
                 cpuPercent: e.cpu, memoryBytes: e.mem, watts: e.watts)
    }
    return sortedRows(apps, by: metric)
}

/// Adds the "System" row to a CPU breakdown: what the whole machine used (`totalCPUPercent`,
/// over the same interval as the rows) minus what the rows account for, so the rows add up
/// to the header. Clamped at 0 (the two clocks differ slightly).
public func addingSystemRow(to apps: [AppUsage], totalCPUPercent: Double) -> [AppUsage] {
    let accounted = apps.reduce(0) { $0 + $1.cpuPercent }
    let system = AppUsage(appPID: BreakdownGroup.system, processes: [],
                          cpuPercent: max(0, totalCPUPercent - accounted), memoryBytes: 0)
    return sortedRows(apps + [system], by: .cpu)
}

/// Descending by value. Ties (e.g. many idle apps at 0% CPU) break by pid, so equal rows keep
/// a stable order between scans instead of shuffling; group rows (negative keys) go last.
private func sortedRows(_ apps: [AppUsage], by metric: BreakdownMetric) -> [AppUsage] {
    apps.sorted { ranksBefore($0.value(for: metric), $0.appPID, $1.value(for: metric), $1.appPID) }
}

private func ranksBefore(_ a: Double, _ aKey: Int32, _ b: Double, _ bKey: Int32) -> Bool {
    if a != b { return a > b }
    if (aKey < 0) != (bKey < 0) { return aKey > 0 }
    return aKey < bKey
}
