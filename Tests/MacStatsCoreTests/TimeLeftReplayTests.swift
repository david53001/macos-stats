import Testing
import Foundation
@testable import MacStatsCore

/// Time left replayed on this Mac's real battery history (M3, 2026-10-05). The constants in
/// `BatteryEstimator` were tuned on 5 days of it (see its doc comment); these pin the result on
/// two pieces of it and on the load changes the tuning had to stay honest about.
@Suite struct TimeLeftReplayTests {
    /// Reviewer B's live window (round 2, 21:41–21:57): gauge intervals (s), their average
    /// whole-Mac draw (mW, from `AccumulatedSystemLoad`) and the charge left (Wh × 100), with the
    /// app's persisted typical drain at the time (3.55 W over 3935 s). The window's measured
    /// drain was 3.52 W, so 25.90 Wh lasts 441 min; the previous constants ended at 8 h 17 m
    /// (+13 %).
    static let liveWindow: [(seconds: Double, milliwatts: Double, centiWh: Double)] = [
        (60, 4735, 2625), (60, 5256, 2595), (48, 4964, 2586), (60, 3371, 2643), (60, 4428, 2626),
        (60, 3419, 2628), (60, 2794, 2607), (60, 4393, 2592), (60, 3457, 2616), (60, 3652, 2596),
        (60, 3486, 2597), (60, 2083, 2607), (63, 3608, 2561), (60, 3034, 2594), (60, 1950, 2595),
        (60, 2018, 2590),
    ]

    @Test func liveWindowEndsNearTheMeasuredDrain() {
        var e = BatteryEstimator(typicalWatts: 3.55, typicalSeconds: 3935)
        var shown: [Int] = []
        for r in Self.liveWindow {
            e.ingest(watts: r.milliwatts / 1000, seconds: r.seconds)
            shown.append(e.minutesLeft(remainingWh: r.centiWh / 100, macOSMinutes: nil)!)
        }
        let honest = 25.90 / 3.52 * 60
        #expect(abs(Double(shown.last!) / honest - 1) < 0.08)   // 469 min (+6 %)
    }

    /// 207 consecutive awake on-battery gauge intervals (3 h 18 m, 18:38–21:56) from this Mac's
    /// powerlog (`PLBatteryAgent_EventBackward_Battery`): seconds, and the drain over the
    /// interval in mW from the coulomb counter (`PassedCharge`, whole mAh, so single minutes are
    /// quantised in ~0.73 W steps).
    static let session: [(seconds: Double, milliwatts: Double)] = [
        (59, 2272), (60, 3693), (60, 4425), (60, 2211), (60, 2211), (60, 2210), (60, 2209), (60, 2208), (60, 1472),
        (60, 2207), (60, 2943), (60, 2206), (60, 2205), (60, 2204), (60, 2204), (60, 2204), (60, 2203), (60, 2203),
        (60, 2203), (60, 2197), (60, 9415), (60, 9407), (60, 2922), (60, 2926), (60, 2926), (60, 2927), (60, 2926),
        (60, 4385), (60, 2922), (60, 2919), (60, 5104), (60, 3645), (59, 2223), (60, 1460), (60, 2191), (60, 1460),
        (60, 2190), (60, 1460), (60, 1460), (60, 2189), (60, 1461), (60, 2189), (60, 1459), (60, 2188), (60, 1459),
        (60, 1459), (54, 2434), (59, 1481), (60, 3629), (32, 12217), (59, 5149), (60, 2905), (60, 3627), (60, 3637),
        (60, 4360), (60, 5068), (60, 1447), (60, 2905), (60, 2180), (60, 1453), (60, 1452), (60, 2180), (60, 1453),
        (60, 2178), (60, 2178), (17, 2565), (60, 2176), (60, 1452), (60, 2176), (60, 2177), (60, 1450), (60, 2175),
        (60, 2176), (60, 4331), (13, 9972), (60, 7182), (60, 4324), (60, 2170), (60, 4338), (60, 2168), (60, 4337),
        (60, 4333), (60, 5052), (48, 4471), (59, 4361), (60, 2881), (60, 2880), (60, 2163), (59, 2198), (60, 4326),
        (60, 3603), (60, 2162), (33, 6560), (59, 3653), (60, 3601), (60, 2879), (60, 6472), (60, 4293), (60, 4293),
        (60, 3587), (60, 2874), (35, 3688), (59, 3628), (60, 2871), (60, 2153), (60, 2154), (60, 3585), (60, 2867),
        (60, 3587), (59, 2185), (60, 2868), (60, 2151), (60, 2150), (26, 3329), (59, 3597), (60, 4238), (60, 5699),
        (60, 2862), (60, 2860), (60, 2859), (60, 2859), (60, 2859), (25, 3455), (59, 2879), (60, 3539), (60, 4975),
        (60, 3565), (60, 2851), (40, 5366), (59, 5762), (60, 8512), (60, 2841), (60, 3556), (60, 2133), (48, 6204),
        (59, 2825), (60, 5610), (60, 2835), (60, 2128), (60, 2128), (60, 2127), (60, 4251), (60, 4225), (60, 3520),
        (60, 2123), (60, 2123), (60, 1415), (60, 2122), (60, 2123), (60, 2122), (60, 1415), (42, 2030), (59, 2153),
        (60, 2120), (60, 2120), (60, 2119), (60, 2119), (60, 1413), (56, 4516), (59, 5681), (60, 2113), (60, 2116),
        (60, 3503), (60, 4200), (60, 2807), (17, 12385), (59, 7107), (60, 2811), (60, 9003), (60, 2766), (60, 6283),
        (18, 9298), (59, 4963), (60, 4206), (60, 5602), (60, 2803), (60, 5609), (60, 4901), (60, 4199), (60, 2100),
        (60, 2100), (37, 3420), (59, 3554), (60, 2101), (60, 2076), (60, 4866), (60, 2093), (60, 3484), (39, 6469),
        (59, 4966), (60, 2098), (60, 4175), (60, 2780), (60, 4891), (60, 5547), (49, 5059), (59, 2815), (60, 4187),
        (60, 3490), (60, 2790), (60, 4168), (60, 3471), (60, 3487), (60, 3487), (60, 2092), (60, 3467), (4, 10463),
    ]

    /// After each reading from 10 min in: |ln(expected draw / the draw over the next 60 min)|,
    /// and |ln| of how much the expected draw moved over the next 10 minutes.
    private func score() -> (error: Double, swing: Double, maxSwing: Double) {
        var e = BatteryEstimator(typicalWatts: 4, typicalSeconds: 36_000)
        var points: [(t: Double, watts: Double)] = []
        var energy: [(t: Double, wh: Double)] = [(0, 0)]
        for r in Self.session {
            e.ingest(watts: r.milliwatts / 1000, seconds: r.seconds)
            let t = energy.last!.t + r.seconds
            points.append((t, e.expectedWatts!))
            energy.append((t, energy.last!.wh + r.milliwatts / 1000 * r.seconds / 3600))
        }
        func energyAt(_ time: Double) -> (t: Double, wh: Double) { energy.last { $0.t <= time }! }
        var errors: [Double] = [], swings: [Double] = []
        for p in points where p.t >= 600 {
            let a = energyAt(p.t), b = energyAt(p.t + 3600)
            if b.t - a.t >= 0.95 * 3600 { errors.append(abs(log(p.watts / ((b.wh - a.wh) * 3600 / (b.t - a.t))))) }
            if let later = points.first(where: { $0.t >= p.t + 600 }), later.t <= p.t + 660 {
                swings.append(abs(log(later.watts / p.watts)))
            }
        }
        return (errors.reduce(0, +) / Double(errors.count), swings.reduce(0, +) / Double(swings.count),
                swings.max()!)
    }

    @Test func realSessionIsCloserAndSteadier() {
        // Previous constants on this session: error 0.139, swing 0.197 per 10 min (max 0.58).
        // Now: 0.113 and 0.135 (max 0.37).
        let s = score()
        #expect(s.error < 0.125)
        #expect(s.swing < 0.16)
        #expect(s.maxSwing < 0.45)
    }

    /// Feeds `minutes` one-minute intervals at `watts`; returns the time left's error after each
    /// of `checkpoints` minutes (positive = too long, the harmful direction).
    private func timeLeftError(_ e: inout BatteryEstimator, watts: Double, minutes: Int,
                               at checkpoints: [Int]) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for m in 1...minutes {
            e.ingest(watts: watts, seconds: 60)
            if checkpoints.contains(m) { out[m] = watts / e.expectedWatts! - 1 }
        }
        return out
    }

    @Test func followsARealLoadQuickly() {
        // A render started right after unplugging (usually 5 W): within 20 % by 10 minutes.
        var fresh = BatteryEstimator(typicalWatts: 5, typicalSeconds: 36_000)
        #expect(timeLeftError(&fresh, watts: 15, minutes: 10, at: [10])[10]! < 0.2)
        // The same jump after an hour at the usual 4 W: most of the way within 30 minutes.
        var e = BatteryEstimator(typicalWatts: 4, typicalSeconds: 36_000)
        _ = timeLeftError(&e, watts: 4, minutes: 60, at: [])
        let err = timeLeftError(&e, watts: 12, minutes: 30, at: [10, 30])
        #expect(err[10]! < 0.45 && err[30]! < 0.15)
    }

    @Test func believesAQuieterSessionWithinHalfAnHour() {
        // A light session (1.8 W) on a Mac that usually draws 5 W, and a 4 W stretch after a
        // 30-minute 12 W build: pessimistic at first, within 25 % after 30 minutes.
        var light = BatteryEstimator(typicalWatts: 5, typicalSeconds: 36_000)
        #expect(timeLeftError(&light, watts: 1.8, minutes: 30, at: [30])[30]! > -0.25)
        var build = BatteryEstimator(typicalWatts: 5, typicalSeconds: 36_000)
        _ = timeLeftError(&build, watts: 12, minutes: 30, at: [])
        #expect(timeLeftError(&build, watts: 4, minutes: 30, at: [30])[30]! > -0.25)
    }

    @Test func oneQuietMinuteEarlyOnMovesLittle() {
        // Reviewer A: four minutes into a session one 2.08 W minute moved the estimate +13 % on
        // real data. In this clean version the previous constants moved it +8.6 %, now +4.7 %.
        var e = BatteryEstimator(typicalWatts: 3.55, typicalSeconds: 3935)
        for _ in 0..<4 { e.ingest(watts: 3.5, seconds: 60) }
        let before = e.expectedWatts!
        e.ingest(watts: 2.08, seconds: 60)
        #expect(before / e.expectedWatts! - 1 < 0.06)
    }
}
