import Testing
@testable import MacStatsCore

@Suite struct SystemReadersSmokeTests {
    @Test func cpuTicksAccumulate() {
        #expect(readCPUTicks().total > 0)
    }

    @Test func vmHasPageSizeAndTotal() {
        let raw = readVMRaw()
        #expect(raw.pageSize > 0)
        #expect(raw.active + raw.wired > 0)
    }

    @Test func netCountersAreMonotonic() {
        let a = readNetCounters()
        let b = readNetCounters()
        #expect(b.rxBytes >= a.rxBytes)
        #expect(b.txBytes >= a.txBytes)
    }

    @Test func batteryIsNilOrInRange() {
        if let s = readBattery() {
            #expect((0...100).contains(s.percent))
        }
        // nil is acceptable (e.g. a desktop Mac with no battery)
    }

    @Test func memoryPressureLevelIsKnown() {
        let level = readMemoryPressureLevel()
        #expect([1, 2, 4].contains(level))
    }
}
