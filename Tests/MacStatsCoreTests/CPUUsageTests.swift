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
}
