import Testing
@testable import MacStatsCore

@Suite struct TourStateTests {
    private let all: (TourStep) -> Bool = { _ in true }
    private let noBattery: (TourStep) -> Bool = { !$0.requiresBattery }
    private var batteryIndex: Int { TourCatalog.steps.firstIndex { $0.id == .battery }! }

    @Test func fullPathFromWelcomeToDone() {
        var s = TourState()
        s.showWelcome()
        #expect(s.phase == .welcome)
        #expect(s.start(isPresent: all) == .show(0))
        for i in 1..<TourCatalog.steps.count {
            #expect(s.next(isPresent: all) == .show(i))
        }
        #expect(s.next(isPresent: all) == .finished)
        #expect(s.phase == .off)
    }

    @Test func backOnTheFirstStepDoesNothing() {
        var s = TourState()
        _ = s.start(isPresent: all)
        #expect(s.back(isPresent: all) == .none)
        #expect(s.phase == .step(0))
    }

    @Test func backAndNextSkipTheMissingBatteryStep() {
        var s = TourState()
        _ = s.start(at: batteryIndex - 1, isPresent: noBattery)
        #expect(s.next(isPresent: noBattery) == .show(batteryIndex + 1))
        #expect(s.back(isPresent: noBattery) == .show(batteryIndex - 1))
    }

    @Test func startSkipsToTheFirstPresentableStep() {
        var s = TourState()
        #expect(s.start(at: batteryIndex, isPresent: noBattery) == .show(batteryIndex + 1))
        var past = TourState()
        #expect(past.start(at: TourCatalog.steps.count, isPresent: all) == .finished)
    }

    @Test func skipFromAnyStepFinishes() {
        for i in TourCatalog.steps.indices {
            var s = TourState()
            _ = s.start(at: i, isPresent: all)
            #expect(s.skip() == .finished)
            #expect(s.phase == .off)
        }
        var welcome = TourState()
        welcome.showWelcome()
        #expect(welcome.skip() == .finished)   // No Thanks
        var off = TourState()
        #expect(off.skip() == .none)
    }

    @Test func firstClosePausesAtTheSameStepSecondFinishes() {
        var s = TourState()
        _ = s.start(at: 2, isPresent: all)
        #expect(s.panelClosed() == .paused(2))
        #expect(s.phase == .off)
        #expect(s.interruptions == 1)
        // The next open resumes the same run where it was.
        var resumed = TourState(interruptions: s.interruptions)
        #expect(resumed.start(at: 2, isPresent: all) == .show(2))
        #expect(resumed.panelClosed() == .finished)
    }

    @Test func closingTheWelcomeAsksAgainThenCountsAsNoThanks() {
        var s = TourState()
        s.showWelcome()
        #expect(s.panelClosed() == .none)
        #expect(s.phase == .off)
        var again = TourState(interruptions: s.interruptions)
        again.showWelcome()
        #expect(again.panelClosed() == .finished)
    }

    @Test func closingWhenOffDoesNothing() {
        var s = TourState()
        #expect(s.panelClosed() == .none)
        #expect(s.interruptions == 0)
    }

    @Test func progressCountsOnlyShownSteps() {
        var s = TourState()
        var seen: [String] = []
        var effect = s.start(isPresent: all)
        while case .show = effect {
            let p = s.progress(isPresent: all)!
            seen.append("\(p.number)/\(p.total)")
            effect = s.next(isPresent: all)
        }
        #expect(seen == ["1/5", "2/5", "3/5", "4/5", "5/5"])

        var d = TourState()
        seen = []
        effect = d.start(isPresent: noBattery)
        while case .show = effect {
            let p = d.progress(isPresent: noBattery)!
            seen.append("\(p.number)/\(p.total)")
            effect = d.next(isPresent: noBattery)
        }
        #expect(seen == ["1/4", "2/4", "3/4", "4/4"])
        #expect(TourState().progress(isPresent: all) == nil)
    }
}
