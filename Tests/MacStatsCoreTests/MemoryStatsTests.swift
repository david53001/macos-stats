import Testing
@testable import MacStatsCore

@Suite struct MemoryStatsTests {
    /// Activity Monitor's "Memory Used" = App Memory (anonymous pages minus purgeable) + Wired
    /// + Compressed. Active/inactive don't enter it: they mix file cache with app memory.
    @Test func usedIsAppMemoryPlusWiredPlusCompressed() {
        let raw = VMRaw(free: 100, active: 30, inactive: 20, wired: 10, compressed: 5,
                        internal: 40, purgeable: 5, pageSize: 1)
        let s = memorySample(raw: raw, totalBytes: 200, pressureLevel: 1)
        #expect(s.usedBytes == 50)          // (40 − 5) + 10 + 5
        #expect(s.totalBytes == 200)
        #expect(abs(s.usedFraction - 0.25) < 0.0001)
        #expect(s.pressure == .normal)
    }
    @Test func usedScalesByPageSize() {
        let raw = VMRaw(free: 0, active: 0, inactive: 0, wired: 2, compressed: 1,
                        internal: 4, purgeable: 1, pageSize: 16_384)
        #expect(memorySample(raw: raw, totalBytes: 1 << 30, pressureLevel: 1).usedBytes == 6 * 16_384)
    }
    @Test func purgeableAboveInternalDoesNotUnderflow() {
        let raw = VMRaw(free: 0, active: 0, inactive: 0, wired: 10, compressed: 5,
                        internal: 3, purgeable: 8, pageSize: 1)
        #expect(memorySample(raw: raw, totalBytes: 100, pressureLevel: 1).usedBytes == 15)
    }
    /// The Memory breakdown's rows count compressed memory at full size, so its "System &
    /// other" remainder is taken from Memory Used with the compressor at full size too.
    @Test func inUseAtFullSizeSwapsTheCompressorForWhatItHolds() {
        let raw = VMRaw(free: 0, active: 0, inactive: 0, wired: 10, compressed: 5,
                        internal: 40, purgeable: 5, pageSize: 2, compressedOriginal: 12)
        #expect(memoryInUseAtFullSize(raw) == (35 + 10 + 12) * 2)
        // Unknown original size (0): falls back to Memory Used.
        var unknown = raw
        unknown.compressedOriginal = 0
        #expect(memoryInUseAtFullSize(unknown) == memorySample(raw: unknown, totalBytes: 1, pressureLevel: 1).usedBytes)
    }
    @Test func pressureComesFromKernelLevel() {
        let raw = VMRaw(free: 0, active: 95, inactive: 0, wired: 0, compressed: 0,
                        internal: 95, purgeable: 0, pageSize: 1)
        // Used fraction is 0.95, but pressure follows the kernel level, not the fraction.
        #expect(memorySample(raw: raw, totalBytes: 100, pressureLevel: 1).pressure == .normal)
        #expect(memorySample(raw: raw, totalBytes: 100, pressureLevel: 2).pressure == .warning)
        #expect(memorySample(raw: raw, totalBytes: 100, pressureLevel: 4).pressure == .critical)
    }
}
