import Testing
@testable import MacStatsCore

@Suite struct MemoryStatsTests {
    @Test func usedIsActivePlusWiredPlusCompressed() {
        let raw = VMRaw(free: 100, active: 30, inactive: 20, wired: 10, compressed: 5, pageSize: 1)
        let s = memorySample(raw: raw, totalBytes: 200, pressureLevel: 1)
        #expect(s.usedBytes == 45)          // 30 + 10 + 5
        #expect(s.totalBytes == 200)
        #expect(abs(s.usedFraction - 0.225) < 0.0001)
        #expect(s.pressure == .normal)
    }
    @Test func pressureComesFromKernelLevel() {
        let raw = VMRaw(free: 0, active: 95, inactive: 0, wired: 0, compressed: 0, pageSize: 1)
        // Used fraction is 0.95, but pressure follows the kernel level, not the fraction.
        #expect(memorySample(raw: raw, totalBytes: 100, pressureLevel: 1).pressure == .normal)
        #expect(memorySample(raw: raw, totalBytes: 100, pressureLevel: 2).pressure == .warning)
        #expect(memorySample(raw: raw, totalBytes: 100, pressureLevel: 4).pressure == .critical)
    }
}
