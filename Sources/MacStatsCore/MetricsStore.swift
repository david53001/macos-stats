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

    @Published public private(set) var cpuHistory: [Double] = []      // percent 0...100
    @Published public private(set) var memHistory: [Double] = []      // used fraction 0...1
    @Published public private(set) var netDownHistory: [Double] = []  // bytes/sec

    private var cpuBuf: RingBuffer<Double>
    private var memBuf: RingBuffer<Double>
    private var netBuf: RingBuffer<Double>

    public init(historyCapacity: Int = 60) {
        cpuBuf = RingBuffer(capacity: historyCapacity)
        memBuf = RingBuffer(capacity: historyCapacity)
        netBuf = RingBuffer(capacity: historyCapacity)
    }

    public func update(cpuPercent: Double, memory: MemorySample?, network: NetworkSample?, battery: BatterySample?) {
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.network = network
        self.battery = battery

        cpuBuf.append(cpuPercent); cpuHistory = cpuBuf.values
        if let memory { memBuf.append(memory.usedFraction); memHistory = memBuf.values }
        if let network { netBuf.append(network.downBytesPerSec); netDownHistory = netBuf.values }
    }
}
