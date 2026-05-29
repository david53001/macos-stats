import Testing
@testable import MacStatsCore

@Suite struct RefreshSchedulerTests {
    @Test func idleIsSlow() {
        #expect(abs(refreshInterval(for: .idle) - 3.0) < 0.001)
    }
    @Test func openIsOneSecond() {
        #expect(abs(refreshInterval(for: .popoverOpen) - 1.0) < 0.001)
    }

    @Test func burstWhileFillingThenSteady() {
        // The first `burstSamples` samples come fast (the priming burst)…
        #expect(abs(openPhaseInterval(samplesSinceOpen: 0) - 0.1) < 0.001)
        #expect(abs(openPhaseInterval(samplesSinceOpen: burstSamples - 1) - 0.1) < 0.001)
        // …then it settles to the steady open cadence (1s).
        #expect(abs(openPhaseInterval(samplesSinceOpen: burstSamples) - 1.0) < 0.001)
        #expect(abs(openPhaseInterval(samplesSinceOpen: burstSamples + 5) - 1.0) < 0.001)
    }

    @Test func burstSpansAboutOneSecond() {
        // burstSamples points at burstInterval apart should fill ~1 second.
        #expect(abs(Double(burstSamples) * burstInterval - 1.0) < 0.001)
    }
}
