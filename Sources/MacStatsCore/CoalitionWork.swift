import Foundation

/// Work a coalition did over one interval that its live, readable processes don't account for:
/// helpers that exited (a build's compilers, a killed `yes`) and members we can't read (a
/// Terminal tab's root `login`).
public struct CoalitionResidual: Equatable {
    public var ns: Double
    public var nj: Double

    public init(ns: Double, nj: Double) {
        self.ns = ns; self.nj = nj
    }
}

/// Turns successive coalition readings (`readCoalitionUsage`) into each coalition's residual,
/// the exact replacement for the breakdown's estimates of exited work (reaped-child credit,
/// `exitWorkCredit`). The kernel keeps a coalition's counters for every task that was ever in
/// it, so its growth minus its live members' own growth is what the ones that are gone did.
///
/// The counters' struct isn't public, so readings are checked against the live processes:
/// a coalition that grew less than its own live members (beyond timing slack) or went
/// backwards is a strike, and after `maxStrikes` coalitions are off for this tracker's life,
/// leaving the estimates. A residual under `floor` is reading-time skew, not exits: the
/// processes are read a few ms before their coalitions.
public struct CoalitionTracker {
    public static let maxStrikes = 3
    /// Live members may read up to this much more than their coalition (reading-time skew)…
    static let slackRatio = 1.25
    /// …plus this much per second of interval: 10 ms of CPU, 10 mJ of energy.
    static let slackPerSecond = 10_000_000.0
    /// A residual below this share of the coalition's growth (plus `floorPerSecond`) is noise.
    static let floorRatio = 0.03
    static let floorPerSecond = 2_000_000.0   // 2 ms of CPU, 2 mJ of energy, per second

    private var previous: [UInt64: CoalitionUsage] = [:]
    public private(set) var strikes = 0
    public var isEnabled: Bool { strikes < Self.maxStrikes }

    public init() {}

    /// `readings`: this scan's counters per coalition (unreadable ones missing). `liveNs` /
    /// `liveNj`: what this scan's live processes in each coalition did over the interval, by
    /// their own counters. Returns the residual of each coalition it can vouch for; members
    /// of any other coalition keep the estimate. The first call (no interval) only records.
    public mutating func residuals(readings: [UInt64: CoalitionUsage], liveNs: [UInt64: Double],
                                   liveNj: [UInt64: Double], elapsed: Double) -> [UInt64: CoalitionResidual] {
        let last = previous
        previous = readings
        guard isEnabled, elapsed > 0 else { return [:] }
        let slack = Self.slackPerSecond * elapsed
        let floor = Self.floorPerSecond * elapsed
        var result: [UInt64: CoalitionResidual] = [:]
        for (id, now) in readings {
            guard let old = last[id] else { continue }   // new coalition: no baseline yet
            guard now.cpuTimeNs >= old.cpuTimeNs, now.energyNj >= old.energyNj else {
                strikes += 1
                continue
            }
            let ns = Double(now.cpuTimeNs - old.cpuTimeNs)
            let nj = Double(now.energyNj - old.energyNj)
            let ownNs = liveNs[id] ?? 0, ownNj = liveNj[id] ?? 0
            guard ownNs <= ns * Self.slackRatio + slack, ownNj <= nj * Self.slackRatio + slack else {
                strikes += 1
                continue
            }
            func residual(_ total: Double, _ own: Double) -> Double {
                let r = total - own
                return r >= total * Self.floorRatio + floor ? r : 0
            }
            result[id] = CoalitionResidual(ns: residual(ns, ownNs), nj: residual(nj, ownNj))
        }
        return isEnabled ? result : [:]
    }
}
