import Foundation
import Combine

/// The single source of truth the UI binds to. Holds the latest sample of each
/// metric plus a time-bounded history for sparklines. Main-actor isolated (UI state).
///
/// History is never wiped on popover close: the idle sampler keeps appending (every 10s), so
/// an open shows the last minute immediately. Each metric has its own setter so a sampler
/// that doesn't read battery/temperature can't clobber them.
@MainActor
public final class MetricsStore: ObservableObject {
    @Published public private(set) var cpuPercent: Double = 0
    @Published public private(set) var memory: MemorySample?
    @Published public private(set) var network: NetworkSample?
    @Published public private(set) var battery: BatterySample?
    /// Gauge readings behind the Battery drill-in (power, health, temperature).
    @Published public private(set) var batteryTelemetry: BatteryTelemetry?
    /// Whole-Mac draw averaged over the last gauge interval (~1 min), W.
    @Published public private(set) var batteryPowerWatts: Double?
    /// Mean whole-Mac draw since unplugging (W); nil unless on battery with data.
    @Published public private(set) var batteryAverageWatts: Double?
    /// False when MacStats started on battery, so the average only covers the time since then.
    @Published public private(set) var batteryAverageSinceUnplug = false

    /// What the overview cards print: the readings above, held (`heldValue` step 1 %,
    /// `heldMemory`, `heldRate`) so a value on a rounding boundary doesn't flip every tick.
    /// The readings, histories and alerts keep the exact values. Set only when they change.
    @Published public private(set) var cardCPUPercent: Double = 0
    @Published public private(set) var cardMemory: MemorySample?
    @Published public private(set) var cardNetwork: NetworkSample?

    @Published public private(set) var cpuHistory: [SamplePoint] = []      // percent 0...100
    @Published public private(set) var memHistory: [SamplePoint] = []      // used fraction 0...1
    @Published public private(set) var netDownHistory: [SamplePoint] = []  // bytes/sec

    @Published public private(set) var trashBytes: UInt64?
    /// Finder access was refused, so the Trash can't be read or emptied until it's allowed.
    @Published public private(set) var trashNeedsPermission = false

    @Published public private(set) var cpuTempCelsius: Double?

    @Published public private(set) var breakdown: [AppUsage] = []
    @Published public private(set) var breakdownMeasuring: Bool = false
    @Published public private(set) var activeBreakdownMetric: BreakdownMetric?
    /// Whole-machine CPU % over the same interval as the breakdown's rows (nil until the
    /// second scan), so the CPU breakdown's header and rows add up.
    @Published public private(set) var breakdownTotalCPU: Double?
    /// Bumped only when a publish changed the breakdown's app order, so the list can animate
    /// the (rare) real reorders and nothing else.
    @Published public private(set) var breakdownOrderRevision = 0
    /// The Battery breakdown's bar scale (W): sticky (`stickyUpperBound`), so a bar changes
    /// length only when its own row changes, not whenever the top row does.
    @Published public private(set) var breakdownEnergyScale: Double = 1
    /// The CPU breakdown's header, held like the CPU card (nil until the first measured total).
    @Published public private(set) var breakdownShownTotalCPU: Double?

    /// What the breakdown showed last, so the next scan can keep the order steady (diagnosis
    /// §5.2–5.4): app order and values, each app's process order and values, the freeze and pin
    /// the view reports, and the held (shown) row values. Reset by `beginBreakdown` / `clearBreakdown`.
    private var order: [Int32] = []
    private var lastValues: [Int32: Double] = [:]
    private var childOrder: [Int32: [Int32]] = [:]
    private var lastChildValues: [Int32: [Int32: Double]] = [:]
    private var pointerFrozen = false
    private var menuFrozen = false
    /// After the pointer leaves (or a menu closes), the first scan at or after this time unfreezes.
    private var unfreezeAt: TimeInterval?
    private var pinnedApp: Int32?
    private var energyScale: Double?
    private var shownApps: [Int32: Double] = [:]
    /// Keyed by app too: the "Exited processes" row's pid (-3) repeats across apps.
    private var shownProcesses: [ProcessRowKey: Double] = [:]
    private struct ProcessRowKey: Hashable {
        let app: Int32
        let pid: Int32
    }
    /// Rows kept in place while frozen although their app or process has ended (`isEnded`).
    private var endedApps: Set<Int32> = []
    private var endedProcesses: Set<ProcessRowKey> = []
    /// Each shown process row's start time, so a placeholder keeps its name (`AppInfoCache`).
    private var lastProcesses: [ProcessRowKey: UInt64] = [:]

    /// Asks the view whether the pointer is over the list right now (AppKit's pointer location),
    /// read once a scan. Hover events alone miss a pointer that hasn't moved: after the list
    /// appears under it, or after a context menu closes. Set by the breakdown view; reset on begin/clear.
    public var breakdownPointerProbe: (() -> Bool)?

    /// Seconds of history the sparklines span (newest point at the right edge).
    public let historyWindow: TimeInterval
    /// Hard cap on points per history, whatever their timestamps (safety net only — at the
    /// 0.5s open cadence the window holds ~121 points).
    public let maxHistoryPoints: Int

    /// While paused (popover closed), samples are kept here instead of being published.
    private var paused = false
    private var pending = Pending()
    /// Values recorded while paused. An outer nil = "not set since the pause"; for battery,
    /// telemetry, average watts and temperature an inner nil is a real value ("none").
    private struct Pending {
        var cpuPercent: Double?
        var memory: MemorySample?
        var network: NetworkSample?
        var cpuHistory: [SamplePoint]?
        var memHistory: [SamplePoint]?
        var netDownHistory: [SamplePoint]?
        var battery: BatterySample??
        var batteryTelemetry: BatteryTelemetry??
        var batteryPowerWatts: Double??
        var batteryAverageWatts: Double??
        var batteryAverageSinceUnplug: Bool?
        var cpuTempCelsius: Double??
    }

    public init(historyWindow: TimeInterval = 60, maxHistoryPoints: Int = 240) {
        precondition(historyWindow > 0 && maxHistoryPoints > 0, "history bounds must be > 0")
        self.historyWindow = historyWindow
        self.maxHistoryPoints = maxHistoryPoints
    }

    /// Stop publishing: samples are still recorded (history keeps growing), but no
    /// `@Published` property changes until `resumePublishing()`. Once the popover has been
    /// opened, MenuBarExtra keeps its views alive while closed, so every published sample made
    /// SwiftUI re-render the hidden popover: ~0.7–1.3 % of a core for good after one open.
    public func pausePublishing() {
        paused = true
    }

    /// Publishes everything recorded while paused at once (call before the popover's first
    /// frame, so it opens on current values), then publishes live again.
    public func resumePublishing() {
        guard paused else { return }
        paused = false
        let p = pending
        pending = Pending()
        if let v = p.cpuPercent { cpuPercent = v }
        if let v = p.memory { memory = v }
        if let v = p.network { network = v }
        if let v = p.cpuHistory { cpuHistory = v }
        if let v = p.memHistory { memHistory = v }
        if let v = p.netDownHistory { netDownHistory = v }
        if let v = p.battery { setBattery(v) }
        if let v = p.batteryTelemetry {
            setBatteryTelemetry(v, powerWatts: p.batteryPowerWatts ?? nil, averageWatts: p.batteryAverageWatts ?? nil,
                                averageSinceUnplug: p.batteryAverageSinceUnplug ?? false)
        }
        if let v = p.cpuTempCelsius { setCPUTemperature(v) }
        // The cards restart their hold from the latest reading.
        if let memory, let network {
            updateCards(cpuPercent: cpuPercent, memory: memory, network: network, restart: true)
        }
    }

    /// Records one sample of the cheap, every-tick metrics (latest values + history).
    /// Leaves battery and temperature untouched — those are read on slower tiers.
    public func record(cpuPercent: Double, memory: MemorySample, network: NetworkSample,
                       time: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        let cpuPoint = SamplePoint(time: time, value: cpuPercent)
        let memPoint = SamplePoint(time: time, value: memory.usedFraction)
        let netPoint = SamplePoint(time: time, value: network.downBytesPerSec)
        if paused {
            pending.cpuPercent = cpuPercent
            pending.memory = memory
            pending.network = network
            pending.cpuHistory = appending(pending.cpuHistory ?? cpuHistory, cpuPoint)
            pending.memHistory = appending(pending.memHistory ?? memHistory, memPoint)
            pending.netDownHistory = appending(pending.netDownHistory ?? netDownHistory, netPoint)
            return
        }
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.network = network
        cpuHistory = appending(cpuHistory, cpuPoint)
        memHistory = appending(memHistory, memPoint)
        netDownHistory = appending(netDownHistory, netPoint)
        updateCards(cpuPercent: cpuPercent, memory: memory, network: network, restart: false)
    }

    /// Sets the held card values from a reading; `restart` drops the hold (a fresh open).
    private func updateCards(cpuPercent: Double, memory: MemorySample, network: NetworkSample, restart: Bool) {
        // Band 1.0 (was 0.75): about half as many changes, within 1 pp of the reading.
        let cpu = heldValue(shown: restart ? nil : cardCPUPercent, value: cpuPercent, step: 1, band: 1.0)
        if cpu != cardCPUPercent { cardCPUPercent = cpu }
        let mem = heldMemory(shown: restart ? nil : cardMemory, value: memory)
        if mem != cardMemory { cardMemory = mem }
        let shownNet = restart ? nil : cardNetwork
        let net = NetworkSample(
            downBytesPerSec: heldRate(shown: shownNet?.downBytesPerSec, value: network.downBytesPerSec),
            upBytesPerSec: heldRate(shown: shownNet?.upBytesPerSec, value: network.upBytesPerSec))
        if net != cardNetwork { cardNetwork = net }
    }

    /// `nil` means "this Mac has no battery" (not "unchanged"). Time left and time to full are
    /// display-only, so they are held in place (`heldTimeLeft`, `heldTimeToFull`) while the
    /// state stays the same; a plug or unplug starts afresh.
    public func setBattery(_ battery: BatterySample?) {
        if paused { pending.battery = .some(battery); return }
        var shown = battery
        if var b = battery, let last = self.battery, last.state == b.state {
            b.timeToEmptyMinutes = b.timeToEmptyMinutes.map {
                heldTimeLeft(shown: last.timeToEmptyMinutes, minutes: $0)
            }
            b.timeToFullMinutes = b.timeToFullMinutes.map {
                heldTimeToFull(shown: last.timeToFullMinutes, minutes: $0)
            }
            shown = b
        }
        if shown != self.battery { self.battery = shown }
    }

    public func setBatteryTelemetry(_ telemetry: BatteryTelemetry?, powerWatts: Double?, averageWatts: Double?,
                                    averageSinceUnplug: Bool = false) {
        if paused {
            pending.batteryTelemetry = .some(telemetry)
            pending.batteryPowerWatts = .some(powerWatts)
            pending.batteryAverageWatts = .some(averageWatts)
            pending.batteryAverageSinceUnplug = averageSinceUnplug
            return
        }
        if telemetry != batteryTelemetry { batteryTelemetry = telemetry }
        if powerWatts != batteryPowerWatts { batteryPowerWatts = powerWatts }
        if averageWatts != batteryAverageWatts { batteryAverageWatts = averageWatts }
        if averageSinceUnplug != batteryAverageSinceUnplug { batteryAverageSinceUnplug = averageSinceUnplug }
    }

    /// `nil` means "no usable CPU sensor" (the card falls back to a label). Shown as a whole
    /// degree that changes only once the reading is a full degree away from it.
    public func setCPUTemperature(_ celsius: Double?) {
        if paused { pending.cpuTempCelsius = .some(celsius); return }
        let shown = celsius.map { heldValue(shown: cpuTempCelsius, value: $0, step: 1, band: 1.0) }
        if shown != cpuTempCelsius { cpuTempCelsius = shown }
    }

    private func appending(_ history: [SamplePoint], _ point: SamplePoint) -> [SamplePoint] {
        var h = history
        h.append(point)
        trimHistory(&h, window: historyWindow, maxCount: maxHistoryPoints)
        return h
    }

    /// Publishes the latest Trash size (bytes). `nil` means "not yet read / unreadable" —
    /// kept distinct from `0` ("empty"). Set off the main tick because the Trash is read via
    /// Finder (`~/.Trash` is TCC-protected), not on the per-second collection path.
    public func setTrashBytes(_ bytes: UInt64?) {
        trashBytes = bytes
    }

    public func setTrashNeedsPermission(_ needed: Bool) {
        if needed != trashNeedsPermission { trashNeedsPermission = needed }
    }

    /// Enter a drill-in for `metric`. CPU and energy start in the "measuring" state (they
    /// need two samples for a delta); memory is instantaneous so it isn't.
    public func beginBreakdown(metric: BreakdownMetric) {
        activeBreakdownMetric = metric
        breakdown = []
        breakdownMeasuring = (metric != .memory)
        breakdownTotalCPU = nil
        resetBreakdownDisplay()
    }

    /// Publish a fresh scan's grouped result for the active breakdown, in a steady order:
    /// apps (and each app's processes) re-rank only with a clear, two-reading lead
    /// (`stableRanking`); the order is frozen while the pointer is in the list or a context menu
    /// is open, and until the first scan `breakdownUnfreezeDelay` after both end; the expanded
    /// app keeps its index. Row values stay exact (bars follow them); the text reads
    /// `shownValue`, held within max(0.75 × the printed step, min(10 % (memory 3 %) of the value,
    /// 2 pp / 0.2 W)). While frozen, a row whose app or process ended stays in place as a
    /// placeholder (`isEnded`), so nothing below it moves; it goes at the unfreeze. An app's
    /// "Exited processes" row stays (at 0) once it has appeared, instead of coming and going.
    public func setBreakdown(_ apps: [AppUsage], measuring: Bool, totalCPU: Double? = nil,
                             time: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        if totalCPU != breakdownTotalCPU { breakdownTotalCPU = totalCPU }
        guard !measuring else {
            // CPU/energy "Measuring…": every value is 0, so there's nothing to rank or hold yet.
            breakdown = apps
            breakdownMeasuring = true
            return
        }
        let metric = activeBreakdownMetric ?? .cpu
        if let at = unfreezeAt, time >= at { unfreezeAt = nil }
        let frozen = pointerFrozen || menuFrozen || unfreezeAt != nil || breakdownPointerProbe?() == true
        let rule = RankHysteresis.for(metric)
        let relBand = metric == .memory ? 0.03 : 0.10
        let bandCap = metric == .cpu ? 2 : metric == .energy ? 0.2 : .infinity
        func hold(_ shown: Double?, _ value: Double) -> Double {
            heldValue(shown: shown, value: value, step: breakdownValueStep(metric, value), band: 0.75,
                      relBand: relBand, cap: bandCap)
        }
        func placeholder(_ pid: Int32, app: Int32) -> ProcessUsage {
            ProcessUsage(pid: pid, appPID: app, cpuPercent: 0, memoryBytes: 0,
                         startTime: lastProcesses[ProcessRowKey(app: app, pid: pid)] ?? 0)
        }

        var byApp = Dictionary(apps.map { ($0.appPID, $0) }, uniquingKeysWith: { a, _ in a })
        var nextEndedApps: Set<Int32> = []
        if frozen {
            for key in order where byApp[key] == nil {
                byApp[key] = AppUsage(appPID: key, processes: [], cpuPercent: 0, memoryBytes: 0)
                nextEndedApps.insert(key)
            }
        }
        var values: [Int32: Double] = [:]
        values.reserveCapacity(byApp.count)
        for (key, app) in byApp { values[key] = app.value(for: metric) }
        let newOrder = stableRanking(previous: order, now: values, before: lastValues, rule: rule,
                                     pinned: pinnedApp.map { [$0] } ?? [], frozen: frozen,
                                     groupsLast: metric == .memory)

        var ordered: [AppUsage] = []
        ordered.reserveCapacity(newOrder.count)
        var nextChildOrder: [Int32: [Int32]] = [:], nextChildValues: [Int32: [Int32: Double]] = [:]
        var nextShownApps: [Int32: Double] = [:], nextShownProcesses: [ProcessRowKey: Double] = [:]
        var nextEndedProcesses: Set<ProcessRowKey> = [], nextLastProcesses: [ProcessRowKey: UInt64] = [:]
        for key in newOrder {
            guard let app = byApp[key] else { continue }
            // Memory has nothing to say about exited processes (they hold no memory).
            var children = metric == .memory
                ? app.processes.filter { $0.pid != BreakdownGroup.exitedProcesses } : app.processes
            let previousKids = childOrder[key] ?? []
            if !nextEndedApps.contains(key) {
                let present = Set(children.map(\.pid))
                for pid in previousKids where !present.contains(pid) {
                    if pid == BreakdownGroup.exitedProcesses {
                        children.append(placeholder(pid, app: key))   // stays, at 0
                    } else if frozen {
                        children.append(placeholder(pid, app: key))
                        nextEndedProcesses.insert(ProcessRowKey(app: key, pid: pid))
                    }
                }
            }
            var childValues: [Int32: Double] = [:]
            childValues.reserveCapacity(children.count)
            for p in children { childValues[p.pid] = p.value(for: metric) }
            let kids = stableRanking(previous: previousKids, now: childValues,
                                     before: lastChildValues[key] ?? [:], rule: rule, frozen: frozen)
            let byPID = Dictionary(children.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            let processes = kids.compactMap { byPID[$0] }
            nextChildOrder[key] = kids
            nextChildValues[key] = childValues
            nextShownApps[key] = hold(shownApps[key], values[key] ?? 0)
            for p in processes {
                let rowKey = ProcessRowKey(app: key, pid: p.pid)
                nextShownProcesses[rowKey] = hold(shownProcesses[rowKey], p.value(for: metric))
                nextLastProcesses[rowKey] = p.startTime
            }
            ordered.append(AppUsage(appPID: app.appPID, processes: processes, cpuPercent: app.cpuPercent,
                                    memoryBytes: app.memoryBytes, watts: app.watts))
        }
        if newOrder != order { breakdownOrderRevision &+= 1 }
        order = newOrder
        lastValues = values
        childOrder = nextChildOrder
        lastChildValues = nextChildValues
        shownApps = nextShownApps
        shownProcesses = nextShownProcesses
        endedApps = nextEndedApps
        endedProcesses = nextEndedProcesses
        lastProcesses = nextLastProcesses

        if metric == .cpu, let totalCPU {
            let shown = heldValue(shown: breakdownShownTotalCPU, value: totalCPU, step: 1, band: 0.75)
            if shown != breakdownShownTotalCPU { breakdownShownTotalCPU = shown }
        }
        if metric == .energy {
            let scale = stickyUpperBound(previous: energyScale, peak: apps.map(\.watts).max() ?? 0)
            energyScale = scale
            if scale != breakdownEnergyScale { breakdownEnergyScale = scale }
        }
        breakdown = ordered
        breakdownMeasuring = false
    }

    /// The pointer entered (true) or left (false) the breakdown's list: the order freezes while
    /// it is inside, and until the first scan `breakdownUnfreezeDelay` after it leaves.
    public func setBreakdownPointerInside(_ inside: Bool,
                                          time: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        guard inside != pointerFrozen else { return }
        pointerFrozen = inside
        if !pointerFrozen, !menuFrozen { unfreezeAt = time + breakdownUnfreezeDelay }
    }

    /// A context menu opened (true) or closed (false): frozen like the pointer, so the menu's
    /// actions always apply to the row it was opened on.
    public func setBreakdownMenuOpen(_ open: Bool, time: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        guard open != menuFrozen else { return }
        menuFrozen = open
        if !pointerFrozen, !menuFrozen { unfreezeAt = time + breakdownUnfreezeDelay }
    }

    /// The expanded app (nil = none): it keeps its index while the other rows reorder.
    public func setBreakdownPinnedApp(_ appPID: Int32?) {
        pinnedApp = appPID
    }

    /// The held value to print for an app row, or for one of its process rows (`pid`). nil
    /// before the row's first real reading.
    public func shownValue(app: Int32, pid: Int32? = nil) -> Double? {
        guard let pid else { return shownApps[app] }
        return shownProcesses[ProcessRowKey(app: app, pid: pid)]
    }

    /// True for a row kept in place while frozen although its app (`pid` nil) or process ended:
    /// the view dims it and offers no actions.
    public func isEnded(app: Int32, pid: Int32? = nil) -> Bool {
        guard let pid else { return endedApps.contains(app) }
        return endedProcesses.contains(ProcessRowKey(app: app, pid: pid))
    }

    /// Leave the drill-in (back button or popover closed).
    public func clearBreakdown() {
        activeBreakdownMetric = nil
        breakdown = []
        breakdownMeasuring = false
        breakdownTotalCPU = nil
        resetBreakdownDisplay()
    }

    private func resetBreakdownDisplay() {
        order = []
        lastValues = [:]
        childOrder = [:]
        lastChildValues = [:]
        pointerFrozen = false
        menuFrozen = false
        unfreezeAt = nil
        pinnedApp = nil
        energyScale = nil
        shownApps = [:]
        shownProcesses = [:]
        endedApps = []
        endedProcesses = []
        lastProcesses = [:]
        breakdownPointerProbe = nil
        if breakdownEnergyScale != 1 { breakdownEnergyScale = 1 }
        if breakdownShownTotalCPU != nil { breakdownShownTotalCPU = nil }
    }
}
