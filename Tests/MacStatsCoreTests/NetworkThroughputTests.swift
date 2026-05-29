import Testing
@testable import MacStatsCore

@Suite struct NetworkThroughputTests {
    @Test func bytesPerSecond() {
        let prev = NetCounters(rxBytes: 1_000, txBytes: 500)
        let cur  = NetCounters(rxBytes: 3_000, txBytes: 1_500)
        let s = networkThroughput(previous: prev, current: cur, secondsElapsed: 2)
        #expect(abs(s.downBytesPerSec - 1_000) < 0.001) // (3000-1000)/2
        #expect(abs(s.upBytesPerSec - 500) < 0.001)     // (1500-500)/2
    }

    @Test func zeroElapsedReturnsZero() {
        let c = NetCounters(rxBytes: 10, txBytes: 10)
        let s = networkThroughput(previous: c, current: c, secondsElapsed: 0)
        #expect(s.downBytesPerSec == 0)
        #expect(s.upBytesPerSec == 0)
    }

    @Test func counterResetClampsToZero() {
        let prev = NetCounters(rxBytes: 5_000, txBytes: 5_000)
        let cur  = NetCounters(rxBytes: 10, txBytes: 10) // counter wrapped/reset
        let s = networkThroughput(previous: prev, current: cur, secondsElapsed: 1)
        #expect(s.downBytesPerSec == 0)
        #expect(s.upBytesPerSec == 0)
    }
}
