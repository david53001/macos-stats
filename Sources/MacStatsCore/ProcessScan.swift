import Foundation

/// Finds the app a process belongs to. At each step up the parent chain (the process itself
/// first): the app macOS holds *responsible* for it wins (how Activity Monitor and privacy
/// prompts attribute work: a Terminal tab's shell, build or render → Terminal; an app's XPC
/// helpers, which launchd starts → that app); else the process itself if it is an app; else
/// its parent. `parent` should see past processes we can't read (a Terminal tab's root
/// `login`). Returns nil when the chain reaches launchd without meeting an app.
///
/// `fallbackAppPIDs` are registered "apps" that aren't real ones (see `attributionAnchors`):
/// Claude's MCP servers (`npm exec …`, background-only, no bundle id, responsible for
/// themselves) used to end the walk as their own row. They only count when nothing further up
/// is a real app, so the MCP server lands under Claude while a lone agent keeps its own row.
public func owningAppPID(for pid: Int32, parent: (Int32) -> Int32?, responsible: (Int32) -> Int32?,
                         appPIDs: Set<Int32>, fallbackAppPIDs: Set<Int32> = []) -> Int32? {
    var current = pid
    var seen = Set<Int32>()
    var fallback: Int32?
    while current > 1, seen.insert(current).inserted {
        if let r = responsible(current), r > 0 {
            if appPIDs.contains(r) { return r }
            if fallback == nil, fallbackAppPIDs.contains(r) { fallback = r }
        }
        if appPIDs.contains(current) { return current }
        if fallback == nil, fallbackAppPIDs.contains(current) { fallback = current }
        guard let up = parent(current), up != current else { return fallback }
        current = up
    }
    return fallback
}

/// What attribution needs to know about one `NSWorkspace` running application.
public struct RunningAppInfo: Equatable {
    public let pid: Int32
    public let hasBundleIdentifier: Bool
    /// `activationPolicy == .prohibited`: no Dock icon, no menu bar, no windows of its own.
    public let isBackgroundOnly: Bool

    public init(pid: Int32, hasBundleIdentifier: Bool, isBackgroundOnly: Bool) {
        self.pid = pid; self.hasBundleIdentifier = hasBundleIdentifier; self.isBackgroundOnly = isBackgroundOnly
    }
}

/// Splits the running applications into real apps (regular or accessory, with a bundle id),
/// which always end an attribution walk, and the rest, which are only a fallback
/// (`owningAppPID`'s `fallbackAppPIDs`). macOS lists background processes such as Claude's
/// MCP servers (`npm exec …`, a disclaimed `node`) and widget extensions as running apps too.
public func attributionAnchors(_ apps: [RunningAppInfo]) -> (apps: Set<Int32>, fallbacks: Set<Int32>) {
    var real = Set<Int32>(), fallbacks = Set<Int32>()
    for app in apps where app.pid > 0 {
        if app.hasBundleIdentifier && !app.isBackgroundOnly { real.insert(app.pid) } else { fallbacks.insert(app.pid) }
    }
    return (real, fallbacks)
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
    private var cachedFallbackPIDs: Set<Int32> = []

    public init(responsible: @escaping (Int32) -> Int32? = responsiblePID(for:),
                allParents: @escaping () -> [Int32: Int32] = readAllParentPIDs) {
        self.responsible = responsible
        self.allParents = allParents
    }

    /// pid → owning app pid (or `BreakdownGroup.otherProcesses`) for every process in `processes`.
    public func owners(for processes: [RawProcess], appPIDs: Set<Int32>,
                       fallbackAppPIDs: Set<Int32> = []) -> [Int32: Int32] {
        if appPIDs != cachedAppPIDs || fallbackAppPIDs != cachedFallbackPIDs {
            cache = [:]
            cachedAppPIDs = appPIDs
            cachedFallbackPIDs = fallbackAppPIDs
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
            }, responsible: responsible, appPIDs: appPIDs,
               fallbackAppPIDs: fallbackAppPIDs) ?? BreakdownGroup.otherProcesses
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
    /// The part of `cpuNs` credited from reaped children (see `ProcessSampler`). Unlike a
    /// process's own time it can't be checked per process, so `BreakdownScanner` caps it.
    public var childCreditNs: UInt64

    public init(cpuNs: UInt64, energyNj: UInt64, childCreditNs: UInt64 = 0) {
        self.cpuNs = cpuNs; self.energyNj = energyNj; self.childCreditNs = childCreditNs
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
/// - That debt expires after `debtScans` scans: a descendant reaped by someone else (handed to
///   launchd when its own parent exited) never shows up in the ancestor's child time, and
///   would otherwise swallow the ancestor's later, real credit.
public final class ProcessSampler {
    public static let debtScans = 3

    private struct Debt {
        var ns: UInt64
        let scan: Int
    }

    private var previous: [Int32: RawProcess] = [:]
    private var previousTime: TimeInterval?
    private var previousAbsTime: UInt64 = 0
    /// CPU (ns) already counted for vanished descendants whose reap hasn't shown up yet in
    /// this parent's child time, oldest first, with the scan that added it.
    private var childDebt: [Int32: [Debt]] = [:]
    private var scanCount = 0
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
        scanCount += 1
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
                    debt[ancestor, default: []].append(Debt(ns: old.cpuTimeNs + old.childCPUTimeNs, scan: scanCount))
                    break
                }
                guard let up = last[ancestor] else { break }
                ancestor = up.ppid
                hops += 1
            }
        }

        for p in processes where survivors.contains(p.pid) {
            guard let old = last[p.pid], p.childCPUTimeNs > old.childCPUTimeNs || debt[p.pid] != nil else { continue }
            var grown = p.childCPUTimeNs &- min(old.childCPUTimeNs, p.childCPUTimeNs)
            var owed = (debt[p.pid] ?? []).filter { scanCount - $0.scan < Self.debtScans }
            while grown > 0, !owed.isEmpty {   // pay the oldest debt first
                let paid = min(grown, owed[0].ns)
                grown -= paid
                owed[0].ns -= paid
                if owed[0].ns == 0 { owed.removeFirst() }
            }
            if grown > 0 {
                deltas[p.pid]?.cpuNs += grown
                deltas[p.pid]?.childCreditNs += grown
            }
            debt[p.pid] = owed.isEmpty ? nil : owed
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

    public func scan(_ processes: [RawProcess], appPIDs: Set<Int32>, fallbackAppPIDs: Set<Int32> = [],
                     metric: BreakdownMetric, time: TimeInterval, absTime: UInt64,
                     cpuTicks: CPUTicks) -> Result {
        let owners = attributor.owners(for: processes, appPIDs: appPIDs, fallbackAppPIDs: fallbackAppPIDs)
        let deltas = sampler.ingest(processes, time: time, absTime: absTime)
        let elapsed = sampler.elapsedSeconds
        let total = lastTicks.map { cpuBusyPercent(previous: $0, current: cpuTicks) }
        lastTicks = cpuTicks

        // Reaped-child credit is capped, all of it together, at the CPU the machine used beyond
        // the processes' own time. When a root process we can't read (a Terminal tab's
        // `login`, `sudo`, a setuid `top`) exits, its parent's child time jumps by that whole
        // subtree's lifetime, which earlier scans already counted (live, or as System): one
        // scan read 510 % of one core for a tab's shell under an 11 % header. Real credit
        // (builds' short-lived compilers) fits in the budget: it is part of that remainder.
        var creditScale = 1.0
        if let deltas, let total, elapsed > 0 {
            var credit = 0.0, own = 0.0
            for d in deltas.values {
                credit += Double(d.childCreditNs)
                own += Double(d.cpuNs - d.childCreditNs)
            }
            if credit > 0 {
                let machineNs = total / 100 * elapsed * cores * 1_000_000_000
                creditScale = min(1, max(0, machineNs - own) / credit)
            }
        }

        var usages: [ProcessUsage] = []
        usages.reserveCapacity(processes.count)
        for p in processes {
            let d = deltas?[p.pid]
            let cpu = d.map {
                let ns = $0.cpuNs - $0.childCreditNs + UInt64(Double($0.childCreditNs) * creditScale)
                return processCPUPercent(previousCPUTimeNs: 0, currentCPUTimeNs: ns, elapsedSeconds: elapsed) / cores
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
