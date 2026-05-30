import Testing
@testable import MacStatsCore

@Suite struct RefreshSchedulerTests {
    @Test func idleIsSlow() {
        #expect(abs(refreshInterval(for: .idle) - 10.0) < 0.001)
    }
    @Test func openIsOneSecond() {
        #expect(abs(refreshInterval(for: .popoverOpen) - 1.0) < 0.001)
    }

    @Test func fillPhaseIsFastAndDense() {
        // The first `burstSamples` samples come fast (the priming fill)…
        #expect(abs(openPhaseInterval(samplesSinceOpen: 0) - burstInterval) < 0.001)
        #expect(abs(openPhaseInterval(samplesSinceOpen: burstSamples - 1) - burstInterval) < 0.001)
    }

    @Test func cadenceEasesInsteadOfCliff() {
        // …then the first post-fill sample is slower than the burst but faster than the
        // steady 1s — it ramps rather than jumping straight to the steady cadence (the old
        // hard cliff left a ~1s stall right after the fill).
        let steady = refreshInterval(for: .popoverOpen)
        let first = openPhaseInterval(samplesSinceOpen: burstSamples)
        #expect(first > burstInterval)
        #expect(first < steady)
    }

    @Test func rampIsMonotonicAndClampsToSteady() {
        let steady = refreshInterval(for: .popoverOpen)
        var prev = 0.0
        for n in burstSamples...(burstSamples + 20) {
            let v = openPhaseInterval(samplesSinceOpen: n)
            #expect(v >= prev - 0.001)      // non-decreasing through the ramp
            #expect(v <= steady + 0.001)    // never overshoots the steady cadence
            prev = v
        }
        // Far enough out it has settled at the steady cadence.
        #expect(abs(openPhaseInterval(samplesSinceOpen: burstSamples + 20) - steady) < 0.001)
    }

    @Test func burstSpansAboutOneSecond() {
        // burstSamples points at burstInterval apart should fill ~1 second.
        #expect(abs(Double(burstSamples) * burstInterval - 1.0) < 0.001)
    }
}
