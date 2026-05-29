import Foundation

/// Which resource a breakdown ranks apps by.
public enum BreakdownMetric: Equatable {
    case cpu
    case memory
}

/// Raw per-process reading straight from libproc (one entry per user process).
public struct RawProcess: Equatable {
    public let pid: Int32
    public let ppid: Int32
    public let cpuTimeNs: UInt64    // cumulative user+system CPU time, nanoseconds
    public let memoryBytes: UInt64  // resident size (RSS)

    public init(pid: Int32, ppid: Int32, cpuTimeNs: UInt64, memoryBytes: UInt64) {
        self.pid = pid; self.ppid = ppid; self.cpuTimeNs = cpuTimeNs; self.memoryBytes = memoryBytes
    }
}

/// A single process's usage, already attributed to its owning GUI app.
public struct ProcessUsage: Equatable {
    public let pid: Int32
    public let appPID: Int32       // owning GUI app's pid (the grouping key)
    public let cpuPercent: Double
    public let memoryBytes: UInt64

    public init(pid: Int32, appPID: Int32, cpuPercent: Double, memoryBytes: UInt64) {
        self.pid = pid; self.appPID = appPID; self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes
    }
}

/// One app's summed usage across all of its processes.
public struct AppUsage: Equatable, Identifiable {
    public let appPID: Int32
    public let pids: [Int32]
    public let cpuPercent: Double
    public let memoryBytes: UInt64

    public var id: Int32 { appPID }

    public init(appPID: Int32, pids: [Int32], cpuPercent: Double, memoryBytes: UInt64) {
        self.appPID = appPID; self.pids = pids; self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes
    }

    public func value(for metric: BreakdownMetric) -> Double {
        switch metric {
        case .cpu: return cpuPercent
        case .memory: return Double(memoryBytes)
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
