/// Raw VM page counts from the kernel (counts are in pages; multiply by pageSize for bytes).
public struct VMRaw: Equatable {
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var wired: UInt64
    public var compressed: UInt64   // pages the compressor occupies (Activity Monitor's "Compressed")
    public var `internal`: UInt64   // anonymous (non-file) pages, active or inactive
    public var purgeable: UInt64    // anonymous pages apps marked as freeable on demand
    public var pageSize: UInt64
    /// What the compressor holds, counted before compression (`vm_stat`'s "Pages stored in
    /// compressor"); 0 if unknown.
    public var compressedOriginal: UInt64

    public init(free: UInt64, active: UInt64, inactive: UInt64, wired: UInt64, compressed: UInt64,
                internal: UInt64, purgeable: UInt64, pageSize: UInt64, compressedOriginal: UInt64 = 0) {
        self.free = free; self.active = active; self.inactive = inactive
        self.wired = wired; self.compressed = compressed
        self.internal = `internal`; self.purgeable = purgeable; self.pageSize = pageSize
        self.compressedOriginal = compressedOriginal
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

/// Activity Monitor's "Memory Used": App Memory (anonymous pages minus purgeable) + Wired +
/// Compressed. `active` isn't used: it includes file cache (which macOS frees instantly when
/// needed) and misses inactive app memory, so (active + wired + compressed) was ±1 GB off.
/// Pressure comes from the kernel's real pressure level (see `memoryPressure(fromLevel:)`),
/// not a used-fraction heuristic.
public func memorySample(raw: VMRaw, totalBytes: UInt64, pressureLevel: Int) -> MemorySample {
    let appPages = raw.internal > raw.purgeable ? raw.internal - raw.purgeable : 0
    let used = (appPages + raw.wired + raw.compressed) * raw.pageSize
    return MemorySample(usedBytes: used, totalBytes: totalBytes,
                        pressure: memoryPressure(fromLevel: pressureLevel))
}

/// "Memory Used" with compressed memory counted at its original size, the way per-process
/// footprints (the Memory breakdown's rows) count it. The breakdown's "System & other" row is
/// this minus the rows. Plain Memory Used − rows isn't usable: on this Mac (16 GB, 7.5 GB of
/// data compressed into 3.0 GB) it read 0.3 GB, less than the 1.6 GB of wired memory alone,
/// and the reviewers saw rows > Memory Used.
public func memoryInUseAtFullSize(_ raw: VMRaw) -> UInt64 {
    let appPages = raw.internal > raw.purgeable ? raw.internal - raw.purgeable : 0
    return (appPages + raw.wired + max(raw.compressed, raw.compressedOriginal)) * raw.pageSize
}
