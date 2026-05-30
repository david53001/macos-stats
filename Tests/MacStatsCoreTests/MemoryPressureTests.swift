import Testing
@testable import MacStatsCore

@Suite struct MemoryPressureTests {
    @Test func mapsKernelLevels() {
        #expect(memoryPressure(fromLevel: 1) == .normal)
        #expect(memoryPressure(fromLevel: 2) == .warning)
        #expect(memoryPressure(fromLevel: 4) == .critical)
    }
    @Test func unknownLevelIsNormal() {
        #expect(memoryPressure(fromLevel: 0) == .normal)
        #expect(memoryPressure(fromLevel: 99) == .normal)
    }
}
