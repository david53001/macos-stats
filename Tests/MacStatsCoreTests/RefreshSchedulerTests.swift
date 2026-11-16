import Testing
import Foundation
@testable import MacStatsCore

@Suite struct RefreshSchedulerTests {
    @Test func idleIsSlow() {
        #expect(abs(refreshInterval(for: .idle) - 10.0) < 0.001)
    }
    @Test func openIsOneSecond() {
        #expect(abs(refreshInterval(for: .popoverOpen) - 1.0) < 0.001)
    }

    @Test func openCadenceFeedsTheDwellAndTheScans() {
        // Card text dwells 2 s and a breakdown screen ticks with its scans: whole multiples.
        #expect(cardDwellSeconds >= refreshInterval(for: .popoverOpen))
        #expect(breakdownScanInterval >= refreshInterval(for: .popoverOpen))
    }

    // MARK: Trash re-read on open

    @Test func trashIsReadWhenNeverRead() {
        #expect(trashReadDue(lastRead: nil, lastStamp: nil, now: Date(), stamp: Date()))
    }

    @Test func unchangedTrashIsNotReReadWithinAMinute() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000), stamp = Date(timeIntervalSinceReferenceDate: 500)
        #expect(!trashReadDue(lastRead: t0, lastStamp: stamp, now: t0.addingTimeInterval(59), stamp: stamp))
        #expect(trashReadDue(lastRead: t0, lastStamp: stamp, now: t0.addingTimeInterval(60), stamp: stamp))
    }

    @Test func changedOrUnknownTrashIsReadAtOnce() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000), stamp = Date(timeIntervalSinceReferenceDate: 500)
        let later = stamp.addingTimeInterval(1)
        #expect(trashReadDue(lastRead: t0, lastStamp: stamp, now: t0.addingTimeInterval(1), stamp: later))
        #expect(trashReadDue(lastRead: t0, lastStamp: stamp, now: t0.addingTimeInterval(1), stamp: nil))
        #expect(trashReadDue(lastRead: t0, lastStamp: nil, now: t0.addingTimeInterval(1), stamp: stamp))
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

    @Test func breakdownScansEveryTwoSeconds() {
        #expect(abs(breakdownScanInterval - 2.0) < 0.001)
        #expect(trailingWindowSeconds >= 2 * breakdownScanInterval - 0.001)
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
