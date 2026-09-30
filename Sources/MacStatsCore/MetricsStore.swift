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
    /// The draw the time-left estimate assumes (W); nil unless on battery with data.
    @Published public private(set) var batteryExpectedWatts: Double?

    @Published public private(set) var cpuHistory: [SamplePoint] = []      // percent 0...100
    @Published public private(set) var memHistory: [SamplePoint] = []      // used fraction 0...1
    @Published public private(set) var netDownHistory: [SamplePoint] = []  // bytes/sec

    @Published public private(set) var trashBytes: UInt64?

    @Published public private(set) var cpuTempCelsius: Double?

    @Published public private(set) var breakdown: [AppUsage] = []
    @Published public private(set) var breakdownMeasuring: Bool = false
    @Published public private(set) var activeBreakdownMetric: BreakdownMetric?

    /// Seconds of history the sparklines span (newest point at the right edge).
    public let historyWindow: TimeInterval
    /// Hard cap on points per history, whatever their timestamps (safety net only — at the
    /// 0.5s open cadence the window holds ~121 points).
    public let maxHistoryPoints: Int

    public init(historyWindow: TimeInterval = 60, maxHistoryPoints: Int = 240) {
        precondition(historyWindow > 0 && maxHistoryPoints > 0, "history bounds must be > 0")
        self.historyWindow = historyWindow
        self.maxHistoryPoints = maxHistoryPoints
    }

    /// Records one sample of the cheap, every-tick metrics (latest values + history).
    /// Leaves battery and temperature untouched — those are read on slower tiers.
    public func record(cpuPercent: Double, memory: MemorySample, network: NetworkSample,
                       time: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.network = network
        cpuHistory = appending(cpuHistory, SamplePoint(time: time, value: cpuPercent))
        memHistory = appending(memHistory, SamplePoint(time: time, value: memory.usedFraction))
        netDownHistory = appending(netDownHistory, SamplePoint(time: time, value: network.downBytesPerSec))
    }

    /// `nil` means "this Mac has no battery" (not "unchanged").
    public func setBattery(_ battery: BatterySample?) {
        if battery != self.battery { self.battery = battery }
    }

    public func setBatteryTelemetry(_ telemetry: BatteryTelemetry?, expectedWatts: Double?) {
        if telemetry != batteryTelemetry { batteryTelemetry = telemetry }
        if expectedWatts != batteryExpectedWatts { batteryExpectedWatts = expectedWatts }
    }

    /// `nil` means "no usable CPU sensor" (the card falls back to a label).
    public func setCPUTemperature(_ celsius: Double?) {
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
    }

    /// Publish a fresh scan's grouped result for the active breakdown.
    public func setBreakdown(_ apps: [AppUsage], measuring: Bool) {
        breakdown = apps
        breakdownMeasuring = measuring
    }

    /// Leave the drill-in (back button or popover closed).
    public func clearBreakdown() {
        activeBreakdownMetric = nil
        breakdown = []
        breakdownMeasuring = false
    }
}
