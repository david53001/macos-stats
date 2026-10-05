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
/// The kernel's counters are 32-bit and wrap: the idle count (~800 ticks/s on 8 cores) does so
/// after ~60 days of uptime, so each field's delta uses wrapping subtraction.
public func cpuBusyPercent(previous: CPUTicks, current: CPUTicks) -> Double {
    let user = Double(current.user &- previous.user)
    let system = Double(current.system &- previous.system)
    let idle = Double(current.idle &- previous.idle)
    let nice = Double(current.nice &- previous.nice)
    let totalDelta = user + system + idle + nice
    guard totalDelta > 0 else { return 0 }
    return max(0, min(100, (user + system + nice) / totalDelta * 100))
}
