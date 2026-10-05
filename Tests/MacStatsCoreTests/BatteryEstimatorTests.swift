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
        #expect(w > 5 && w < 8)
    }

    @Test func macOSFigureCoversTheFirstTwoMinutes() {
        var e = BatteryEstimator(typicalWatts: 5, typicalSeconds: 3600)
        e.ingest(watts: 5, seconds: 60)
        #expect(e.minutesLeft(remainingWh: 40, macOSMinutes: 333) == 333)
        // Without a usable macOS figure it falls back to its own (typical-led) estimate.
        #expect(e.minutesLeft(remainingWh: 40, macOSMinutes: nil) == 480)
        e.ingest(watts: 5, seconds: 60)
        #expect(e.minutesLeft(remainingWh: 40, macOSMinutes: 333) == 480)
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
    @Test func constantCurrentBelowTheKnee() {
        // 50 % → 80 % of 4000 mAh at 2000 mA: 1200 mAh / 2000 mA = 36 min, no taper.
        #expect(minutesToTarget(currentMAh: 2000, maxMAh: 4000, chargeMA: 2000, targetPercent: 80) == 36)
    }

    @Test func taperAboveTheKnee() {
        // 3213 → 4400 at 1846 mA: 10 min to the knee, then 880 mAh at 45 % of the current.
        let m = minutesToTarget(currentMAh: 3213, maxMAh: 4400, chargeMA: 1846, targetPercent: 100)!
        #expect(m >= 70 && m <= 78)
    }

    @Test func chargeLimitIsTheTarget() {
        // The live case: 74 % with an 85 % limit at 1846 mA. macOS said 82 min (its figure
        // ignores the limit); 10 min to 80 % plus ~16 min tapered to 85 %. (pmset log, Sep 28:
        // 63 → 85 % took 35 min at ~1980 mA, vs 29 min at constant current: a taper above 80 %.)
        let m = minutesToTarget(currentMAh: 3213, maxMAh: 4400, chargeMA: 1846, targetPercent: 85)!
        #expect(m >= 22 && m <= 28)
    }

    @Test func measuredCurrentAboveTheKneeIsNotTaperedTwice() {
        // At 90 % the measured current is already the tapered one.
        #expect(minutesToTarget(currentMAh: 3600, maxMAh: 4000, chargeMA: 400, targetPercent: 100) == 60)
    }

    @Test func atOrPastTheTargetOrNoCurrentIsNil() {
        #expect(minutesToTarget(currentMAh: 3800, maxMAh: 4000, chargeMA: 1000, targetPercent: 95) == nil)
        #expect(minutesToTarget(currentMAh: 2000, maxMAh: 4000, chargeMA: 20, targetPercent: 100) == nil)
        #expect(minutesToTarget(currentMAh: 2000, maxMAh: 0, chargeMA: 1000, targetPercent: 100) == nil)
    }

    @Test func chargeCurrentAverageSmoothsADip() {
        var c = ChargeCurrent()
        c.ingest(milliamps: 2000, seconds: 0)
        #expect(c.milliamps == 2000)
        c.ingest(milliamps: 1300, seconds: 60)   // one low gauge reading
        #expect(c.milliamps! > 1800)
        c.ingest(milliamps: -150, seconds: 60)   // discharging readings are ignored
        #expect(c.milliamps! > 1800)
        c.reset()
        #expect(c.milliamps == nil)
    }
}

@Suite struct ChargeLimitTests {
    @Test func learnsWhereChargingStops() {
        #expect(learnedChargeLimit(previous: nil, state: .notCharging, percent: 85) == 85)
        #expect(learnedChargeLimit(previous: nil, state: .charged, percent: 80) == 80)
    }

    @Test func fullOrVeryLowHoldsAreNotLimits() {
        #expect(learnedChargeLimit(previous: nil, state: .charged, percent: 100) == nil)
        #expect(learnedChargeLimit(previous: nil, state: .notCharging, percent: 30) == nil)
    }

    @Test func chargingPastTheLimitForgetsIt() {
        #expect(learnedChargeLimit(previous: 85, state: .charging, percent: 86) == nil)
        #expect(learnedChargeLimit(previous: 85, state: .charging, percent: 70) == 85)
        #expect(learnedChargeLimit(previous: 85, state: .discharging, percent: 40) == 85)
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

    @Test func staleOrUnreadableFileIsUnknown() throws {
        let data = try powerdFile(policies: [["soclimit": 85, "terminated": false]], boot: "OLD")
        #expect(parsePowerdChargeLimit(data, bootSessionUUID: "BOOT-1") == .unknown)
        #expect(parsePowerdChargeLimit(Data("garbage".utf8), bootSessionUUID: "BOOT-1") == .unknown)
        #expect(parsePowerdChargeLimit(nil, bootSessionUUID: "BOOT-1") == .unknown)
    }
}
