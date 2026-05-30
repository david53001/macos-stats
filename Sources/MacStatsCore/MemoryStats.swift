/// Raw VM page counts from the kernel (counts are in pages; multiply by pageSize for bytes).
public struct VMRaw: Equatable {
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var pageSize: UInt64

    public init(free: UInt64, active: UInt64, inactive: UInt64, wired: UInt64, compressed: UInt64, pageSize: UInt64) {
        self.free = free; self.active = active; self.inactive = inactive
        self.wired = wired; self.compressed = compressed; self.pageSize = pageSize
    }
}

public enum MemoryPressure: Equatable { case normal, warning, critical }

public struct MemorySample: Equatable {
    public var usedBytes: UInt64
    public var totalBytes: UInt64
    public var pressure: MemoryPressure

    public init(usedBytes: UInt64, totalBytes: UInt64, pressure: MemoryPressure) {
        self.usedBytes = usedBytes; self.totalBytes = totalBytes; self.pressure = pressure
    }

    public var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }
}

/// Maps the kernel's `kern.memorystatus_vm_pressure_level` to our enum.
public func memoryPressure(fromLevel level: Int) -> MemoryPressure {
    switch level {
    case 2: return .warning
    case 4: return .critical
    default: return .normal   // 1 (normal) and anything unexpected
    }
}

/// Approximates Activity Monitor's "memory used" as (active + wired + compressed).
/// Pressure comes from the kernel's real pressure level (see `memoryPressure(fromLevel:)`),
/// not a used-fraction heuristic.
public func memorySample(raw: VMRaw, totalBytes: UInt64, pressureLevel: Int) -> MemorySample {
    let used = (raw.active + raw.wired + raw.compressed) * raw.pageSize
    return MemorySample(usedBytes: used, totalBytes: totalBytes,
                        pressure: memoryPressure(fromLevel: pressureLevel))
}
