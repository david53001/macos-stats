import Foundation

/// How strongly a breakdown resists re-ranking (diagnosis section 5.2). Measured on live data
/// (`docs/research/2026-10-06-stability-diagnosis.md` §4.1): with a 4 s window these margins
/// cut the CPU breakdown's top-8 order changes from 59 to 5–13 a minute.
public struct RankHysteresis: Equatable, Sendable {
    public var rel: Double      // relative margin
    public var abs: Double      // absolute margin (metric units)
    public var jump: Double     // a lead this big (and > 2×) moves at once

    public init(rel: Double, abs: Double, jump: Double) {
        self.rel = rel; self.abs = abs; self.jump = jump
    }

    public static let cpu    = RankHysteresis(rel: 0.25, abs: 0.3, jump: 2)          // pp of the whole Mac
    public static let memory = RankHysteresis(rel: 0.05, abs: 20 * 1_048_576, jump: 200 * 1_048_576)
    public static let energy = RankHysteresis(rel: 0.25, abs: 0.05, jump: 1)         // W

    public static func `for`(_ metric: BreakdownMetric) -> RankHysteresis {
        switch metric {
        case .cpu: return .cpu
        case .memory: return .memory
        case .energy: return .energy
        }
    }
}

/// Re-ranks keys with hysteresis. Starts from `previous`: vanished keys are dropped, and new keys enter at
/// their sorted place (by `now`, ties by today's `ranksBefore` rule). A key climbs past the one above only when
/// min(now, before) of it > max(now, before) of the one above × (1 + rel) + abs, i.e. it leads on both
/// readings. A key that leads by > 2× AND > `jump` on `now` moves at once. `pinned` keys keep their index
/// while the others reorder around them. `frozen` returns `previous` minus vanished keys, plus new keys
/// appended at the end. `groupsLast` (memory) keeps negative keys (group rows) after all apps.
/// One insertion pass, O(n²) on ~60 rows (O(n) when little changed). A key missing from `before`
/// counts its `now` value for both readings.
public func stableRanking(previous: [Int32], now: [Int32: Double], before: [Int32: Double],
                          rule: RankHysteresis, pinned: Set<Int32> = [], frozen: Bool = false,
                          groupsLast: Bool = false) -> [Int32] {
    var seen = Set<Int32>()
    let kept = previous.filter { now[$0] != nil && seen.insert($0).inserted }
    // `now` has unique keys, so this sort decides ties by key alone: deterministic.
    let fresh = now.keys.filter { !seen.contains($0) }.sorted {
        precedes($0, $1, now: now, groupsLast: groupsLast)
    }

    if frozen {
        guard groupsLast else { return kept + fresh }
        return kept.filter { $0 > 0 } + fresh.filter { $0 > 0 } + kept.filter { $0 < 0 } + fresh.filter { $0 < 0 }
    }

    let pinnedSlots = previous.enumerated()
        .filter { pinned.contains($0.element) && now[$0.element] != nil }
        .map { (key: $0.element, index: $0.offset) }
    var list = kept.filter { !pinned.contains($0) }
    if list.isEmpty {
        list = fresh.filter { !pinned.contains($0) }
    } else {
        for key in fresh where !pinned.contains(key) {
            let at = list.firstIndex { precedes(key, $0, now: now, groupsLast: groupsLast) } ?? list.count
            list.insert(key, at: at)
        }
    }

    func value(_ key: Int32) -> Double { now[key] ?? 0 }
    func low(_ key: Int32) -> Double { min(value(key), before[key] ?? value(key)) }
    func high(_ key: Int32) -> Double { max(value(key), before[key] ?? value(key)) }
    func climbs(_ a: Int32, over b: Int32) -> Bool {
        if groupsLast, (a < 0) != (b < 0) { return a > 0 }
        if low(a) > high(b) * (1 + rule.rel) + rule.abs { return true }
        return value(a) > 2 * value(b) && value(a) - value(b) > rule.jump
    }
    if list.count > 1 {
        for i in 1..<list.count {
            var j = i
            while j > 0, climbs(list[j], over: list[j - 1]) {
                list.swapAt(j, j - 1)
                j -= 1
            }
        }
    }

    // Pinned keys go back to their old index (an app stays before the group rows).
    for slot in pinnedSlots.sorted(by: { $0.index < $1.index }) {
        let limit = groupsLast && slot.key > 0 ? list.lazy.filter { $0 > 0 }.count : list.count
        list.insert(slot.key, at: min(slot.index, limit))
    }
    for key in fresh where pinned.contains(key) && !list.contains(key) {
        let at = list.firstIndex { precedes(key, $0, now: now, groupsLast: groupsLast) } ?? list.count
        list.insert(key, at: at)
    }
    return list
}

/// The plain sort order: by value, descending; on ties apps before groups, then by key.
/// With `groupsLast`, every app comes before every group.
private func precedes(_ a: Int32, _ b: Int32, now: [Int32: Double], groupsLast: Bool) -> Bool {
    if groupsLast, (a < 0) != (b < 0) { return a > 0 }
    let va = now[a] ?? 0, vb = now[b] ?? 0
    if va != vb { return va > vb }
    if (a < 0) != (b < 0) { return a > 0 }
    return a < b
}
