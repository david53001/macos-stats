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
    /// One of macOS's own agents (`isMacOSAgent`): loginwindow, Dock, WindowManager, universalaccessd…
    public let isMacOSAgent: Bool

    public init(pid: Int32, hasBundleIdentifier: Bool, isBackgroundOnly: Bool, isMacOSAgent: Bool = false) {
        self.pid = pid; self.hasBundleIdentifier = hasBundleIdentifier; self.isBackgroundOnly = isBackgroundOnly
        self.isMacOSAgent = isMacOSAgent
    }
}

/// True for a running "app" that is part of macOS rather than something the user opened: not a
/// regular (Dock) app, and installed with the system (`/System/…`, `/usr/…` but not `/usr/local/…`).
/// macOS registers ~30 such agents as running apps (loginwindow, Dock, Control Centre, WindowManager,
/// CoreServicesUIAgent, universalaccessd…); listed as apps they filled half of a quiet Mac's CPU
/// list with internal names and blank icons, and offered Force Quit on loginwindow (a logout).
/// Finder, Mail or System Settings are regular apps and stay apps.
public func isMacOSAgent(path: String?, isRegularApp: Bool) -> Bool {
    guard !isRegularApp, let path else { return false }
    return path.hasPrefix("/System/") || (path.hasPrefix("/usr/") && !path.hasPrefix("/usr/local/"))
}

/// Splits the running applications into real apps (regular or accessory, with a bundle id),
/// which always end an attribution walk, and the rest, which are only a fallback
/// (`owningAppPID`'s `fallbackAppPIDs`). macOS lists background processes such as Claude's
/// MCP servers (`npm exec …`, a disclaimed `node`) and widget extensions as running apps too.
/// macOS's own agents are neither, so their processes land in "Other processes".
public func attributionAnchors(_ apps: [RunningAppInfo]) -> (apps: Set<Int32>, fallbacks: Set<Int32>) {
    var real = Set<Int32>(), fallbacks = Set<Int32>()
    for app in apps where app.pid > 0 && !app.isMacOSAgent {
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
    /// The part of `energyNj` estimated for `childCreditNs` (capped along with it).
    public var childCreditEnergyNj: UInt64

    public init(cpuNs: UInt64, energyNj: UInt64, childCreditNs: UInt64 = 0, childCreditEnergyNj: UInt64 = 0) {
        self.cpuNs = cpuNs; self.energyNj = energyNj
        self.childCreditNs = childCreditNs; self.childCreditEnergyNj = childCreditEnergyNj
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
/// - Energy of reaped children is estimated (rusage has no child-energy field): the credited
///   CPU time × this interval's energy per CPU-ns (Σ energy ÷ Σ own CPU time). The ratio comes
///   from the processes that started this interval when they ran ≥ 20 ms (the reaped ones'
///   siblings: the next compiler, the next `dd`, so the same mix of performance and efficiency
///   cores), else from every process measured. An approximation: per scan it read 2.8–8.1 W
///   (mean 6.5 W) for 2 cores of sub-second `dd` processes against 7.0 W for the same load in
///   long-lived `yes` processes; before, it read 0.2–0.4 W.
/// - That debt expires after `debtScans` scans: a descendant reaped by someone else (handed to
///   launchd when its own parent exited) never shows up in the ancestor's child time, and
///   would otherwise swallow the ancestor's later, real credit.
/// - Work a vanished process may have done since the last scan that no reap explains is
///   reported in `unexplainedExitNs` / `orphanExitNs` (its last rate × the interval, an upper
///   bound), for `BreakdownScanner` to credit out of the System remainder.
public final class ProcessSampler {
    public static let debtScans = 3
    /// New processes' energy ratio is used once they ran at least this much CPU (ns).
    static let minRatioSampleNs = 20_000_000.0

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
    /// Each process's own CPU time (ns, no child credit) over the previous interval.
    private var previousOwnNs: [Int32: UInt64] = [:]
    private var previousElapsed: Double = 0
    private var scanCount = 0
    /// Seconds between the last two scans (0 until there are two).
    public private(set) var elapsedSeconds: Double = 0
    /// Surviving process → CPU (ns) its vanished descendants may have done since the last scan
    /// beyond what reaping credited to it this scan (an orphan reaped by launchd, or a reap
    /// still pending). An upper bound: each one's last-interval rate × this interval.
    public private(set) var unexplainedExitNs: [Int32: UInt64] = [:]
    /// Vanished process with no surviving ancestor (already handed to launchd) → the same
    /// upper bound of its unseen work.
    public private(set) var orphanExitNs: [Int32: UInt64] = [:]

    public init() {}

    /// Records `ns` as already counted for `pid`'s vanished descendants, so a reap that shows
    /// up later isn't credited a second time (see `BreakdownScanner`'s exit credit).
    public func addDebt(_ ns: UInt64, to pid: Int32) {
        guard ns > 0, previous[pid] != nil else { return }
        childDebt[pid, default: []].append(Debt(ns: ns, scan: scanCount))
    }

    /// Records a scan taken at `time` (seconds) / `absTime` (Mach absolute time, the clock
    /// of `RawProcess.startTime`). Returns pid → usage since the previous scan, or nil when
    /// this is the first scan (a baseline only).
    public func ingest(_ processes: [RawProcess], time: TimeInterval, absTime: UInt64) -> [Int32: ProcessDelta]? {
        let lastTime = previousTime
        let lastAbsTime = previousAbsTime
        let last = previous
        let lastOwnNs = previousOwnNs
        let lastElapsed = previousElapsed
        previous = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        previousTime = time
        previousAbsTime = absTime
        scanCount += 1
        unexplainedExitNs = [:]
        orphanExitNs = [:]
        guard let lastTime, time > lastTime else {
            elapsedSeconds = 0
            childDebt = [:]
            previousOwnNs = [:]
            previousElapsed = 0
            return nil
        }
        elapsedSeconds = time - lastTime

        var deltas: [Int32: ProcessDelta] = [:]
        deltas.reserveCapacity(processes.count)
        var survivors = Set<Int32>()
        survivors.reserveCapacity(processes.count)
        var reapedByNew: [Int32: UInt64] = [:]   // new processes' children reaped before we saw them
        for p in processes {
            if let old = last[p.pid], old.startTime == p.startTime {
                survivors.insert(p.pid)
                deltas[p.pid] = ProcessDelta(cpuNs: p.cpuTimeNs &- min(old.cpuTimeNs, p.cpuTimeNs),
                                             energyNj: p.energyNj &- min(old.energyNj, p.energyNj))
            } else if p.startTime != 0, p.startTime >= lastAbsTime {
                deltas[p.pid] = ProcessDelta(cpuNs: p.cpuTimeNs + p.childCPUTimeNs, energyNj: p.energyNj)
                if p.childCPUTimeNs > 0 { reapedByNew[p.pid] = p.childCPUTimeNs }
            } else {
                deltas[p.pid] = ProcessDelta(cpuNs: 0, energyNj: 0)
            }
        }

        // Each vanished process's already-counted time is owed by its nearest surviving
        // ancestor (whose child time will include it once reaped). Its possible unseen work
        // since the last scan is estimated from its last rate.
        var debt = childDebt.filter { survivors.contains($0.key) }
        var exitEstimate: [Int32: UInt64] = [:]
        for (pid, old) in last where !survivors.contains(pid) {
            var ancestor = old.ppid
            var hops = 0
            var target: Int32?
            while ancestor > 1, hops < 64 {
                if survivors.contains(ancestor) {
                    debt[ancestor, default: []].append(Debt(ns: old.cpuTimeNs + old.childCPUTimeNs, scan: scanCount))
                    target = ancestor
                    break
                }
                guard let up = last[ancestor] else { break }
                ancestor = up.ppid
                hops += 1
            }
            guard lastElapsed > 0, let rate = lastOwnNs[pid], rate > 0 else { continue }
            let estimate = UInt64(Double(rate) * min(elapsedSeconds / lastElapsed, 10))
            if let target { exitEstimate[target, default: 0] += estimate } else { orphanExitNs[pid] = estimate }
        }

        var credited: [Int32: UInt64] = [:]
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
                credited[p.pid] = grown
            }
            debt[p.pid] = owed.isEmpty ? nil : owed
        }
        childDebt = debt
        for (pid, estimate) in exitEstimate where estimate > credited[pid] ?? 0 {
            unexplainedExitNs[pid] = estimate - (credited[pid] ?? 0)
        }

        // Energy for reaped children: their CPU time × the interval's energy per CPU-ns.
        var ownTotal = 0.0, energyTotal = 0.0, newOwn = 0.0, newEnergy = 0.0
        var ownNs: [Int32: UInt64] = [:]
        ownNs.reserveCapacity(deltas.count)
        for (pid, d) in deltas {
            let own = d.cpuNs - d.childCreditNs - (reapedByNew[pid] ?? 0)
            ownNs[pid] = own
            ownTotal += Double(own)
            energyTotal += Double(d.energyNj)
            if let p = previous[pid], last[pid]?.startTime != p.startTime {
                newOwn += Double(own)
                newEnergy += Double(d.energyNj)
            }
        }
        previousOwnNs = ownNs
        previousElapsed = elapsedSeconds
        if energyTotal > 0, ownTotal > 0 {
            // Processes that started this interval are the reaped ones' siblings (the next
            // compiler, the next `dd`), so their mix of core types is the better guess.
            let useNew = newOwn >= Self.minRatioSampleNs && newEnergy > 0
            let njPerNs = useNew ? newEnergy / newOwn : energyTotal / ownTotal
            for (pid, ns) in credited {
                let nj = UInt64(Double(ns) * njPerNs)
                deltas[pid]?.energyNj += nj
                deltas[pid]?.childCreditEnergyNj += nj
            }
            for (pid, ns) in reapedByNew {
                deltas[pid]?.energyNj += UInt64(Double(ns) * njPerNs)
            }
        }
        return deltas
    }
}

/// One breakdown's scan pipeline: attribution + interval usage + the CPU header over the
/// same span. Lives only while a breakdown is open (a new one per drill-in).
///
/// CPU and energy rows are averaged over a trailing window (`windowSeconds`; by default
/// `trailingWindowSeconds` for CPU, `energyWindowSeconds` for energy), and so is the CPU header, so rows + System still add up to
/// it. A process that started mid-window counts what it used over the whole window; one that
/// exited mid-window keeps its earlier work in its app's "Exited processes" row while the app
/// runs (else it falls into System). Memory rows are instantaneous.
/// Not thread-safe: `@unchecked Sendable` so it can be handed to the app's serial scan queue,
/// which is the only place it is used.
public final class BreakdownScanner: @unchecked Sendable {
    public struct Result: Equatable, Sendable {
        public let apps: [AppUsage]
        /// Whole-machine CPU % over exactly the span the rows cover (nil until measured).
        public let totalCPUPercent: Double?
        /// CPU and energy need two scans for a delta.
        public let measuring: Bool
    }

    /// A process across scans: a reused pid is a different process.
    private struct ProcessKey: Hashable {
        let pid: Int32
        let startTime: UInt64
    }
    /// What one process did in one interval (after the child-credit cap), and its app then.
    private struct Work {
        let app: Int32
        let ns: Double
        let nj: Double
    }
    /// One scan interval of the trailing window.
    private struct Interval {
        let elapsed: Double
        /// The machine's busy CPU time (ns); nil when the tick counters didn't move.
        let busyNs: Double?
        /// Every process that was alive at the interval's end.
        let work: [ProcessKey: Work]
        /// Exit credit (ns) per app: work by processes that exited during the interval.
        let exitedNs: [Int32: Double]
    }

    private let cores: Double
    private let windowSeconds: TimeInterval?
    private let fastAttack: Bool
    private let attributor: ProcessAttributor
    private let sampler = ProcessSampler()
    private var lastTicks: CPUTicks?
    /// The previous scan's owners, for processes that have exited since.
    private var lastOwners: [Int32: Int32] = [:]
    /// The previous CPU scan's System row over that scan's interval alone (%): the level exit
    /// credit leaves to System.
    private var lastSystemPercent: Double?
    /// The trailing window's intervals, oldest first. A few dictionaries of ~500 entries
    /// (~20–60 KB), freed with the scanner when the breakdown closes.
    private var window: [Interval] = []
    /// Each live process's name, read once when it first shows up (a few new processes a scan).
    private var names: [ProcessKey: String] = [:]
    private let nameOf: (Int32) -> String?

    /// `windowSeconds`: the span rows are averaged over; 0 = the latest interval only, nil = the
    /// metric's own (`trailingWindowSeconds`, `energyWindowSeconds`). `fastAttack`: restart the window
    /// when the Mac gets much busier (`breakdownFastAttackCores`).
    public init(cores: Int = ProcessInfo.processInfo.activeProcessorCount,
                windowSeconds: TimeInterval? = nil, fastAttack: Bool = true,
                responsible: @escaping (Int32) -> Int32? = responsiblePID(for:),
                allParents: @escaping () -> [Int32: Int32] = readAllParentPIDs,
                nameOf: @escaping (Int32) -> String? = processName) {
        self.cores = Double(max(1, cores))
        self.windowSeconds = windowSeconds.map { max(0, $0) }
        self.fastAttack = fastAttack
        self.attributor = ProcessAttributor(responsible: responsible, allParents: allParents)
        self.nameOf = nameOf
    }

    public func scan(_ processes: [RawProcess], appPIDs: Set<Int32>, fallbackAppPIDs: Set<Int32> = [],
                     metric: BreakdownMetric, time: TimeInterval, absTime: UInt64,
                     cpuTicks: CPUTicks) -> Result {
        let owners = attributor.owners(for: processes, appPIDs: appPIDs, fallbackAppPIDs: fallbackAppPIDs)
        let deltas = sampler.ingest(processes, time: time, absTime: absTime)
        let elapsed = sampler.elapsedSeconds
        // Ticks that didn't move (a failed or stale read) span no time: that read 0 % over
        // 25 % of rows. No header for that scan rather than a wrong one.
        let total = lastTicks.flatMap { $0 == cpuTicks ? nil : cpuBusyPercent(previous: $0, current: cpuTicks) }
        lastTicks = cpuTicks
        let previousOwners = lastOwners
        lastOwners = owners
        let nsPerPercent = elapsed * cores * 1_000_000_000 / 100   // ns of one % of the Mac

        // Reaped-child credit is capped, all of it together, at the CPU the machine used beyond
        // the processes' own time. When a root process we can't read (a Terminal tab's
        // `login`, `sudo`, a setuid `top`) exits, its parent's child time jumps by that whole
        // subtree's lifetime, which earlier scans already counted (live, or as System): one
        // scan read 510 % of one core for a tab's shell under an 11 % header. Real credit
        // (builds' short-lived compilers) fits in the budget: it is part of that remainder.
        var creditScale = 1.0
        var exitCredit: [Int32: UInt64] = [:]
        if let deltas, let total, elapsed > 0 {
            var credit = 0.0, own = 0.0
            for d in deltas.values {
                credit += Double(d.childCreditNs)
                own += Double(d.cpuNs - d.childCreditNs)
            }
            let machineNs = total * nsPerPercent
            if credit > 0 {
                creditScale = min(1, max(0, machineNs - own) / credit)
            }
            if metric == .cpu {
                let unexplained = max(0, machineNs - own - credit * creditScale)
                let baseline = (lastSystemPercent ?? 0) * nsPerPercent
                exitCredit = exitWorkCredit(unexplained: sampler.unexplainedExitNs,
                                            orphans: sampler.orphanExitNs, previousOwners: previousOwners,
                                            alive: { deltas[$0] != nil }, budgetNs: unexplained - baseline)
                for (pid, ns) in exitCredit where sampler.unexplainedExitNs[pid] != nil {
                    sampler.addDebt(min(ns, sampler.unexplainedExitNs[pid] ?? 0), to: pid)
                }
            }
        }

        // This interval's work per process, then the window.
        if let deltas, elapsed > 0 {
            var work: [ProcessKey: Work] = [:]
            work.reserveCapacity(processes.count)
            var rowsNs = 0.0
            for p in processes {
                guard let d = deltas[p.pid] else { continue }
                let ns = Double(d.cpuNs - d.childCreditNs) + Double(d.childCreditNs) * creditScale
                let nj = metric == .energy
                    ? Double(d.energyNj - d.childCreditEnergyNj) + Double(d.childCreditEnergyNj) * creditScale : 0
                work[ProcessKey(pid: p.pid, startTime: p.startTime)] =
                    Work(app: owners[p.pid] ?? BreakdownGroup.otherProcesses, ns: ns, nj: nj)
                rowsNs += ns
            }
            // Exit credit is work by processes that are gone, so it gets its own child row in the
            // app the credited process belongs to instead of landing on a live process: credited
            // to the app's main process, an idle VS Code read 79 % of one core after an orphaned
            // `yes` was killed, on the very row someone would Force Quit.
            var exitedNs: [Int32: Double] = [:]
            for (pid, ns) in exitCredit {
                exitedNs[owners[pid] ?? BreakdownGroup.otherProcesses, default: 0] += Double(ns)
                rowsNs += Double(ns)
            }
            if metric == .cpu, let total {
                // Exit credit's baseline: System over this interval alone, not the window.
                lastSystemPercent = max(0, total - rowsNs / nsPerPercent)
            }
            // Fast attack: when this interval was much busier than the rest of the window (a new
            // load), the window restarts from it, so rows and header show the load at once instead of
            // ramping up over the window (a one-core load read 3, 6, 9 then 12 % over 8 s while the
            // CPU card showed it within 2 s). It regrows by one interval a scan. Falls still average.
            if fastAttack, let total, !window.isEmpty, window.allSatisfy({ $0.busyNs != nil }) {
                let restSpan = window.reduce(0) { $0 + $1.elapsed }
                let rest = window.reduce(0) { $0 + ($1.busyNs ?? 0) } * 100 / (restSpan * cores * 1_000_000_000)
                if total - rest >= breakdownFastAttackCores * 100 / cores { window = [] }
            }
            window.append(Interval(elapsed: elapsed, busyNs: total.map { $0 * nsPerPercent }, work: work,
                                   exitedNs: exitedNs))
            // Keep the newest intervals that cover the window (10 % slack for timer jitter).
            let span = metric == .memory ? 0
                : windowSeconds ?? (metric == .energy ? energyWindowSeconds : trailingWindowSeconds)
            var covered = window.reduce(0) { $0 + $1.elapsed }
            while window.count > 1, covered - window[0].elapsed >= span * 0.9 {
                covered -= window[0].elapsed
                window.removeFirst()
            }
        } else {
            window = []
        }

        // Sums over the window. Processes that exited mid-window go to their app's "Exited
        // processes" row while that app still has processes; otherwise they fall into System.
        let span = window.reduce(0) { $0 + $1.elapsed }
        let alive = window.last?.work ?? [:]
        var ns: [ProcessKey: Double] = [:], nj: [ProcessKey: Double] = [:]
        var exitedNs: [Int32: Double] = [:], exitedNj: [Int32: Double] = [:]
        for interval in window {
            for (key, w) in interval.work {
                if alive[key] != nil {
                    ns[key, default: 0] += w.ns
                    if w.nj > 0 { nj[key, default: 0] += w.nj }
                } else {
                    exitedNs[w.app, default: 0] += w.ns
                    exitedNj[w.app, default: 0] += w.nj
                }
            }
            for (app, credit) in interval.exitedNs { exitedNs[app, default: 0] += credit }
        }
        let windowTotal: Double? = window.isEmpty || window.contains { $0.busyNs == nil } ? nil
            : window.reduce(0) { $0 + ($1.busyNs ?? 0) } / (span * cores * 1_000_000_000) * 100
        let percentPerNs = span > 0 ? 100 / (span * cores * 1_000_000_000) : 0

        var usages: [ProcessUsage] = []
        usages.reserveCapacity(processes.count + exitedNs.count)
        var liveApps = Set<Int32>()
        var liveNames: [ProcessKey: String] = [:]
        liveNames.reserveCapacity(processes.count)
        for p in processes {
            let key = ProcessKey(pid: p.pid, startTime: p.startTime)
            let app = owners[p.pid] ?? BreakdownGroup.otherProcesses
            liveApps.insert(app)
            let name = names[key] ?? nameOf(p.pid)
            liveNames[key] = name
            usages.append(ProcessUsage(pid: p.pid, appPID: app, cpuPercent: (ns[key] ?? 0) * percentPerNs,
                                       memoryBytes: p.memoryBytes,
                                       watts: span > 0 ? (nj[key] ?? 0) / 1_000_000_000 / span : 0,
                                       startTime: p.startTime, name: name))
        }
        names = liveNames
        for (app, exited) in exitedNs where liveApps.contains(app) {
            let watts = span > 0 ? (exitedNj[app] ?? 0) / 1_000_000_000 / span : 0
            guard exited > 0 || watts > 0 else { continue }
            usages.append(ProcessUsage(pid: BreakdownGroup.exitedProcesses, appPID: app,
                                       cpuPercent: exited * percentPerNs, memoryBytes: 0, watts: watts))
        }

        let measuring = metric != .memory && deltas == nil
        var apps = aggregate(usages, by: metric)
        if metric == .cpu, !measuring, let windowTotal {
            apps = addingSystemRow(to: apps, totalCPUPercent: windowTotal)
        }
        return Result(apps: apps, totalCPUPercent: measuring ? nil : windowTotal, measuring: measuring)
    }
}

/// Credit for work done since the last scan by processes that have exited and that no
/// reap explains: a job killed by a subshell that then exited (its `yes` processes were
/// reaped by launchd), or a process already handed to launchd. That work can't be read, so it
/// fell into the System row: live, 380 % of one core of the user's own `yes` processes showed
/// as System for one scan. Each candidate is an upper bound (its last-interval rate × this
/// interval); together they get at most `budgetNs`, the part of the unattributed remainder
/// above the System row's previous level, shared out in proportion. So System keeps its
/// usual level, and nothing is credited when the remainder didn't grow.
///
/// - `unexplained`: surviving ancestor pid → its vanished descendants' candidate work.
/// - `orphans`: vanished pid with no surviving ancestor → candidate work, credited to the app
///   it belonged to (`previousOwners`), keyed by the app's main process, if that is still `alive`.
/// Returns surviving pid → ns credited on its behalf. `BreakdownScanner` shows it in that
/// process's app as an "Exited processes" child row, not on the process itself.
public func exitWorkCredit(unexplained: [Int32: UInt64], orphans: [Int32: UInt64],
                           previousOwners: [Int32: Int32], alive: (Int32) -> Bool,
                           budgetNs: Double) -> [Int32: UInt64] {
    var targets = unexplained
    for (pid, ns) in orphans {
        guard let owner = previousOwners[pid], owner > 0, alive(owner) else { continue }
        targets[owner, default: 0] += ns
    }
    let need = targets.values.reduce(0.0) { $0 + Double($1) }
    guard need > 0, budgetNs > 0 else { return [:] }
    let scale = min(1, budgetNs / need)
    var credit: [Int32: UInt64] = [:]
    for (pid, ns) in targets {
        let c = UInt64(Double(ns) * scale)
        if c > 0 { credit[pid] = c }
    }
    return credit
}
