import Testing
@testable import MacStatsCore

@Suite struct StableRankingTests {
    private let cpu = RankHysteresis.cpu

    @Test func emptyPreviousIsAPlainSort() {
        let order = stableRanking(previous: [], now: [1: 2, 2: 5, 3: 0.5, BreakdownGroup.system: 5], before: [:],
                                  rule: cpu)
        #expect(order == [2, BreakdownGroup.system, 1, 3])
    }

    @Test func noSwapWithinTheMargin() {
        // 5 vs 4: 4 × 1.25 + 0.3 = 5.3 > 5, so the row below doesn't climb.
        let order = stableRanking(previous: [2, 1], now: [1: 5, 2: 4], before: [1: 5, 2: 4], rule: cpu)
        #expect(order == [2, 1])
    }

    @Test func aSwapNeedsTwoReadings() {
        // 1 jumps from 4 to 8 (not a 2× lead over 5, so no jump rule): held for one reading…
        let first = stableRanking(previous: [2, 1], now: [1: 8, 2: 5], before: [1: 4, 2: 5], rule: cpu)
        #expect(first == [2, 1])
        // …and moves when it leads on both.
        let second = stableRanking(previous: first, now: [1: 8, 2: 5], before: [1: 8, 2: 5], rule: cpu)
        #expect(second == [1, 2])
    }

    @Test func jumpRuleMovesASpikeAtOnce() {
        // 1 → 6 pp over 2's 1 pp: > 2× and > 2 pp ahead.
        let order = stableRanking(previous: [2, 1], now: [1: 6, 2: 1], before: [1: 0.5, 2: 1], rule: cpu)
        #expect(order == [1, 2])
    }

    @Test func newKeysEnterAtTheirSortedPlaceAndVanishedOnesGo() {
        let order = stableRanking(previous: [1, 2, 3], now: [1: 9, 3: 1, 4: 5], before: [1: 9, 2: 6, 3: 1],
                                  rule: cpu)
        #expect(order == [1, 4, 3])
    }

    @Test func pinnedKeepsItsIndex() {
        // 3 is pinned at index 1; 4 climbs past everything else around it.
        let previous: [Int32] = [1, 3, 2, 4]
        let values: [Int32: Double] = [1: 5, 2: 4, 3: 0.1, 4: 30]
        let order = stableRanking(previous: previous, now: values, before: values, rule: cpu, pinned: [3])
        #expect(order[1] == 3)
        #expect(order == [4, 3, 1, 2])
    }

    @Test func frozenKeepsOrderAndAppendsNewKeys() {
        let order = stableRanking(previous: [1, 2, 3], now: [1: 0, 2: 1, 3: 50, 4: 99], before: [:],
                                  rule: cpu, frozen: true)
        #expect(order == [1, 2, 3, 4])
        let quit = stableRanking(previous: [1, 2, 3], now: [1: 0, 3: 50], before: [:], rule: cpu, frozen: true)
        #expect(quit == [1, 3])
    }

    @Test func groupsStayLastForMemory() {
        let mb = 1_048_576.0
        let other = BreakdownGroup.otherProcesses
        let values: [Int32: Double] = [other: 4_000 * mb, 7: 300 * mb, 8: 100 * mb, 9: 2_000 * mb]
        let order = stableRanking(previous: [7, 8, other], now: values, before: values, rule: .memory,
                                  groupsLast: true)
        #expect(order == [9, 7, 8, other])
        let frozen = stableRanking(previous: [7, 8, other], now: values, before: values, rule: .memory,
                                   frozen: true, groupsLast: true)
        #expect(frozen == [7, 8, 9, other])
    }

    @Test func tiesAreDeterministicByKey() {
        let values: [Int32: Double] = [9: 0, 3: 0, 5: 0, BreakdownGroup.otherProcesses: 0]
        let a = stableRanking(previous: [], now: values, before: [:], rule: cpu)
        let b = stableRanking(previous: [], now: values, before: [:], rule: cpu)
        #expect(a == [3, 5, 9, BreakdownGroup.otherProcesses])
        #expect(a == b)
        // New tied keys enter in key order too.
        #expect(stableRanking(previous: [3], now: values, before: [:], rule: cpu)
                == [3, 5, 9, BreakdownGroup.otherProcesses])
    }

    @Test func ruleForEachMetric() {
        #expect(RankHysteresis.for(.cpu) == .cpu)
        #expect(RankHysteresis.for(.memory) == .memory)
        #expect(RankHysteresis.for(.energy) == .energy)
    }
}
