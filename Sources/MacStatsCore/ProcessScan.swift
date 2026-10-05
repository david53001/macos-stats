import Foundation

/// Finds the app a process belongs to. At each step up the parent chain (the process itself
/// first): the app macOS holds *responsible* for it wins (how Activity Monitor and privacy
/// prompts attribute work: a Terminal tab's shell, build or render → Terminal; an app's XPC
/// helpers, which launchd starts → that app); else the process itself if it is an app; else
/// its parent. `parent` should see past processes we can't read (a Terminal tab's root
/// `login`). Returns nil when the chain reaches launchd without meeting an app.
public func owningAppPID(for pid: Int32, parent: (Int32) -> Int32?, responsible: (Int32) -> Int32?,
                         appPIDs: Set<Int32>) -> Int32? {
    var current = pid
    var seen = Set<Int32>()
    while current > 1, seen.insert(current).inserted {
        if let r = responsible(current), r > 0, appPIDs.contains(r) { return r }
        if appPIDs.contains(current) { return current }
        guard let up = parent(current), up != current else { return nil }
        current = up
    }
    return nil
}

/// Attributes each scanned process to an app, or to `BreakdownGroup.otherProcesses`.
/// Results are cached per process (keyed by pid + start time, so a reused pid is looked up
/// again) and dropped whenever the set of running apps changes, so a steady scan costs a
/// dictionary lookup per process. The full process table (which includes root processes
/// such as a Terminal tab's `login`) is fetched only when a parent chain leaves the user's
/// processes, at most once per scan.
public final class ProcessAttributor {
    private struct Entry {
        let startTime: UInt64
        let owner: Int32
    }

    private let responsible: (Int32) -> Int32?
    private let allParents: () -> [Int32: Int32]
    private var cache: [Int32: Entry] = [:]
    private var cachedAppPIDs: Set<Int32> = []

    public init(responsible: @escaping (Int32) -> Int32? = responsiblePID(for:),
                allParents: @escaping () -> [Int32: Int32] = readAllParentPIDs) {
        self.responsible = responsible
        self.allParents = allParents
    }

    /// pid → owning app pid (or `BreakdownGroup.otherProcesses`) for every process in `processes`.
    public func owners(for processes: [RawProcess], appPIDs: Set<Int32>) -> [Int32: Int32] {
        if appPIDs != cachedAppPIDs {
            cache = [:]
            cachedAppPIDs = appPIDs
        }
        var userParents: [Int32: Int32]?
        var fullParents: [Int32: Int32]?
        var next: [Int32: Entry] = [:]
        next.reserveCapacity(processes.count)
        var result: [Int32: Int32] = [:]
        result.reserveCapacity(processes.count)

        for p in processes {
            if let hit = cache[p.pid], hit.startTime == p.startTime {
                next[p.pid] = hit
                result[p.pid] = hit.owner
                continue
            }
            if userParents == nil {
                userParents = Dictionary(processes.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
            }
            let owner = owningAppPID(for: p.pid, parent: { pid in
                if let up = userParents?[pid] { return up }
                if fullParents == nil { fullParents = self.allParents() }
                return fullParents?[pid]
            }, responsible: responsible, appPIDs: appPIDs) ?? BreakdownGroup.otherProcesses
            next[p.pid] = Entry(startTime: p.startTime, owner: owner)
            result[p.pid] = owner
        }
        cache = next   // forget processes that exited
        return result
    }
}

/// What one process used between two scans.
public struct ProcessDelta: Equatable {
    public var cpuNs: UInt64
    public var energyNj: UInt64

    public init(cpuNs: UInt64, energyNj: UInt64) {
        self.cpuNs = cpuNs; self.energyNj = energyNj
    }
}

/// Turns successive process scans into per-interval usage.
///
/// - A process that started since the last scan counts from zero (its whole CPU time and
///   energy fall in this interval); one that was merely missed by the last scan gets no
///   baseline for one interval rather than its whole lifetime at once.
/// - Work by processes that exit between scans isn't lost: when a parent reaps a child the
///   kernel adds the child's total CPU time to the parent's child time, so the growth of a
///   surviving parent's child time, minus what earlier scans already counted for the
///   children that vanished, is credited to the parent. No extra system calls.
public final class ProcessSampler {
    private var previous: [Int32: RawProcess] = [:]
    private var previousTime: TimeInterval?
    private var previousAbsTime: UInt64 = 0
    /// CPU (ns) already counted for vanished descendants whose reap hasn't shown up yet in
    /// this parent's child time.
    private var childDebt: [Int32: UInt64] = [:]
    /// Seconds between the last two scans (0 until there are two).
    public private(set) var elapsedSeconds: Double = 0

    public init() {}

    /// Records a scan taken at `time` (seconds) / `absTime` (Mach absolute time, the clock
    /// of `RawProcess.startTime`). Returns pid → usage since the previous scan, or nil when
    /// this is the first scan (a baseline only).
    public func ingest(_ processes: [RawProcess], time: TimeInterval, absTime: UInt64) -> [Int32: ProcessDelta]? {
        let lastTime = previousTime
        let lastAbsTime = previousAbsTime
        let last = previous
        previous = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        previousTime = time
        previousAbsTime = absTime
        guard let lastTime, time > lastTime else {
            elapsedSeconds = 0
            childDebt = [:]
            return nil
        }
        elapsedSeconds = time - lastTime

        var deltas: [Int32: ProcessDelta] = [:]
        deltas.reserveCapacity(processes.count)
        var survivors = Set<Int32>()
        survivors.reserveCapacity(processes.count)
        for p in processes {
            if let old = last[p.pid], old.startTime == p.startTime {
                survivors.insert(p.pid)
                deltas[p.pid] = ProcessDelta(cpuNs: p.cpuTimeNs &- min(old.cpuTimeNs, p.cpuTimeNs),
                                             energyNj: p.energyNj &- min(old.energyNj, p.energyNj))
            } else if p.startTime != 0, p.startTime >= lastAbsTime {
                deltas[p.pid] = ProcessDelta(cpuNs: p.cpuTimeNs + p.childCPUTimeNs, energyNj: p.energyNj)
            } else {
                deltas[p.pid] = ProcessDelta(cpuNs: 0, energyNj: 0)
            }
        }

        // Each vanished process's already-counted time is owed by its nearest surviving
        // ancestor (whose child time will include it once reaped).
        var debt = childDebt.filter { survivors.contains($0.key) }
        for (pid, old) in last where !survivors.contains(pid) {
            var ancestor = old.ppid
            var hops = 0
            while ancestor > 1, hops < 64 {
                if survivors.contains(ancestor) {
                    debt[ancestor, default: 0] += old.cpuTimeNs + old.childCPUTimeNs
                    break
                }
                guard let up = last[ancestor] else { break }
                ancestor = up.ppid
                hops += 1
            }
        }

        for p in processes where survivors.contains(p.pid) {
            guard let old = last[p.pid], p.childCPUTimeNs > old.childCPUTimeNs || debt[p.pid] != nil else { continue }
            let grown = p.childCPUTimeNs &- min(old.childCPUTimeNs, p.childCPUTimeNs)
            let owed = debt[p.pid] ?? 0
            if grown > owed {
                deltas[p.pid]?.cpuNs += grown - owed
                debt[p.pid] = nil
            } else {
                debt[p.pid] = owed - grown > 0 ? owed - grown : nil
            }
        }
        childDebt = debt
        return deltas
    }
}

/// One breakdown's scan pipeline: attribution + interval usage + the CPU header over the
/// same interval. Lives only while a breakdown is open (a new one per drill-in).
public final class BreakdownScanner {
    public struct Result: Equatable {
        public let apps: [AppUsage]
        /// Whole-machine CPU % over exactly the interval the rows cover (nil until measured).
        public let totalCPUPercent: Double?
        /// CPU and energy need two scans for a delta.
        public let measuring: Bool
    }

    private let cores: Double
    private let attributor: ProcessAttributor
    private let sampler = ProcessSampler()
    private var lastTicks: CPUTicks?

    public init(cores: Int = ProcessInfo.processInfo.activeProcessorCount,
                responsible: @escaping (Int32) -> Int32? = responsiblePID(for:),
                allParents: @escaping () -> [Int32: Int32] = readAllParentPIDs) {
        self.cores = Double(max(1, cores))
        self.attributor = ProcessAttributor(responsible: responsible, allParents: allParents)
    }

    public func scan(_ processes: [RawProcess], appPIDs: Set<Int32>, metric: BreakdownMetric,
                     time: TimeInterval, absTime: UInt64, cpuTicks: CPUTicks) -> Result {
        let owners = attributor.owners(for: processes, appPIDs: appPIDs)
        let deltas = sampler.ingest(processes, time: time, absTime: absTime)
        let elapsed = sampler.elapsedSeconds
        let total = lastTicks.map { cpuBusyPercent(previous: $0, current: cpuTicks) }
        lastTicks = cpuTicks

        var usages: [ProcessUsage] = []
        usages.reserveCapacity(processes.count)
        for p in processes {
            let d = deltas?[p.pid]
            let cpu = d.map {
                processCPUPercent(previousCPUTimeNs: 0, currentCPUTimeNs: $0.cpuNs, elapsedSeconds: elapsed) / cores
            } ?? 0
            let watts = metric == .energy
                ? d.map { processWatts(previousNj: 0, currentNj: $0.energyNj, elapsedSeconds: elapsed) } ?? 0
                : 0
            usages.append(ProcessUsage(pid: p.pid, appPID: owners[p.pid] ?? BreakdownGroup.otherProcesses,
                                       cpuPercent: cpu, memoryBytes: p.memoryBytes, watts: watts,
                                       startTime: p.startTime))
        }

        let measuring = metric != .memory && deltas == nil
        var apps = aggregate(usages, by: metric)
        if metric == .cpu, !measuring, let total {
            apps = addingSystemRow(to: apps, totalCPUPercent: total)
        }
        return Result(apps: apps, totalCPUPercent: measuring ? nil : total, measuring: measuring)
    }
}
