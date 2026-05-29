/// Cumulative CPU tick counts (since boot) in the four Mach CPU states.
public struct CPUTicks: Equatable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }

    public var total: UInt64 { UInt64(user) + UInt64(system) + UInt64(idle) + UInt64(nice) }
    public var busy: UInt64 { UInt64(user) + UInt64(system) + UInt64(nice) }
}

/// Busy CPU percentage (0...100) between two cumulative tick snapshots.
public func cpuBusyPercent(previous: CPUTicks, current: CPUTicks) -> Double {
    let totalDelta = Double(current.total) - Double(previous.total)
    guard totalDelta > 0 else { return 0 }
    let busyDelta = Double(current.busy) - Double(previous.busy)
    return max(0, min(100, busyDelta / totalDelta * 100))
}
