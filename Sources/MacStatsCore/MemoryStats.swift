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

/// Approximates Activity Monitor's "memory used" as (active + wired + compressed).
/// NOTE: pressure here is a used-fraction heuristic; a real memory-pressure source
/// (DISPATCH_SOURCE_TYPE_MEMORYPRESSURE) is a later refinement.
public func memorySample(raw: VMRaw, totalBytes: UInt64) -> MemorySample {
    let used = (raw.active + raw.wired + raw.compressed) * raw.pageSize
    let frac = totalBytes > 0 ? Double(used) / Double(totalBytes) : 0
    let pressure: MemoryPressure = frac > 0.90 ? .critical : (frac > 0.75 ? .warning : .normal)
    return MemorySample(usedBytes: used, totalBytes: totalBytes, pressure: pressure)
}
