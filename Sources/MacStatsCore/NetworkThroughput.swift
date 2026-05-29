/// Cumulative interface byte counters (since boot).
public struct NetCounters: Equatable {
    public var rxBytes: UInt64
    public var txBytes: UInt64
    public init(rxBytes: UInt64, txBytes: UInt64) {
        self.rxBytes = rxBytes; self.txBytes = txBytes
    }
}

public struct NetworkSample: Equatable {
    public var downBytesPerSec: Double
    public var upBytesPerSec: Double
    public init(downBytesPerSec: Double, upBytesPerSec: Double) {
        self.downBytesPerSec = downBytesPerSec; self.upBytesPerSec = upBytesPerSec
    }
}

/// Throughput between two cumulative counter samples. Clamps to 0 if a counter
/// went backwards (interface reset) or no time elapsed.
public func networkThroughput(previous: NetCounters, current: NetCounters, secondsElapsed: Double) -> NetworkSample {
    guard secondsElapsed > 0 else { return NetworkSample(downBytesPerSec: 0, upBytesPerSec: 0) }
    let down = current.rxBytes >= previous.rxBytes ? Double(current.rxBytes - previous.rxBytes) : 0
    let up   = current.txBytes >= previous.txBytes ? Double(current.txBytes - previous.txBytes) : 0
    return NetworkSample(downBytesPerSec: down / secondsElapsed, upBytesPerSec: up / secondsElapsed)
}
