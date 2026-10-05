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
    /// The parts of `usedBytes`, as Activity Monitor's Memory tab lists them (App Memory +
    /// Wired Memory + Compressed = Memory Used). 0 when unknown.
    public var appBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    /// What the compressor holds before compression (`vm_stat`'s "Pages stored in
    /// compressor"): the size per-process footprints count it at. 0 if unknown.
    public var compressedDataBytes: UInt64

    public init(usedBytes: UInt64, totalBytes: UInt64, pressure: MemoryPressure, appBytes: UInt64 = 0,
                wiredBytes: UInt64 = 0, compressedBytes: UInt64 = 0, compressedDataBytes: UInt64 = 0) {
        self.usedBytes = usedBytes; self.totalBytes = totalBytes; self.pressure = pressure
        self.appBytes = appBytes; self.wiredBytes = wiredBytes; self.compressedBytes = compressedBytes
        self.compressedDataBytes = compressedDataBytes
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
/// Compressed, each kept as a part for the Memory breakdown. `active` isn't used: it includes
/// file cache (which macOS frees instantly when needed) and misses inactive app memory, so
/// (active + wired + compressed) was ±1 GB off.
/// Pressure comes from the kernel's real pressure level (see `memoryPressure(fromLevel:)`),
/// not a used-fraction heuristic.
public func memorySample(raw: VMRaw, totalBytes: UInt64, pressureLevel: Int) -> MemorySample {
    let appPages = raw.internal > raw.purgeable ? raw.internal - raw.purgeable : 0
    let app = appPages * raw.pageSize, wired = raw.wired * raw.pageSize
    let compressed = raw.compressed * raw.pageSize
    return MemorySample(usedBytes: app + wired + compressed, totalBytes: totalBytes,
                        pressure: memoryPressure(fromLevel: pressureLevel), appBytes: app, wiredBytes: wired,
                        compressedBytes: compressed, compressedDataBytes: raw.compressedOriginal * raw.pageSize)
}

/// Rounds `parts` to multiples of `step` (in the parts' unit after dividing by `unit`) so that
/// they add up to their rounded total, as shown next to each other (largest remainders get
/// the rounding up; ties go to the earlier part). Plain rounding can be off by 0.1–0.2: parts
/// of 6.16 + 1.66 + 2.66 = 10.48 GB read 6.2 + 1.7 + 2.7 = 10.6 under a "10.5 GB" header.
public func roundedParts(_ parts: [UInt64], unit: Double, step: Double = 0.1) -> [Double] {
    guard unit > 0, step > 0 else { return parts.map { _ in 0 } }
    let scaled = parts.map { Double($0) / unit / step }
    let target = Int((scaled.reduce(0, +)).rounded())
    var floors = scaled.map { Int($0.rounded(.down)) }
    let order = scaled.indices.sorted {
        let a = scaled[$0] - Double(floors[$0]), b = scaled[$1] - Double(floors[$1])
        return a != b ? a > b : $0 < $1
    }
    var missing = target - floors.reduce(0, +)
    for i in order where missing > 0 {
        floors[i] += 1
        missing -= 1
    }
    return floors.map { Double($0) * step }
}
