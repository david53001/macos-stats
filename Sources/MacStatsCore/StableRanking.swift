import Foundation

/// How strongly a breakdown resists re-ranking. A row must lead by BOTH margins: `rel` of the row
/// above's value and `abs`, on two readings. `abs` is 1.5 printed steps of a small row
/// (`breakdownValueStep`: 0.1 pp, 0.01 W): rows ranked by their printed values climb over a row
/// 2 steps lower, not over one a single step lower. Memory keeps 5 % / 20 MB (its list is still and sorted).
public struct RankHysteresis: Equatable, Sendable {
    public var rel: Double      // relative margin
    public var abs: Double      // absolute margin (metric units)
    public var jump: Double     // a lead this big (and > 1.5×) moves at once, on one reading

    public init(rel: Double, abs: Double, jump: Double) {
        self.rel = rel; self.abs = abs; self.jump = jump
    }

    public static let cpu    = RankHysteresis(rel: 0.15, abs: 0.15, jump: 1)         // pp of the whole Mac
    public static let memory = RankHysteresis(rel: 0.05, abs: 20 * 1_048_576, jump: 200 * 1_048_576)
    public static let energy = RankHysteresis(rel: 0.15, abs: 0.015, jump: 0.05)     // W

    public static func `for`(_ metric: BreakdownMetric) -> RankHysteresis {
        switch metric {
        case .cpu: return .cpu
        case .memory: return .memory
        case .energy: return .energy
        }
    }
}

/// Re-ranks keys with hysteresis. Starts from `previous`: vanished keys are dropped, and new keys enter at
/// their sorted place (by `now`, ties by today's `ranksBefore` rule). A key "clearly beats" a key when
/// min(now, before) of it > max(now, before) of the other × (1 + rel) and + abs, i.e. it leads by both
/// margins on both readings; or when it leads by > 1.5× AND > `jump` on `now` (moves at once: a big,
/// clear lead isn't held back a scan).
/// Each key moves up past the run of keys directly above it that it outranks on `now`, as far as the
/// highest of them it clearly beats: so a key it can't clearly beat doesn't block one further up that
/// it can, and it never passes a key with a higher value.
/// With steady readings one pass leaves no key clearly beaten by a key below it (tested).
/// `frozen` returns `previous` minus vanished keys, plus new keys appended at the end. `groupsLast` (memory) keeps negative keys
/// (group rows) after all apps. One insertion pass, O(n²) on ~60 rows (O(n) when little changed).
/// A key missing from `before` counts its `now` value for both readings.
public func stableRanking(previous: [Int32], now: [Int32: Double], before: [Int32: Double],
                          rule: RankHysteresis, frozen: Bool = false,
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

    var list = kept
    if list.isEmpty {
        list = fresh
    } else {
        for key in fresh {
            let at = list.firstIndex { precedes(key, $0, now: now, groupsLast: groupsLast) } ?? list.count
            list.insert(key, at: at)
        }
    }

    func value(_ key: Int32) -> Double { now[key] ?? 0 }
    func low(_ key: Int32) -> Double { min(value(key), before[key] ?? value(key)) }
    func high(_ key: Int32) -> Double { max(value(key), before[key] ?? value(key)) }
    func outranks(_ a: Int32, _ b: Int32) -> Bool {
        if groupsLast, (a < 0) != (b < 0) { return a > 0 }
        return value(a) > value(b)
    }
    func climbs(_ a: Int32, over b: Int32) -> Bool {
        if groupsLast, (a < 0) != (b < 0) { return a > 0 }
        if low(a) > max(high(b) * (1 + rule.rel), high(b) + rule.abs) { return true }
        return value(a) > 1.5 * value(b) && value(a) - value(b) > rule.jump
    }
    if list.count > 1 {
        for i in 1..<list.count {
            let key = list[i]
            var j = i, target = i
            while j > 0, outranks(key, list[j - 1]) {
                j -= 1
                if climbs(key, over: list[j]) { target = j }
            }
            if target < i {
                list.remove(at: i)
                list.insert(key, at: target)
            }
        }
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
