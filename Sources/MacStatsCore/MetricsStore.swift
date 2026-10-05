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
    /// Mean whole-Mac draw since unplugging (W); nil unless on battery with data.
    @Published public private(set) var batteryAverageWatts: Double?

    @Published public private(set) var cpuHistory: [SamplePoint] = []      // percent 0...100
    @Published public private(set) var memHistory: [SamplePoint] = []      // used fraction 0...1
    @Published public private(set) var netDownHistory: [SamplePoint] = []  // bytes/sec

    @Published public private(set) var trashBytes: UInt64?

    @Published public private(set) var cpuTempCelsius: Double?

    @Published public private(set) var breakdown: [AppUsage] = []
    @Published public private(set) var breakdownMeasuring: Bool = false
    @Published public private(set) var activeBreakdownMetric: BreakdownMetric?
    /// Whole-machine CPU % over the same interval as the breakdown's rows (nil until the
    /// second scan), so the CPU breakdown's header and rows add up.
    @Published public private(set) var breakdownTotalCPU: Double?

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
        var batteryAverageWatts: Double??
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
        if let v = p.batteryTelemetry { setBatteryTelemetry(v, averageWatts: p.batteryAverageWatts ?? nil) }
        if let v = p.cpuTempCelsius { setCPUTemperature(v) }
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
    }

    /// `nil` means "this Mac has no battery" (not "unchanged").
    public func setBattery(_ battery: BatterySample?) {
        if paused { pending.battery = .some(battery); return }
        if battery != self.battery { self.battery = battery }
    }

    public func setBatteryTelemetry(_ telemetry: BatteryTelemetry?, averageWatts: Double?) {
        if paused {
            pending.batteryTelemetry = .some(telemetry)
            pending.batteryAverageWatts = .some(averageWatts)
            return
        }
        if telemetry != batteryTelemetry { batteryTelemetry = telemetry }
        if averageWatts != batteryAverageWatts { batteryAverageWatts = averageWatts }
    }

    /// `nil` means "no usable CPU sensor" (the card falls back to a label).
    public func setCPUTemperature(_ celsius: Double?) {
        if paused { pending.cpuTempCelsius = .some(celsius); return }
        cpuTempCelsius = celsius
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

    /// Enter a drill-in for `metric`. CPU and energy start in the "measuring" state (they
    /// need two samples for a delta); memory is instantaneous so it isn't.
    public func beginBreakdown(metric: BreakdownMetric) {
        activeBreakdownMetric = metric
        breakdown = []
        breakdownMeasuring = (metric != .memory)
        breakdownTotalCPU = nil
    }

    /// Publish a fresh scan's grouped result for the active breakdown.
    public func setBreakdown(_ apps: [AppUsage], measuring: Bool, totalCPU: Double? = nil) {
        breakdown = apps
        breakdownMeasuring = measuring
        if totalCPU != breakdownTotalCPU { breakdownTotalCPU = totalCPU }
    }

    /// Leave the drill-in (back button or popover closed).
    public func clearBreakdown() {
        activeBreakdownMetric = nil
        breakdown = []
        breakdownMeasuring = false
        breakdownTotalCPU = nil
    }
}
