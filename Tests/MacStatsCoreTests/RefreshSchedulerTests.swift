import Testing
import Foundation
@testable import MacStatsCore

@Suite struct RefreshSchedulerTests {
    @Test func idleIsSlow() {
        #expect(abs(refreshInterval(for: .idle) - 10.0) < 0.001)
    }
    @Test func openIsHalfASecond() {
        #expect(abs(refreshInterval(for: .popoverOpen) - 0.5) < 0.001)
    }

    @Test func rateWindowIsLongerThanOpenCadence() {
        // Rates average over ≥2 ticks, so the faster cadence doesn't make values flicker.
        #expect(rateWindowSeconds >= 2 * refreshInterval(for: .popoverOpen))
    }

    @Test func toleranceIsASmallFractionOfTheInterval() {
        for v in [Visibility.idle, .popoverOpen] {
            #expect(refreshTolerance(for: v) > 0)
            #expect(refreshTolerance(for: v) <= refreshInterval(for: v) * 0.2 + 0.001)
        }
    }

    @Test func slowTiersAreMultiplesOfOpenCadence() {
        #expect(abs(temperatureInterval - 2.0) < 0.001)
        #expect(abs(batteryInterval - 10.0) < 0.001)
        #expect(temperatureInterval > refreshInterval(for: .popoverOpen))
    }

    @Test func breakdownRescansQuicklyThenSettles() {
        #expect(breakdownFirstRescanDelay < breakdownScanInterval)
        #expect(abs(breakdownFirstRescanDelay - 0.3) < 0.001)
        #expect(abs(breakdownScanInterval - 1.0) < 0.001)
    }

    @Test func neverReadIsDue() {
        #expect(isDue(last: nil, now: Date(), every: 2))
    }

    @Test func dueOnlyOnceIntervalHasElapsed() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        #expect(!isDue(last: t0, now: t0.addingTimeInterval(1.5), every: 2))
        #expect(isDue(last: t0, now: t0.addingTimeInterval(2.0), every: 2))
        #expect(isDue(last: t0, now: t0.addingTimeInterval(2.5), every: 2))
    }
}
