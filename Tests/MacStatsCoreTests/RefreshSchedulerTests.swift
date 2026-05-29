import Testing
@testable import MacStatsCore

@Suite struct RefreshSchedulerTests {
    @Test func idleIsSlow() {
        #expect(abs(refreshInterval(for: .idle) - 3.0) < 0.001)
    }
    @Test func openIsOneSecond() {
        #expect(abs(refreshInterval(for: .popoverOpen) - 1.0) < 0.001)
    }
}
