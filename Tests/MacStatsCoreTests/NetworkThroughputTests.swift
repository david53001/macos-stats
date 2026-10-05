import Testing
import Darwin
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

@Suite struct InterfaceCountersTests {
    private func interface(rx: UInt64, tx: UInt64, loopback: Bool = false) -> ifmibdata {
        var d = ifmibdata()
        d.ifmd_flags = loopback ? UInt32(IFF_LOOPBACK | IFF_UP) : UInt32(IFF_UP)
        d.ifmd_data.ifi_ibytes = rx
        d.ifmd_data.ifi_obytes = tx
        return d
    }

    @Test func sumsSixtyFourBitCountersPastFourGiB() {
        // getifaddrs' if_data counters were 32-bit and wrapped every 4 GiB per interface.
        let c = sumInterfaceCounters([interface(rx: 5_000_000_000, tx: 7), interface(rx: 6_000_000_000, tx: 3)])
        #expect(c == NetCounters(rxBytes: 11_000_000_000, txBytes: 10))
    }

    @Test func skipsLoopback() {
        let c = sumInterfaceCounters([interface(rx: 100, tx: 100, loopback: true), interface(rx: 1, tx: 2)])
        #expect(c == NetCounters(rxBytes: 1, txBytes: 2))
    }
}
