import Testing
import Foundation
@testable import MacStatsCore

@Suite struct BatteryEstimatorTests {
    /// Feeds `minutes` of one-minute on-battery intervals at `watts`.
    private func feed(_ e: inout BatteryEstimator, watts: Double, minutes: Int) {
        for _ in 0..<minutes { e.ingest(watts: watts, seconds: 60) }
    }

    @Test func noDataMeansNoEstimate() {
        #expect(BatteryEstimator().expectedWatts == nil)
        #expect(BatteryEstimator().minutesLeft(remainingWh: 40, macOSMinutes: nil) == nil)
    }

    @Test func steadyDrainGivesWhLeftOverWatts() {
        var e = BatteryEstimator()
        feed(&e, watts: 5.6, minutes: 30)
        #expect(abs(e.expectedWatts! - 5.6) < 1e-9)
        #expect(e.minutesLeft(remainingWh: 28, macOSMinutes: 999) == 300)   // 28 Wh / 5.6 W = 5 h
    }

    @Test func pollutedTypicalCannotHideRealDrain() {
        // The bug: a "typical" learned at 2.5 W (plugged-in idle, sleep) got half the weight
        // against the real 5.6 W drain, so 5h52 of charge showed as 8h. Even if a typical that
        // low were genuine, the session now outweighs it after its first 20 minutes.
        var e = BatteryEstimator(typicalWatts: 2.54, typicalSeconds: 160_000)
        feed(&e, watts: 5.6, minutes: 24)
        let honest = 32.9 / 5.6 * 60   // 352 min
        let shown = Double(e.minutesLeft(remainingWh: 32.9, macOSMinutes: nil)!)
        #expect(abs(shown - honest) / honest < 0.15)   // the old blend showed 8h04 (+37 %)
        feed(&e, watts: 5.6, minutes: 48)
        let later = Double(e.minutesLeft(remainingWh: 26.0, macOSMinutes: nil)!)
        #expect(abs(later - 26.0 / 5.6 * 60) / (26.0 / 5.6 * 60) < 0.06)
    }

    @Test func aQuietMinuteDoesNotPromiseHours() {
        // 20 min at 10 W, then one idle minute at 3 W: macOS would divide by ~3 W.
        var e = BatteryEstimator()
        feed(&e, watts: 10, minutes: 20)
        e.ingest(watts: 3, seconds: 60)
        let w = e.expectedWatts!
        #expect(w > 9 && w < 10)
    }

    @Test func respondsToASustainedLoadStep() {
        var e = BatteryEstimator(typicalWatts: 5.6, typicalSeconds: 20_000)
        feed(&e, watts: 5.6, minutes: 30)
        feed(&e, watts: 12, minutes: 15)
        #expect(e.expectedWatts! > 9)   // most of the way to 12 W within 15 min
    }

    @Test func typicalTempersAFreshSession() {
        // A history of 8 W use, then a fresh unplug that has only seen 3 W for 2 minutes.
        var e = BatteryEstimator(typicalWatts: 8, typicalSeconds: 10 * 3600)
        feed(&e, watts: 3, minutes: 2)
        let w = e.expectedWatts!
        #expect(w > 4.5 && w < 8)
    }

    @Test func aQuietStretchDoesNotHideRealUseLater() {
        // The user's "7 h left while it drains much faster": an hour at idle draw (1.7 W,
        // display on) and then real use at 5.5 W. The since-unplug mean the estimate used to
        // rest on read +38 / +28 / +13 % after 20 / 40 / 120 minutes of use.
        var e = BatteryEstimator()
        feed(&e, watts: 1.7, minutes: 60)
        let honest = 36 / 5.5 * 60   // 393 min
        func error() -> Double { Double(e.minutesLeft(remainingWh: 36, macOSMinutes: nil)!) / honest - 1 }
        feed(&e, watts: 5.5, minutes: 20)
        #expect(error() < 0.25)
        feed(&e, watts: 5.5, minutes: 20)
        #expect(error() < 0.12)
        feed(&e, watts: 5.5, minutes: 80)
        #expect(error() < 0.03)
    }

    @Test func typicalCoversTheFirstTwoMinutes() {
        // Right after unplugging, one gauge reading can be a spike; neither it nor macOS's
        // short-horizon figure (799 min, then a jump to 482) should set the time left.
        var e = BatteryEstimator(typicalWatts: 5, typicalSeconds: 3600)
        e.ingest(watts: 9.5, seconds: 60)
        let settling = e.minutesLeft(remainingWh: 40, macOSMinutes: 333)!
        // 40 Wh / ~5.09 W: the spike counts for its 1 minute of the hour typical rests on.
        #expect(settling >= 468 && settling <= 476)
        e.ingest(watts: 5, seconds: 60)
        #expect(e.minutesLeft(remainingWh: 40, macOSMinutes: 333)! < 460)    // now its own blend
    }

    @Test func macOSFigureCoversTheFirstTwoMinutesWithoutATypical() {
        var e = BatteryEstimator()
        e.ingest(watts: 5, seconds: 60)
        #expect(e.minutesLeft(remainingWh: 40, macOSMinutes: 333) == 333)
        // Without a usable macOS figure it falls back to its own estimate.
        #expect(e.minutesLeft(remainingWh: 40, macOSMinutes: nil) == 480)
        e.ingest(watts: 5, seconds: 60)
        #expect(e.minutesLeft(remainingWh: 40, macOSMinutes: 333) == 480)
    }

    @Test func aFirstIntervalSpikeCountsOnlyForItsOwnMinute() {
        // The unplug spike (9.5 W) then a steady 1.8 W, no typical yet. Seeding each average
        // with the first reading at full weight read −66 % after 10 min and −50 % after 30.
        var e = BatteryEstimator()
        e.ingest(watts: 9.5, seconds: 60)
        feed(&e, watts: 1.8, minutes: 9)
        let honest = 30 / 1.8 * 60
        func error() -> Double { Double(e.minutesLeft(remainingWh: 30, macOSMinutes: nil)!) / honest - 1 }
        #expect(error() > -0.25)   // the spike is 1 of 10 minutes of real drain
        feed(&e, watts: 1.8, minutes: 20)
        #expect(abs(error()) < 0.06)
    }

    @Test func aSmallFirstIntervalBumpFadesWithinTenMinutes() {
        // Live: 4.9 W for the first gauge interval (a compile), then ~3.5 W.
        var e = BatteryEstimator()
        e.ingest(watts: 4.9, seconds: 60)
        feed(&e, watts: 3.5, minutes: 9)
        #expect(abs(e.expectedWatts! / 3.5 - 1) < 0.05)
    }

    @Test func persistedTypicalIsNotSeededByTheFirstReading() {
        // First launch after a build: a 12 W tail, then 3 h at 4.6 W. The old seeding kept the
        // persisted typical at 7.3 W, so the next session opened ~37 % short.
        var e = BatteryEstimator()
        e.ingest(watts: 12, seconds: 60)
        feed(&e, watts: 4.6, minutes: 179)
        #expect(abs(e.typicalWatts! / 4.6 - 1) < 0.05)
    }

    @Test func endSessionKeepsTypicalOnly() {
        var e = BatteryEstimator()
        feed(&e, watts: 6, minutes: 10)
        e.endSession()
        #expect(e.sessionSeconds == 0)
        #expect(e.sessionAverageWatts == nil)
        #expect(e.shortWatts == nil)
        #expect(e.typicalWatts == 6)
        #expect(e.typicalSeconds == 600)
        #expect(e.expectedWatts == 6)   // typical alone until the new session has data
    }

    @Test func sessionAverageIsEnergyWeighted() {
        var e = BatteryEstimator()
        e.ingest(watts: 10, seconds: 60)
        e.ingest(watts: 4, seconds: 120)
        #expect(abs(e.sessionAverageWatts! - 6) < 1e-9)
    }

    @Test func ignoresNonsense() {
        var e = BatteryEstimator()
        e.ingest(watts: 0, seconds: 60)
        e.ingest(watts: .nan, seconds: 60)
        e.ingest(watts: 5, seconds: 0)
        #expect(e.expectedWatts == nil)
    }
}

@Suite struct GaugeIntervalTests {
    private func t(_ time: Int, accum: UInt64? = nil, count: UInt64? = nil) -> BatteryTelemetry {
        BatteryTelemetry(updateTime: time, accumulatedSystemLoad: accum, systemLoadCount: count)
    }

    @Test func awakeGaugeStepIsUsable() {
        #expect(gaugeInterval(from: t(1000, accum: 0, count: 0), to: t(1060, accum: 330_000, count: 60)) == 60)
    }

    @Test func intervalSpanningSleepIsRejected() {
        // The gauge's sums keep ticking through sleep, so this would average the sleep (~0.05 W).
        #expect(gaugeInterval(from: t(1000, accum: 0, count: 0), to: t(4400, accum: 170_000, count: 3400)) == nil)
    }

    @Test func sumsThatSpanSleepAreRejectedEvenIfTimestampsLookClose() {
        #expect(gaugeInterval(from: t(1000, accum: 0, count: 0), to: t(1060, accum: 0, count: 3400)) == nil)
    }

    @Test func sameOrBackwardsTimestampIsNotAnInterval() {
        #expect(gaugeInterval(from: t(1000), to: t(1000)) == nil)
        #expect(gaugeInterval(from: t(1000), to: t(900)) == nil)
    }

    @Test func intelWithoutSumsUsesTimestampsOnly() {
        #expect(gaugeInterval(from: t(1000), to: t(1085)) == 85)
    }
}

@Suite struct ChargeTimeTests {
    /// The current the model expects at raw level `s` for a charge that starts at `base` mA
    /// (−40 % of the level up to the 80 % knee, then linear to 0 at full).
    private func modelMA(_ s: Double, base: Double = 2200) -> Double {
        s <= 0.8 ? base * (1 - 0.4 * s) : base * 0.68 * (1 - s) / 0.2
    }

    private func minutes(at s: Double, mA: Double, maxMAh: Int = 4400, target: Int = 100) -> Int? {
        minutesToTarget(currentMAh: Int((s * Double(maxMAh)).rounded()), maxMAh: maxMAh,
                        chargeMA: mA, targetPercent: target)
    }

    /// Minutes the model takes from raw level `a` to `b` (a numeric integral, independent of
    /// the closed form under test).
    private func modelMinutes(from a: Double, to b: Double, maxMAh: Double = 4400) -> Double {
        let n = 200, h = (b - a) / Double(n)
        return (0..<n).reduce(0) { $0 + h / modelMA(a + (Double($1) + 0.5) * h) } * maxMAh * 60
    }

    @Test func withoutDeclineBelowTheKneeItIsConstantCurrent() {
        // 50 % → raw 80 % (81 % shown) of 4000 mAh at 2000 mA: 1200 mAh / 2000 mA = 36 min.
        #expect(minutesToTarget(currentMAh: 2000, maxMAh: 4000, chargeMA: 2000, targetPercent: 81, decline: 0) == 36)
    }

    @Test func noCliffAtTheKnee() {
        // The shipped v1.1.0 formula said 60 min at 79 % and 26 min at 80 % (2000 mA, 4430 mAh;
        // reviewer B's table). One percent at 2 A takes ~1.3 min; with the measured current
        // held (the average lags a little), the estimate may drop by that and a little more.
        for target in [85, 100] {
            let at79 = minutes(at: 0.79, mA: 2000, maxMAh: 4430, target: target)!
            let at80 = minutes(at: 0.80, mA: 2000, maxMAh: 4430, target: target)!
            #expect(at79 >= at80 && at79 - at80 <= 3)
        }
    }

    @Test func continuousAndMonotoneOverTheWholeCharge() {
        // Charge stepped 1 % at a time, with the current the model expects at each level: every
        // step lowers the estimate by the time that 1 % takes, within rounding.
        for target in [85, 100] {
            var previous: (s: Double, minutes: Int)?
            for percent in 20...99 {
                let s = Double(percent) / 100
                guard let m = minutes(at: s, mA: modelMA(s), target: target) else { break }
                if let previous {
                    #expect(m <= previous.minutes)
                    let step = modelMinutes(from: previous.s, to: s)
                    #expect(Double(previous.minutes - m) <= step + 1.5, "at \(percent) %")
                }
                previous = (s, m)
            }
        }
    }

    @Test func sensibleNearFull() {
        // 99 % with the model's current (~75 mA, already under C/20 = 220 mA): the last trickle,
        // no figure (the app shows "Almost full", not a "1m" that could stick).
        #expect(minutes(at: 0.99, mA: modelMA(0.99)) == nil)
        // 99 % but still taking 400 mA: a few minutes, not an hour.
        let late = minutes(at: 0.99, mA: 400)!
        #expect(late >= 2 && late <= 8)
        // From the knee at 1500 mA to full: about an hour (the constant-voltage phase; this
        // stretch is the physical model, as no session here went past the 85 % limit awake).
        let fromKnee = minutes(at: 0.80, mA: 1500)!
        #expect(fromKnee >= 50 && fromKnee <= 75)
    }

    @Test func chargeLimitIsTheTarget() {
        // 74 % shown (raw 73 %) with an 85 % limit at 1846 mA. Real charges from raw 73 % to the
        // limit took 16 min at ~2000 mA (Sep 30) and 19 min at ~1700 mA (Oct 4); the shipped
        // formula said 25. macOS said 82 min (its figure ignores the limit).
        let m = minutesToTarget(currentMAh: 3212, maxMAh: 4400, chargeMA: 1846, targetPercent: 85)!
        #expect(m >= 15 && m <= 19)
    }

    @Test func limitTargetIsOneBelowTheShownPercentInRawCharge() {
        // While charging macOS shows ⌊raw⌋ + 1, and the 85 % limit stopped charging at raw 84.0 %.
        #expect(minutesToTarget(currentMAh: 3712, maxMAh: 4419, chargeMA: 1900, targetPercent: 85) == nil)
        // Sep 30, 19:56: plugged in at 65 % shown but raw 61.9 % (the shown percent holds the
        // discharging value for a few minutes); charging stopped at the limit 31.4 min later.
        // Placing the charge at the shown 65 % (the old way) said ~25 min.
        let m = minutesToTarget(currentMAh: 2736, maxMAh: 4419, chargeMA: 2000, targetPercent: 85)!
        #expect(abs(m - 31) <= 2)
    }

    @Test func atOrPastTheTargetOrNoCurrentIsNil() {
        #expect(minutesToTarget(currentMAh: 3800, maxMAh: 4000, chargeMA: 1000, targetPercent: 95) == nil)
        #expect(minutesToTarget(currentMAh: 2000, maxMAh: 4000, chargeMA: 20, targetPercent: 100) == nil)
        #expect(minutesToTarget(currentMAh: 2000, maxMAh: 0, chargeMA: 1000, targetPercent: 100) == nil)
    }

    @Test func chargeCurrentSkipsThePlugInTransient() {
        // Sep 28: 1096 mA right after plug-in, then 2278 and 2269 mA.
        var c = ChargeCurrent()
        c.ingest(milliamps: 1096, seconds: 0)
        #expect(c.milliamps == nil)                  // one reading isn't reported
        c.ingest(milliamps: 2278, seconds: 43)
        #expect(c.milliamps == 2278)                 // and the next one replaces it
        c.ingest(milliamps: 2269, seconds: 74)       // then a time-weighted running mean
        #expect(abs(c.milliamps! - 2272) < 3)
    }

    @Test func chargeCurrentAverageSmoothsADip() {
        var c = ChargeCurrent()
        c.ingest(milliamps: 2000, seconds: 0)
        for _ in 0..<11 { c.ingest(milliamps: 2000, seconds: 60) }
        c.ingest(milliamps: 1300, seconds: 60)       // one low gauge reading
        #expect(c.milliamps! > 1800)
        let afterDip = c.milliamps
        c.ingest(milliamps: -150, seconds: 60)       // discharging readings are ignored
        c.ingest(milliamps: 2000, seconds: 0)        // so is one that doesn't follow an awake interval
        #expect(c.milliamps == afterDip)
        c.reset()
        #expect(c.milliamps == nil)
    }
}

@Suite struct ChargeLimitTests {
    @Test func learnsWhereChargingStops() {
        #expect(learnedChargeLimit(previous: nil, previousState: .charging, state: .notCharging, percent: 85) == 85)
        #expect(learnedChargeLimit(previous: nil, previousState: .charging, state: .charged, percent: 80) == 80)
        // Still held on the next reading: kept.
        #expect(learnedChargeLimit(previous: 85, previousState: .notCharging, state: .notCharging, percent: 85) == 85)
    }

    @Test func fullOrVeryLowHoldsAreNotLimits() {
        #expect(learnedChargeLimit(previous: nil, previousState: .charging, state: .charged, percent: 100) == nil)
        #expect(learnedChargeLimit(previous: nil, previousState: .charging, state: .notCharging, percent: 30) == nil)
    }

    @Test func aFullMacDriftingOnACIsNotALimit() {
        // Full on AC, the charge drifts to 97 % while macOS still says charged.
        #expect(learnedChargeLimit(previous: nil, previousState: .charged, state: .charged, percent: 97) == nil)
        #expect(learnedChargeLimit(previous: nil, previousState: .charged, state: .notCharging, percent: 96) == nil)
    }

    @Test func pluggingInAboveALimitIsNotALimit() {
        // Plugged in at 90 % with an 85 % limit: held at 90 without ever charging.
        #expect(learnedChargeLimit(previous: 85, previousState: .discharging, state: .notCharging, percent: 90) == 85)
        #expect(learnedChargeLimit(previous: nil, previousState: nil, state: .notCharging, percent: 90) == nil)
    }

    @Test func chargingPastTheLimitForgetsIt() {
        #expect(learnedChargeLimit(previous: 85, previousState: .charging, state: .charging, percent: 86) == nil)
        #expect(learnedChargeLimit(previous: 85, previousState: .charging, state: .charging, percent: 70) == 85)
        #expect(learnedChargeLimit(previous: 85, previousState: .charging, state: .discharging, percent: 40) == 85)
    }

    /// powerd's policy file: an NSKeyedArchiver blob under "policies", as found on macOS 26.
    private func powerdFile(policies: [Any], boot: String = "BOOT-1") throws -> Data {
        var objects: [Any] = ["$null", ["NS.objects": policies.indices.map { _ in "x" }, "$class": "c"]]
        objects.append(contentsOf: policies)
        let archive: [String: Any] = ["$version": 100000, "$archiver": "NSKeyedArchiver", "$objects": objects]
        let inner = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        return try PropertyListSerialization.data(
            fromPropertyList: ["bootSessionUUID": boot, "policies": inner], format: .binary, options: 0)
    }

    @Test func readsAnActiveManualLimit() throws {
        let data = try powerdFile(policies: [["soclimit": 85, "terminated": false, "drain": true]])
        #expect(parsePowerdChargeLimit(data, bootSessionUUID: "BOOT-1") == .limit(85))
    }

    @Test func emptyPoliciesMeanNoLimit() throws {
        #expect(parsePowerdChargeLimit(try powerdFile(policies: []), bootSessionUUID: "BOOT-1") == .noLimit)
        let ended = try powerdFile(policies: [["soclimit": 85, "terminated": true]])
        #expect(parsePowerdChargeLimit(ended, bootSessionUUID: "BOOT-1") == .noLimit)
    }

    /// powerd's file on this Mac 20 s after plugging in (2026-10-05 22:03): a manual 85 % limit
    /// (end of charge) plus Optimized Charging's 80 % (not end of charge; the charge went on
    /// past 80 % to the limit).
    static let pluggedInFile = Data(base64Encoded: """
        YnBsaXN0MDDSAQIDBF8QD2Jvb3RTZXNzaW9uVVVJRFhwb2xpY2llc18QJEM2NkRBQzY2LTNCRUEtNEQ5Ny05Qjk3LTAzNDhDOTM3\
        OEJBQ08RArNicGxpc3QwMNQBAgMEBQYHClgkdmVyc2lvblkkYXJjaGl2ZXJUJHRvcFgkb2JqZWN0cxIAAYagXxAPTlNLZXllZEFy\
        Y2hpdmVy0QgJVHJvb3SAAasLDBMlJiowND0+QlUkbnVsbNINDg8SWk5TLm9iamVjdHNWJGNsYXNzohARgAKAB4AK2RQVFg4XGBka\
        GxwdHh8gISEgJFZyZWFzb25Vb3duZXJYc29jbGltaXRVZHJhaW5adGVybWluYXRlZF5ub0NoYXJnZVRvRnVsbF1pc0VuZE9mQ2hh\
        cmdlVXRva2VugAMRAmcQVYAGCQgICYAEXxARbWFudWFsQ2hhcmdlTGltaXTSJw4oKVxOUy51dWlkYnl0ZXNPEBDJ5hNsXflEbIGr\
        RZUtkCqggAXSKywtLlokY2xhc3NuYW1lWCRjbGFzc2VzVk5TVVVJRKItL1hOU09iamVjdNIrLDEyXxAQQ2hhcmdlQ3RybFBvbGlj\
        eaIzL18QEENoYXJnZUN0cmxQb2xpY3nZFBUWDhcYGRobNR02HyAhISE8gAgQUIAGCQgICIAJXxAYb3B0aW1pemVkQmF0dGVyeUNo\
        YXJnaW5n0j8OQClcTlMudXVpZGJ5dGVzTxAQNVLhrzHaSGKD3LULbbgZIoAF0issQ0ReTlNNdXRhYmxlQXJyYXmjQ0UvV05TQXJy\
        YXkACAARABoAJAApADIANwBJAEwAUQBTAF8AZQBqAHUAfAB/AIEAgwCFAJgAnwClAK4AtAC/AM4A3ADiAOQA5wDpAOsA7ADtAO4A\
        7wDxAQUBCgEXASoBLAExATwBRQFMAU8BWAFdAXABcwGGAZkBmwGdAZ8BoAGhAaIBowGlAcABxQHSAeUB5wHsAfsB/wAAAAAAAAIB\
        AAAAAAAAAEYAAAAAAAAAAAAAAAAAAAIHAAgADQAfACgATwAAAAAAAAIBAAAAAAAAAAUAAAAAAAAAAAAAAAAAAAMG
        """)!

    @Test func realPluggedInFileGivesTheLimitAndTheOptimizedChargingHold() {
        // That charge stopped at 80 % (the hold), 40 minutes later.
        let policy = parsePowerdChargePolicy(Self.pluggedInFile, bootSessionUUID: "C66DAC66-3BEA-4D97-9B97-0348C9378BAC")
        #expect(policy == PowerdChargePolicy(limit: .limit(85), hold: 80))
        #expect(parsePowerdChargePolicy(Self.pluggedInFile, bootSessionUUID: "OTHER-BOOT")
                == PowerdChargePolicy(limit: .unknown))
    }

    @Test func onlyAnOptimizedChargingHoldIsAHoldWithoutALimit() throws {
        let data = try powerdFile(policies: [["soclimit": 80, "terminated": false, "isEndOfCharge": false]])
        #expect(parsePowerdChargePolicy(data, bootSessionUUID: "BOOT-1") == PowerdChargePolicy(limit: .noLimit, hold: 80))
    }

    @Test func staleOrUnreadableFileIsUnknown() throws {
        let data = try powerdFile(policies: [["soclimit": 85, "terminated": false]], boot: "OLD")
        #expect(parsePowerdChargeLimit(data, bootSessionUUID: "BOOT-1") == .unknown)
        #expect(parsePowerdChargeLimit(Data("garbage".utf8), bootSessionUUID: "BOOT-1") == .unknown)
        #expect(parsePowerdChargeLimit(nil, bootSessionUUID: "BOOT-1") == .unknown)
    }
}

@Suite struct ChargeLimitResolverTests {
    private let now = Date(timeIntervalSince1970: 1_791_227_000)

    @Test func powerdLimitWinsAndIsRemembered() {
        var r = ChargeLimitResolver(observed: 80)
        #expect(r.resolve(powerd: .limit(85), pluggedInFor: 20, now: now) == .limit(85))
        #expect(r.remembered == 85 && r.rememberedAt == now)
    }

    @Test func rightAfterPlugInTheRememberedLimitBridgesTheEmptyFile() {
        // The round-2 case: the file still empty from the unplug reads "no limit". Remembered
        // from the last plug-in, the target is 85 % from the first reading.
        var r = ChargeLimitResolver(remembered: 85, rememberedAt: now.addingTimeInterval(-86_400))
        #expect(r.resolve(powerd: .noLimit, pluggedInFor: 5, now: now) == .limit(85))
        #expect(r.resolve(powerd: .unknown, pluggedInFor: 5, now: now) == .limit(85))
    }

    @Test func noLimitIsBelievedOnceTheFileHadTimeToFillIn() {
        // The limit was switched off: powerd's file stays empty after plug-in.
        var r = ChargeLimitResolver(remembered: 85, rememberedAt: now.addingTimeInterval(-86_400))
        #expect(r.resolve(powerd: .noLimit, pluggedInFor: 61, now: now) == .full)
        #expect(r.remembered == 100)
        #expect(r.resolve(powerd: .noLimit, pluggedInFor: 5, now: now) == .full)   // next plug-in
    }

    @Test func withNothingKnownTheTargetIsUnknown() {
        var r = ChargeLimitResolver()
        #expect(r.resolve(powerd: .noLimit, pluggedInFor: 5, now: now) == .unknown)
        #expect(r.resolve(powerd: .unknown, pluggedInFor: 3600, now: now) == .unknown)
    }

    @Test func withoutPowerdTheObservedStopIsUsed() {
        // Older macOS (no policy file): where charging was last seen to stop.
        var r = ChargeLimitResolver(observed: 80)
        #expect(r.resolve(powerd: .unknown, pluggedInFor: 3600, now: now) == .limit(80))
    }

    @Test func anOptimizedChargingHoldIsTheTargetUntilPassed() {
        // Live 2026-10-05: limit 85 %, hold 80 %; charging stopped at 80 %.
        var r = ChargeLimitResolver()
        #expect(r.resolve(powerd: .limit(85), hold: 80, percent: 56, pluggedInFor: 30, now: now) == .limit(80))
        #expect(r.resolve(powerd: .limit(85), hold: 80, percent: 80, pluggedInFor: 60, now: now) == .limit(80))
        // Earlier charges ran on past 80 %: then the limit is the target again.
        #expect(r.resolve(powerd: .limit(85), hold: 80, percent: 81, pluggedInFor: 600, now: now) == .limit(85))
        #expect(r.remembered == 85)   // only the end limit is remembered
        // With no limit set, the hold still comes first.
        var free = ChargeLimitResolver()
        #expect(free.resolve(powerd: .noLimit, hold: 80, percent: 60, pluggedInFor: 600, now: now) == .limit(80))
        #expect(free.resolve(powerd: .noLimit, hold: 80, percent: 81, pluggedInFor: 600, now: now) == .full)
    }

    @Test func aLongUnconfirmedMemoryExpires() {
        var r = ChargeLimitResolver(remembered: 85, rememberedAt: now.addingTimeInterval(-31 * 86_400))
        #expect(r.resolve(powerd: .unknown, pluggedInFor: 3600, now: now) == .unknown)
        #expect(ChargeLimitResolver(remembered: 0, rememberedAt: now).remembered == nil)   // nonsense
    }
}
