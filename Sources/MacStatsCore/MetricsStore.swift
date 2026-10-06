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

    /// What the overview cards print: the readings above, held (`heldValue` step 1 %, band 1.25,
    /// `heldMemory`, `heldRate`) so a value on a rounding boundary doesn't flip every tick, and
    /// CPU and network shown for at least `cardDwellSeconds` unless the reading jumps (`dwellAllows`).
    /// The readings, histories and alerts keep the exact values. Set only when they change.
    @Published public private(set) var cardCPUPercent: Double = 0
    @Published public private(set) var cardMemory: MemorySample?
    @Published public private(set) var cardNetwork: NetworkSample?
    /// When each dwelled card value last changed (nil after a restart: no wait).
    private var cardCPUChangedAt: TimeInterval?
    private var cardDownChangedAt: TimeInterval?
    private var cardUpChangedAt: TimeInterval?

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
    /// What a full bar stands for in the CPU (%) and Battery (W) breakdowns (`BreakdownDisplay.barScale`).
    @Published public private(set) var breakdownBarScale: Double = 1
    /// The CPU breakdown's header, held like the CPU card (nil until the first measured total).
    @Published public private(set) var breakdownShownTotalCPU: Double?

    /// The breakdown as shown and what keeps it steady (order, holds, placeholders, freeze).
    /// Replaced by `beginBreakdown` / `clearBreakdown`.
    private var display = BreakdownDisplay(metric: .cpu)

    /// Asks the view where the pointer is (AppKit's pointer location), read once a scan. Hover
    /// events alone miss a pointer that hasn't moved since a context menu closed. Set by the
    /// breakdown view; reset on begin/clear.
    public var breakdownPointerProbe: (() -> BreakdownPointer)?

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
            updateCards(cpuPercent: cpuPercent, memory: memory, network: network, time: 0, restart: true)
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
        updateCards(cpuPercent: cpuPercent, memory: memory, network: network, time: time, restart: false)
    }

    /// Sets the held card values from a reading; `restart` drops the hold and the dwell (a fresh open).
    private func updateCards(cpuPercent: Double, memory: MemorySample, network: NetworkSample,
                             time: TimeInterval, restart: Bool) {
        if restart { cardCPUChangedAt = nil; cardDownChangedAt = nil; cardUpChangedAt = nil }
        // Within 1.25 pp of the reading; a move of 3 pp or more shows at once (2 pp let bursty
        // load skip the dwell: about one change every 1.5 s).
        let cpu = heldValue(shown: restart ? nil : cardCPUPercent, value: cpuPercent, step: 1, band: 1.25)
        if cpu != cardCPUPercent,
           restart || dwellAllows(since: cardCPUChangedAt, now: time, bigMove: abs(cpuPercent - cardCPUPercent) >= 3) {
            cardCPUPercent = cpu
            if !restart { cardCPUChangedAt = time }
        }
        let mem = heldMemory(shown: restart ? nil : cardMemory, value: memory)
        if mem != cardMemory { cardMemory = mem }
        let shownNet = restart ? nil : cardNetwork
        let down = dwelledRate(shown: shownNet?.downBytesPerSec, value: network.downBytesPerSec,
                               since: &cardDownChangedAt, time: time)
        let up = dwelledRate(shown: shownNet?.upBytesPerSec, value: network.upBytesPerSec,
                             since: &cardUpChangedAt, time: time)
        let net = NetworkSample(downBytesPerSec: down, upBytesPerSec: up)
        if net != cardNetwork { cardNetwork = net }
    }

    /// `heldRate` plus the dwell; a big move (the rate doubled or halved, by 10 KB/s or more) shows at once.
    private func dwelledRate(shown: Double?, value: Double, since: inout TimeInterval?, time: TimeInterval) -> Double {
        let next = heldRate(shown: shown, value: value)
        guard let shown, next != shown else { return next }
        let big = max(value, shown) >= 2 * min(value, shown) && abs(value - shown) >= 10_000
        guard dwellAllows(since: since, now: time, bigMove: big) else { return shown }
        since = time
        return next
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
        resetBreakdownDisplay(metric)
    }

    /// Publish a fresh scan's grouped result for the active breakdown, in a steady order with held
    /// text (`BreakdownDisplay` has the rules).
    public func setBreakdown(_ apps: [AppUsage], measuring: Bool, totalCPU: Double? = nil,
                             time: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        if totalCPU != breakdownTotalCPU { breakdownTotalCPU = totalCPU }
        guard !measuring else {
            // CPU/energy "Measuring…": every value is 0, so there's nothing to rank or hold yet.
            breakdown = apps
            breakdownMeasuring = true
            return
        }
        let freeze = display.freeze(at: time, pointer: breakdownPointerProbe?())
        if display.apply(apps, totalCPU: totalCPU, freeze: freeze, time: time) { breakdownOrderRevision &+= 1 }
        if display.shownTotalCPU != breakdownShownTotalCPU { breakdownShownTotalCPU = display.shownTotalCPU }
        let scale = display.barScale ?? 1
        if scale != breakdownBarScale { breakdownBarScale = scale }
        breakdown = display.apps
        breakdownMeasuring = false
    }

    /// The pointer entered (true) or left (false) the breakdown's list: the order freezes while
    /// it is inside, and until the first scan `breakdownUnfreezeDelay` after it leaves.
    public func setBreakdownPointerInside(_ inside: Bool,
                                          time: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        display.setPointerInside(inside, time: time)
    }

    /// A context menu opened (true) or closed (false): frozen like the pointer, so the menu's
    /// actions always apply to the row it was opened on.
    public func setBreakdownMenuOpen(_ open: Bool, time: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        display.setMenuOpen(open, time: time)
    }

    /// The held value to print for an app row, or for one of its process rows (`pid`). nil
    /// before the row's first real reading.
    public func shownValue(app: Int32, pid: Int32? = nil) -> Double? {
        display.shownValue(app: app, pid: pid)
    }

    /// True for a row kept in place while frozen although its app (`pid` nil) or process ended:
    /// the view dims it and offers no actions.
    public func isEnded(app: Int32, pid: Int32? = nil) -> Bool {
        display.isEnded(app: app, pid: pid)
    }

    /// Leave the drill-in (back button or popover closed).
    public func clearBreakdown() {
        activeBreakdownMetric = nil
        breakdown = []
        breakdownMeasuring = false
        breakdownTotalCPU = nil
        resetBreakdownDisplay(.cpu)
    }

    private func resetBreakdownDisplay(_ metric: BreakdownMetric) {
        display = BreakdownDisplay(metric: metric, shownTotalCPU: cardCPUPercent)
        breakdownPointerProbe = nil
        if breakdownBarScale != 1 { breakdownBarScale = 1 }
        if breakdownShownTotalCPU != nil { breakdownShownTotalCPU = nil }
    }
}
