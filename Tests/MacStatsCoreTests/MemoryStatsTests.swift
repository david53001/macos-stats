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
    /// The Memory breakdown shows Memory Used's parts, as Activity Monitor's Memory tab does.
    @Test func partsAddUpToMemoryUsed() {
        let raw = VMRaw(free: 0, active: 0, inactive: 0, wired: 10, compressed: 5,
                        internal: 40, purgeable: 5, pageSize: 2, compressedOriginal: 12)
        let s = memorySample(raw: raw, totalBytes: 1_000, pressureLevel: 1)
        #expect(s.appBytes == 70)
        #expect(s.wiredBytes == 20)
        #expect(s.compressedBytes == 10)
        #expect(s.appBytes + s.wiredBytes + s.compressedBytes == s.usedBytes)
        #expect(s.compressedDataBytes == 24)   // what the compressor holds, at full size
    }

    @Test func roundedPartsAddUpToTheRoundedTotal() {
        // 6.16 + 1.66 + 2.66 = 10.48: plain rounding gives 6.2 + 1.7 + 2.7 = 10.6 under "10.5".
        let gib = 1_073_741_824.0
        let parts = [6.16, 1.66, 2.66].map { UInt64($0 * gib) }
        let shown = roundedParts(parts, unit: gib)
        #expect(zip(shown, [6.2, 1.7, 2.6]).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(abs(shown.reduce(0, +) - 10.5) < 1e-9)
    }

    @Test func roundedPartsKeepExactValues() {
        let shown = roundedParts([3_000, 1_000, 0], unit: 1_000)
        #expect(zip(shown, [3.0, 1.0, 0.0]).allSatisfy { abs($0 - $1) < 1e-9 })
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
