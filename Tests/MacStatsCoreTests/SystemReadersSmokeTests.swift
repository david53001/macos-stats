import Testing
import Foundation
@testable import MacStatsCore

@Suite struct SystemReadersSmokeTests {
    @Test func cpuTicksAccumulate() {
        #expect(readCPUTicks().total > 0)
    }

    /// host_statistics returned the previous reading for 1–2 of 40 reads at 3/s (rate limit).
    @Test func cpuTicksAreFreshAtAHighReadRate() {
        var last = readCPUTicks()
        for _ in 0..<20 {
            usleep(20_000)   // 50 reads/s; 8 cores × 100 Hz = 16 ticks per gap
            let now = readCPUTicks()
            #expect(now.total > last.total)
            last = now
        }
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

    @Test func ownCoalitionCountsOwnCPUInNanoseconds() {
        // Live check of the private struct layout and units: our coalition grows at least by
        // our own spin (Mach units left unconverted would read ~42× low on Apple Silicon).
        let id = readCoalitionID(getpid())
        guard id != 0, let before = readCoalitionUsage(id) else { return }   // older/newer macOS: estimate path
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        var x = 0.0
        while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start < 200_000_000 { x += 1 }
        let spun = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start
        let after = readCoalitionUsage(id)!
        #expect(x > 0)
        #expect(after.cpuTimeNs >= before.cpuTimeNs + spun * 9 / 10)
        #expect(after.energyNj >= before.energyNj)
    }

    @Test func memoryPressureLevelIsKnown() {
        let level = readMemoryPressureLevel()
        #expect([1, 2, 4].contains(level))
    }
}
