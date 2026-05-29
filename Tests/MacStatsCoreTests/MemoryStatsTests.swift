import Testing
@testable import MacStatsCore

@Suite struct MemoryStatsTests {
    // pageSize 1 byte keeps the arithmetic obvious.
    @Test func usedIsActivePlusWiredPlusCompressed() {
        let raw = VMRaw(free: 100, active: 30, inactive: 20, wired: 10, compressed: 5, pageSize: 1)
        let s = memorySample(raw: raw, totalBytes: 200)
        #expect(s.usedBytes == 45)          // 30 + 10 + 5
        #expect(s.totalBytes == 200)
        #expect(abs(s.usedFraction - 0.225) < 0.0001)
        #expect(s.pressure == .normal)
    }

    @Test func warningAndCriticalThresholds() {
        let warn = memorySample(raw: VMRaw(free: 0, active: 80, inactive: 0, wired: 0, compressed: 0, pageSize: 1), totalBytes: 100)
        #expect(warn.pressure == .warning)  // 0.80 > 0.75
        let crit = memorySample(raw: VMRaw(free: 0, active: 95, inactive: 0, wired: 0, compressed: 0, pageSize: 1), totalBytes: 100)
        #expect(crit.pressure == .critical) // 0.95 > 0.90
    }
}
