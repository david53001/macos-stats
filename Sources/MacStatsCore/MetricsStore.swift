import Foundation
import Combine

/// The single source of truth the UI binds to. Holds the latest sample of each
/// metric plus a bounded history for sparklines. Main-actor isolated (UI state).
@MainActor
public final class MetricsStore: ObservableObject {
    @Published public private(set) var cpuPercent: Double = 0
    @Published public private(set) var memory: MemorySample?
    @Published public private(set) var network: NetworkSample?
    @Published public private(set) var battery: BatterySample?

    @Published public private(set) var cpuHistory: [SamplePoint] = []      // percent 0...100
    @Published public private(set) var memHistory: [SamplePoint] = []      // used fraction 0...1
    @Published public private(set) var netDownHistory: [SamplePoint] = []  // bytes/sec

    @Published public private(set) var trashBytes: UInt64?

    @Published public private(set) var cpuTempCelsius: Double?

    @Published public private(set) var breakdown: [AppUsage] = []
    @Published public private(set) var breakdownMeasuring: Bool = false
    @Published public private(set) var activeBreakdownMetric: BreakdownMetric?

    private var cpuBuf: RingBuffer<SamplePoint>
    private var memBuf: RingBuffer<SamplePoint>
    private var netBuf: RingBuffer<SamplePoint>

    public init(historyCapacity: Int = 60) {
        cpuBuf = RingBuffer(capacity: historyCapacity)
        memBuf = RingBuffer(capacity: historyCapacity)
        netBuf = RingBuffer(capacity: historyCapacity)
    }

    public func update(cpuPercent: Double, memory: MemorySample?, network: NetworkSample?,
                       battery: BatterySample?, cpuTemp: Double? = nil,
                       time: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.network = network
        self.battery = battery
        self.cpuTempCelsius = cpuTemp
        cpuBuf.append(SamplePoint(time: time, value: cpuPercent)); cpuHistory = cpuBuf.values
        if let memory {
            memBuf.append(SamplePoint(time: time, value: memory.usedFraction)); memHistory = memBuf.values
        }
        if let network {
            netBuf.append(SamplePoint(time: time, value: network.downBytesPerSec)); netDownHistory = netBuf.values
        }
    }

    /// Publishes the latest Trash size (bytes). `nil` means "not yet read / unreadable" —
    /// kept distinct from `0` ("empty"). Set off the main tick because the Trash is read via
    /// Finder (`~/.Trash` is TCC-protected), not on the per-second collection path.
    public func setTrashBytes(_ bytes: UInt64?) {
        trashBytes = bytes
    }

    /// Clears the latest sample and all history. Called when the popover closes so
    /// each open session builds a fresh sparkline rather than showing stale points.
    public func reset() {
        cpuPercent = 0
        memory = nil
        network = nil
        battery = nil

        cpuBuf = RingBuffer(capacity: cpuBuf.capacity); cpuHistory = []
        memBuf = RingBuffer(capacity: memBuf.capacity); memHistory = []
        netBuf = RingBuffer(capacity: netBuf.capacity); netDownHistory = []

        trashBytes = nil
        cpuTempCelsius = nil

        clearBreakdown()
    }

    /// Enter a drill-in for `metric`. CPU starts in the "measuring" state (it needs two
    /// samples for a delta); memory is instantaneous so it isn't.
    public func beginBreakdown(metric: BreakdownMetric) {
        activeBreakdownMetric = metric
        breakdown = []
        breakdownMeasuring = (metric == .cpu)
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
