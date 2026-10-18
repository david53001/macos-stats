import Testing
@testable import MacStatsCore

@Suite struct CPUUsageTests {
    @Test func halfBusy() {
        let prev = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let cur  = CPUTicks(user: 25, system: 25, idle: 50, nice: 0)
        #expect(abs(cpuBusyPercent(previous: prev, current: cur) - 50) < 0.001)
    }

    @Test func noTimeElapsedReturnsZero() {
        let t = CPUTicks(user: 10, system: 10, idle: 10, nice: 0)
        #expect(abs(cpuBusyPercent(previous: t, current: t) - 0) < 0.001)
    }

    @Test func countersWrappingPast32BitsStillGiveTheRightShare() {
        // The idle count wraps after ~60 days of uptime; it read 0 % for that sample.
        let prev = CPUTicks(user: 1_000, system: 0, idle: UInt32.max - 49, nice: 0)
        let cur  = CPUTicks(user: 1_050, system: 0, idle: 50, nice: 0)   // +50 busy, +100 idle
        #expect(abs(cpuBusyPercent(previous: prev, current: cur) - 100.0 / 3) < 0.001)
    }

    @Test func clampedTo100() {
        let prev = CPUTicks(user: 0, system: 0, idle: 10, nice: 0)
        let cur  = CPUTicks(user: 100, system: 0, idle: 10, nice: 0)
        #expect(abs(cpuBusyPercent(previous: prev, current: cur) - 100) < 0.001)
    }

    @Test func perCPUCountersAreSummedPerState() {
        // Two CPUs, laid out user, system, idle, nice each (PROCESSOR_CPU_LOAD_INFO).
        let t = sumCPULoad([10, 2, 80, 1, 30, 4, 60, 0] as [Int32], cpuCount: 2)
        #expect(t == CPUTicks(user: 40, system: 6, idle: 140, nice: 1))
    }

    @Test func perCPUSumsWrapLikeTheKernelsOwnTotal() {
        // A counter past 2^31 arrives as a negative Int32; sums wrap mod 2^32, so deltas stay exact.
        let before = sumCPULoad([0, 0, Int32(bitPattern: UInt32.max - 9), 0, 0, 0, 5, 0] as [Int32], cpuCount: 2)
        let after = sumCPULoad([5, 0, 10, 0, 5, 0, 15, 0] as [Int32], cpuCount: 2)   // +10 busy, +30 idle
        #expect(abs(cpuBusyPercent(previous: before, current: after) - 25) < 0.001)
    }

    @Test func perCPUSumIgnoresAShortBuffer() {
        #expect(sumCPULoad([1, 2, 3, 4, 5] as [Int32], cpuCount: 2) == CPUTicks(user: 1, system: 2, idle: 3, nice: 4))
    }
}
