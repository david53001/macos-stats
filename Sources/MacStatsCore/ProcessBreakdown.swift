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

    public init(pid: Int32, ppid: Int32, cpuTimeNs: UInt64, memoryBytes: UInt64, energyNj: UInt64 = 0) {
        self.pid = pid; self.ppid = ppid; self.cpuTimeNs = cpuTimeNs; self.memoryBytes = memoryBytes
        self.energyNj = energyNj
    }
}

/// A single process's usage, already attributed to its owning GUI app.
public struct ProcessUsage: Equatable {
    public let pid: Int32
    public let appPID: Int32       // owning GUI app's pid (the grouping key)
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    public let watts: Double

    public init(pid: Int32, appPID: Int32, cpuPercent: Double, memoryBytes: UInt64, watts: Double = 0) {
        self.pid = pid; self.appPID = appPID; self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes
        self.watts = watts
    }
}

/// One app's summed usage across all of its processes.
public struct AppUsage: Equatable, Identifiable {
    public let appPID: Int32
    public let pids: [Int32]
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    public let watts: Double

    public var id: Int32 { appPID }

    public init(appPID: Int32, pids: [Int32], cpuPercent: Double, memoryBytes: UInt64, watts: Double = 0) {
        self.appPID = appPID; self.pids = pids; self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes
        self.watts = watts
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

/// Groups already-attributed process usages by their owning app, sums CPU% and memory,
/// and returns the apps sorted descending by the chosen metric. Input is assumed to be
/// pre-filtered to app-owned processes (callers skip processes whose `owningAppPID` is nil),
/// so the result contains only user apps.
public func aggregate(_ processes: [ProcessUsage], by metric: BreakdownMetric) -> [AppUsage] {
    var byApp: [Int32: (pids: [Int32], cpu: Double, mem: UInt64, watts: Double)] = [:]
    for p in processes {
        var entry = byApp[p.appPID] ?? (pids: [], cpu: 0, mem: 0, watts: 0)
        entry.pids.append(p.pid)
        entry.cpu += p.cpuPercent
        entry.mem += p.memoryBytes
        entry.watts += p.watts
        byApp[p.appPID] = entry
    }
    let apps = byApp.map { appPID, e in
        AppUsage(appPID: appPID, pids: e.pids, cpuPercent: e.cpu, memoryBytes: e.mem, watts: e.watts)
    }
    // Ties (e.g. many idle apps at 0% CPU) break by pid, so equal rows keep a stable order
    // between scans instead of shuffling with dictionary iteration order.
    return apps.sorted {
        let (a, b) = ($0.value(for: metric), $1.value(for: metric))
        return a != b ? a > b : $0.appPID < $1.appPID
    }
}
