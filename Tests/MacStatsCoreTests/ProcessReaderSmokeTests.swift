import Testing
import Darwin
@testable import MacStatsCore

@Suite struct ProcessReaderSmokeTests {
    @Test func returnsCurrentProcessWithSaneFields() {
        let procs = readRawProcesses()
        #expect(!procs.isEmpty)

        let me = procs.first { $0.pid == getpid() }
        #expect(me != nil)                       // our own process is listed
        #expect(me?.ppid ?? 0 > 0)               // has a parent
        // CPU time is cumulative-since-launch (could be small but non-negative); memory > 0.
        #expect((me?.memoryBytes ?? 0) > 0)
    }
}
