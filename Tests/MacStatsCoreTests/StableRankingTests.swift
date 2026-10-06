import Testing
@testable import MacStatsCore

@Suite struct StableRankingTests {
    private let cpu = RankHysteresis.cpu

    @Test func emptyPreviousIsAPlainSort() {
        let order = stableRanking(previous: [], now: [1: 2, 2: 5, 3: 0.5, BreakdownGroup.system: 5], rule: cpu)
        #expect(order == [2, BreakdownGroup.system, 1, 3])
    }

    @Test func noSwapWithinTheMargin() {
        // 4.5 vs 4: needs > max(4 × 1.15, 4 + 0.15) = 4.6, so the row below doesn't climb…
        let order = stableRanking(previous: [2, 1], now: [1: 4.5, 2: 4], rule: cpu)
        #expect(order == [2, 1])
        // …and 4.0 vs 3.5 (a 14 % lead) doesn't either; 4.1 vs 3.5 (17 %) does.
        #expect(stableRanking(previous: [2, 1], now: [1: 4, 2: 3.5], rule: cpu) == [2, 1])
        #expect(stableRanking(previous: [2, 1], now: [1: 4.1, 2: 3.5], rule: cpu) == [1, 2])
    }

    @Test func jumpRuleMovesASpikeAtOnce() {
        // 1 → 6 pp over 2's 1 pp: > 1.5× and > 1 pp ahead.
        let order = stableRanking(previous: [2, 1], now: [1: 6, 2: 1], rule: cpu)
        #expect(order == [1, 2])
    }

    @Test func aPromotedKeyPassesWithinTheMargin() {
        // 4.5 vs 4 is within the margins, but a promoted key passes what it outranks.
        #expect(stableRanking(previous: [2, 1], now: [1: 4.5, 2: 4], rule: cpu, promoted: [1]) == [1, 2])
        #expect(stableRanking(previous: [2, 1], now: [1: 3.5, 2: 4], rule: cpu, promoted: [1]) == [2, 1])
    }

    @Test func newKeysEnterAtTheirSortedPlaceAndVanishedOnesGo() {
        let order = stableRanking(previous: [1, 2, 3], now: [1: 9, 3: 1, 4: 5], rule: cpu)
        #expect(order == [1, 4, 3])
    }

    @Test func frozenKeepsOrderAndAppendsNewKeys() {
        let order = stableRanking(previous: [1, 2, 3], now: [1: 0, 2: 1, 3: 50, 4: 99], rule: cpu, frozen: true)
        #expect(order == [1, 2, 3, 4])
        let quit = stableRanking(previous: [1, 2, 3], now: [1: 0, 3: 50], rule: cpu, frozen: true)
        #expect(quit == [1, 3])
    }

    @Test func groupsStayLastForMemory() {
        let mb = 1_048_576.0
        let other = BreakdownGroup.otherProcesses
        let values: [Int32: Double] = [other: 4_000 * mb, 7: 300 * mb, 8: 100 * mb, 9: 2_000 * mb]
        let order = stableRanking(previous: [7, 8, other], now: values, rule: .memory,
                                  groupsLast: true)
        #expect(order == [9, 7, 8, other])
        let frozen = stableRanking(previous: [7, 8, other], now: values, rule: .memory,
                                   frozen: true, groupsLast: true)
        #expect(frozen == [7, 8, 9, other])
    }

    @Test func tiesAreDeterministicByKey() {
        let values: [Int32: Double] = [9: 0, 3: 0, 5: 0, BreakdownGroup.otherProcesses: 0]
        let a = stableRanking(previous: [], now: values, rule: cpu)
        let b = stableRanking(previous: [], now: values, rule: cpu)
        #expect(a == [3, 5, 9, BreakdownGroup.otherProcesses])
        #expect(a == b)
        // New tied keys enter in key order too.
        #expect(stableRanking(previous: [3], now: values, rule: cpu)
                == [3, 5, 9, BreakdownGroup.otherProcesses])
    }

    @Test func aRowItCantBeatDoesNotBlockOneItCan() {
        // Round 1's CPU case: 4.3 % sat under 0.4 % because 2.3 % (within its margin) stopped it.
        let values: [Int32: Double] = [1: 2.9, 2: 3.3, 3: 0.4, 4: 2.3, 5: 4.3]
        let order = stableRanking(previous: [1, 2, 3, 4, 5], now: values, rule: cpu)
        #expect(order == [5, 1, 2, 4, 3])
        // A row passes the lower rows it outranks but stops under a higher one.
        let stops = stableRanking(previous: [1, 2, 3], now: [1: 5, 2: 0.1, 3: 4.5], rule: cpu)
        #expect(stops == [1, 3, 2])
    }

    @Test func energyRowsSortAtTheirPrintedPrecision() {
        // Round 1's Battery capture: 0.00 W on top, 0.17 W near the bottom (the old 0.05 W margin).
        let values: [Int32: Double] = [1: 0.14, 2: 0.01, 3: 0.00, 4: 0.05, 5: 0.04, 6: 0.17]
        let order = stableRanking(previous: [1, 2, 3, 4, 5, 6], now: values, rule: .energy)
        // Everything sorts: 0.17 W leads 0.14 W by 21 % and 0.03 W, past both margins (15 %, 0.02 W).
        #expect(order == [6, 1, 4, 5, 2, 3])
        // 0.15 vs 0.14 (7 %) is within them, so those two keep their order.
        let close = stableRanking(previous: [1, 6], now: [1: 0.14, 6: 0.15], rule: .energy)
        #expect(close == [1, 6])
    }

    /// Steady readings from any starting order: after one scan, no row is clearly beaten
    /// (by both margins) by a row below it, for every metric's rule.
    @Test(arguments: [RankHysteresis.cpu, .energy, .memory])
    func steadyInputsConvergeToSorted(rule: RankHysteresis) {
        var rng = SplitMix(seed: 42)
        let scale = rule == .memory ? 4_000.0 * 1_048_576 : rule == .energy ? 3.0 : 40.0
        for _ in 0..<300 {
            let n = Int(rng.next() % 30) + 2
            var values: [Int32: Double] = [:]
            for k in 1...n {
                // Mostly small values with a few large ones, like real breakdowns.
                let u = Double(rng.next() % 10_000) / 10_000
                values[Int32(k)] = (u * u * u * scale * 100).rounded() / 100
            }
            let previous = values.keys.shuffled(using: &rng)
            let order = stableRanking(previous: previous, now: values, rule: rule)
            #expect(Set(order) == Set(values.keys))
            for (i, upper) in order.enumerated() {
                for lower in order[(i + 1)...] {
                    let a = values[lower]!, b = values[upper]!
                    let clearly = a > max(b * (1 + rule.rel), b + rule.abs) || (a > 1.5 * b && a - b > rule.jump)
                    #expect(!clearly, "\(a) below \(b)")
                }
            }
        }
    }

    @Test func ruleForEachMetric() {
        #expect(RankHysteresis.for(.cpu) == .cpu)
        #expect(RankHysteresis.for(.memory) == .memory)
        #expect(RankHysteresis.for(.energy) == .energy)
    }
}

/// A small seeded generator, so the property test is reproducible.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
