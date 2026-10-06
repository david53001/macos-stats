import Testing
@testable import MacStatsCore

@Suite struct DisplayHoldTests {
    @Test func wobbleAcrossARoundingBoundaryHolds() {
        var shown = heldValue(shown: nil, value: 8.49, step: 1)
        #expect(shown == 8)
        for value in [8.51, 8.49, 8.6, 8.4, 8.74] {
            shown = heldValue(shown: shown, value: value, step: 1)
            #expect(shown == 8)
        }
    }

    @Test func aRealMovePasses() {
        #expect(heldValue(shown: 8, value: 8.75, step: 1) == 9)
        #expect(heldValue(shown: 8, value: 12.2, step: 1) == 12)
        #expect(heldValue(shown: 8, value: 7.2, step: 1) == 7)
    }

    @Test func nilShownGivesTheQuantisedValue() {
        #expect(heldValue(shown: nil, value: 3.14159, step: 0.1) == (31.0 * 0.1))
        #expect(heldValue(shown: nil, value: 7.6, step: 1) == 8)
    }

    @Test func errorBoundHoldsOverARandomWalk() {
        var rng = SystemRandomNumberGenerator()
        for (step, band, rel) in [(1.0, 0.75, 0.0), (0.1, 0.75, 0.10), (1.0, 1.0, 0.0)] {
            var value = 20.0
            var shown: Double?
            for _ in 0..<5_000 {
                value = max(0, value + Double.random(in: -1.5...1.5, using: &rng))
                let previous = shown
                let next = heldValue(shown: previous, value: value, step: step, band: band, relBand: rel)
                let bound = max(band * step, rel * abs(previous ?? 0), step / 2) + 1e-9
                #expect(abs(next - value) <= bound)
                shown = next
            }
        }
    }

    @Test func relativeBandWidensTheHoldForBigValues() {
        // 40 % with a 10 % band: a 3-point move stays, a 5-point one passes.
        #expect(heldValue(shown: 40, value: 43, step: 1, band: 0.75, relBand: 0.10) == 40)
        #expect(heldValue(shown: 40, value: 45, step: 1, band: 0.75, relBand: 0.10) == 45)
        // Small values fall back to the step band.
        #expect(heldValue(shown: 1, value: 1.5, step: 1, band: 0.75, relBand: 0.10) == 1)
    }

    // MARK: Memory

    private let gib: UInt64 = 1_073_741_824

    private func sample(_ used: UInt64, _ pressure: MemoryPressure = .normal) -> MemorySample {
        MemorySample(usedBytes: used, totalBytes: 16 * gib, pressure: pressure, appBytes: used / 2,
                     wiredBytes: used / 4, compressedBytes: used - used / 2 - used / 4)
    }

    @Test func memoryIsHeldAsOneSample() {
        let shown = sample(10 * gib)
        let held = heldMemory(shown: shown, value: sample(10 * gib + 50_000_000))
        #expect(held == shown)   // used and every part: still adds up
        #expect(held.appBytes + held.wiredBytes + held.compressedBytes == held.usedBytes)
        let moved = sample(10 * gib + 120_000_000)
        #expect(heldMemory(shown: shown, value: moved) == moved)
        #expect(heldMemory(shown: nil, value: moved) == moved)
    }

    @Test func memoryPressureChangePassesAtOnce() {
        let shown = sample(10 * gib)
        let warning = sample(10 * gib + 1_000, .warning)
        #expect(heldMemory(shown: shown, value: warning) == warning)
    }

    // MARK: Network

    @Test func rateHoldsSmallWobble() {
        #expect(heldRate(shown: nil, value: 12_400) == 12_000)
        #expect(heldRate(shown: 5_000, value: 6_400) == 5_000)       // < 1.5 KB/s
        #expect(heldRate(shown: 5_000, value: 6_600) == 7_000)
        #expect(heldRate(shown: 200_000, value: 225_000) == 200_000)  // < 15 %
        #expect(heldRate(shown: 200_000, value: 231_000) == 231_000)
    }

    @Test func rateUnitSwitchIsHeld() {
        // 990 KB/s ↔ 1.0 MB/s across the format switch at 999.5 KB/s.
        #expect(heldRate(shown: 990_000, value: 1_010_000) == 990_000)
        #expect(heldRate(shown: 1_000_000, value: 990_000) == 1_000_000)
        #expect(heldRate(shown: 990_000, value: 1_200_000) == 1_200_000)
        #expect(heldRate(shown: nil, value: 1_234_567) == 1_200_000)
    }

    // MARK: Battery times

    @Test func timeLeftHoldsAtEachStepBoundary() {
        // Under 15 min, to the minute: a 1-minute move passes.
        #expect(heldTimeLeft(shown: 14, minutes: 15) == 15)
        // 5-minute steps under 2 h: 3 minutes stay, 4 pass.
        #expect(heldTimeLeft(shown: 119, minutes: 120) == 119)
        #expect(heldTimeLeft(shown: 116, minutes: 119) == 116)
        #expect(heldTimeLeft(shown: 115, minutes: 119) == 119)
        // 15-minute steps under 6 h.
        #expect(heldTimeLeft(shown: 120, minutes: 119) == 120)
        #expect(heldTimeLeft(shown: 359, minutes: 360) == 359)
        #expect(heldTimeLeft(shown: 359, minutes: 371) == 371)
        // Hours above 6 h.
        #expect(heldTimeLeft(shown: 360, minutes: 359) == 360)
        #expect(heldTimeLeft(shown: 400, minutes: 444) == 400)
        #expect(heldTimeLeft(shown: 400, minutes: 445) == 445)
        #expect(heldTimeLeft(shown: nil, minutes: 77) == 77)
    }

    @Test func timeToFullFallsByOneButDoesNotRiseByOne() {
        #expect(heldTimeToFull(shown: 30, minutes: 29) == 29)
        #expect(heldTimeToFull(shown: 30, minutes: 31) == 30)
        #expect(heldTimeToFull(shown: 30, minutes: 32) == 32)
        #expect(heldTimeToFull(shown: nil, minutes: 31) == 31)
    }

    @Test func relativeBandIsCapped() {
        // 50 % shown: 10 % would hold up to 55 %; the 2 pp cap lets 52 % through.
        #expect(heldValue(shown: 50, value: 51.9, step: 1, relBand: 0.10, cap: 2) == 50)
        #expect(heldValue(shown: 50, value: 52, step: 1, relBand: 0.10, cap: 2) == 52)
        // Small rows keep the relative band (under the cap).
        #expect(heldValue(shown: 5, value: 5.4, step: 0.1, relBand: 0.10, cap: 2) == 5)
    }
}
