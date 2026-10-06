import Testing
@testable import MacStatsCore

@Suite struct TourRulesTests {
    private let id = "com.macstats.MacStats"

    @Test func classify() {
        #expect(TourAudience.classify(domainKeys: [], bundleID: id) == .new)
        #expect(TourAudience.classify(domainKeys: TourKey.all, bundleID: id) == .new)
        #expect(TourAudience.classify(domainKeys: ["didRegisterLoginItem"], bundleID: id) == .existing)
        #expect(TourAudience.classify(domainKeys: ["NSStatusItem VisibleCC Item-0"], bundleID: id) == .existing)
        #expect(TourAudience.classify(domainKeys: ["batteryDrainTypicalWatts"], bundleID: id) == .existing)
        #expect(TourAudience.classify(domainKeys: [TourKey.audience, "uiOpacity"], bundleID: id) == .existing)
        #expect(TourAudience.classify(domainKeys: [], bundleID: nil) == .existing)
        #expect(TourAudience.classify(domainKeys: [], bundleID: "com.example.Other") == .existing)
    }

    @Test func welcomeOnlyForAnUnansweredNewUser() {
        #expect(TourRules.shouldShowWelcome(audience: .new, seenVersion: nil, answered: false))
        #expect(!TourRules.shouldShowWelcome(audience: .new, seenVersion: nil, answered: true))
        #expect(!TourRules.shouldShowWelcome(audience: .new, seenVersion: 1, answered: false))
        #expect(!TourRules.shouldShowWelcome(audience: .existing, seenVersion: nil, answered: false))
    }

    @Test func offerTour() {
        #expect(TourRules.shouldOfferTour(audience: .existing, seenVersion: nil, offerShows: 0, dismissed: false))
        #expect(TourRules.shouldOfferTour(audience: .existing, seenVersion: nil, offerShows: 2, dismissed: false))
        #expect(!TourRules.shouldOfferTour(audience: .existing, seenVersion: nil, offerShows: 3, dismissed: false))
        #expect(!TourRules.shouldOfferTour(audience: .existing, seenVersion: nil, offerShows: 0, dismissed: true))
        #expect(!TourRules.shouldOfferTour(audience: .new, seenVersion: nil, offerShows: 0, dismissed: false))
        #expect(!TourRules.shouldOfferTour(audience: .existing, seenVersion: 1, offerShows: 0, dismissed: false,
                                           version: 1))
        // A version bump offers again; dismissed stays never.
        #expect(TourRules.shouldOfferTour(audience: .existing, seenVersion: 1, offerShows: 0, dismissed: false,
                                          version: 2))
        #expect(!TourRules.shouldOfferTour(audience: .existing, seenVersion: 1, offerShows: 0, dismissed: true,
                                           version: 2))
    }

    @Test func deferPermissionPrompts() {
        #expect(TourRules.deferPermissionPrompts(audience: .new, seenVersion: nil))
        #expect(!TourRules.deferPermissionPrompts(audience: .new, seenVersion: nil, answered: true))
        #expect(!TourRules.deferPermissionPrompts(audience: .new, seenVersion: 1))
        #expect(!TourRules.deferPermissionPrompts(audience: .existing, seenVersion: nil))
    }

    @Test func breakdownHint() {
        #expect(TourRules.showsBreakdownHint(shows: 0))
        #expect(TourRules.showsBreakdownHint(shows: 2))
        #expect(!TourRules.showsBreakdownHint(shows: 3))
    }
}
