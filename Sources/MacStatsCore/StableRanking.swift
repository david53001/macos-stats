import Foundation

/// How strongly a breakdown resists re-ranking. A row must lead by BOTH margins: `rel` of the row
/// above's value and `abs`. The values are the rows' printed (held) values, which already take two
/// scans to change (`HeldReading`), so one reading is enough here. `abs` is 1.5 printed steps of a small row
/// (`breakdownValueStep`: 0.1 pp, 0.01 W): rows ranked by their printed values climb over a row
/// 2 steps lower, not over one a single step lower. Memory keeps 5 % / 20 MB (its list is still and sorted).
public struct RankHysteresis: Equatable, Sendable {
    public var rel: Double      // relative margin
    public var abs: Double      // absolute margin (metric units)
    public var jump: Double     // a lead this big (and > 1.5×) moves at once, on one reading
    /// Process rows printed below this pass a neighbour only by the margins, never by the inversion
    /// timeout (`ListRanking`): an expanded app's 0.1–0.4 % helpers crossing each other is noise.
    public var promotionFloor: Double

    public init(rel: Double, abs: Double, jump: Double, promotionFloor: Double = 0) {
        self.rel = rel; self.abs = abs; self.jump = jump; self.promotionFloor = promotionFloor
    }

    public static let cpu    = RankHysteresis(rel: 0.15, abs: 0.15, jump: 1, promotionFloor: 0.5)   // pp of the whole Mac
    public static let memory = RankHysteresis(rel: 0.05, abs: 20 * 1_048_576, jump: 200 * 1_048_576)
    public static let energy = RankHysteresis(rel: 0.15, abs: 0.015, jump: 0.05, promotionFloor: 0.05)   // W

    /// Only a big jump moves (`ListRanking`'s reorder dwell).
    public var jumpsOnly: RankHysteresis { RankHysteresis(rel: 0, abs: .greatestFiniteMagnitude, jump: jump) }

    public static func `for`(_ metric: BreakdownMetric) -> RankHysteresis {
        switch metric {
        case .cpu: return .cpu
        case .memory: return .memory
        case .energy: return .energy
        }
    }
}

/// How a breakdown row's printed value is held (`HeldReading`): it changes once the reading is at least
/// max(`band` × the printed step, min(`relBand` × the value, `cap`)) away, confirmed over two scans.
public struct RowHold: Equatable, Sendable {
    public var band: Double
    public var relBand: Double
    public var cap: Double

    public static let cpu    = RowHold(band: 0.75, relBand: 0.10, cap: 2)          // pp
    public static let memory = RowHold(band: 0.75, relBand: 0.03, cap: .infinity)
    public static let energy = RowHold(band: 0.75, relBand: 0.10, cap: 0.2)        // W

    public static func `for`(_ metric: BreakdownMetric) -> RowHold {
        switch metric {
        case .cpu: return .cpu
        case .memory: return .memory
        case .energy: return .energy
        }
    }
}

/// Re-ranks keys with hysteresis. Starts from `previous`: vanished keys are dropped, and new keys enter at
/// their sorted place (by `now`, ties by `precedes`). A key "clearly beats" a key when its value >
/// the other's × (1 + rel) and + abs, i.e. it leads by both margins; or when it leads by > 1.5× AND
/// > `jump`.
/// Each key moves up past the run of keys directly above it that it outranks on `now`, as far as the
/// highest of them it clearly beats: so a key it can't clearly beat doesn't block one further up that
/// it can, and it never passes a key with a higher value.
/// With steady readings one pass leaves no key clearly beaten by a key below it (tested).
/// A `promoted` key climbs over every key directly above it that it outranks, margins or not.
/// The first `fixed` kept keys keep their places; the rest rank below them, and new keys join there.
/// `frozen` (= `fixed` all) returns `previous` minus vanished keys, plus new keys appended at the end (after
/// the group rows too).
/// Otherwise `groupsLast` (memory) keeps negative keys (group rows) after all apps. One insertion pass, O(n²) on ~60 rows (O(n) when little changed).
public func stableRanking(previous: [Int32], now: [Int32: Double],
                          rule: RankHysteresis, frozen: Bool = false, fixed: Int = 0,
                          groupsLast: Bool = false, promoted: Set<Int32> = []) -> [Int32] {
    var seen = Set<Int32>()
    let kept = previous.filter { now[$0] != nil && seen.insert($0).inserted }
    // `now` has unique keys, so this sort decides ties by key alone: deterministic.
    let fresh = now.keys.filter { !seen.contains($0) }.sorted {
        precedes($0, $1, now: now, groupsLast: groupsLast)
    }

    // Frozen: new keys go after every kept one, group rows included, so nothing under the pointer moves.
    let fixed = frozen ? kept.count : min(max(0, fixed), kept.count)
    var list = kept
    if list.isEmpty {
        list = fresh
    } else {
        for key in fresh {
            let at = list[fixed...].firstIndex { precedes(key, $0, now: now, groupsLast: groupsLast) } ?? list.count
            list.insert(key, at: at)
        }
    }

    func value(_ key: Int32) -> Double { now[key] ?? 0 }
    func outranks(_ a: Int32, _ b: Int32) -> Bool {
        if groupsLast, (a < 0) != (b < 0) { return a > 0 }
        return value(a) > value(b)
    }
    func climbs(_ a: Int32, over b: Int32) -> Bool {
        if groupsLast, (a < 0) != (b < 0) { return a > 0 }
        if promoted.contains(a) { return true }
        if value(a) > max(value(b) * (1 + rule.rel), value(b) + rule.abs) { return true }
        return value(a) > 1.5 * value(b) && value(a) - value(b) > rule.jump
    }
    if list.count > 1 {
        for i in max(1, fixed)..<list.count {
            let key = list[i]
            var j = i, target = i
            while j > fixed, outranks(key, list[j - 1]) {
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
