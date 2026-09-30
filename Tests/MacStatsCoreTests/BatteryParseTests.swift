import Testing
import Foundation
import IOKit.ps
@testable import MacStatsCore

@Suite struct BatteryParseTests {
    private func dict(percent: Int = 84, charging: Bool = false, charged: Bool = false, onAC: Bool = false,
                      toEmpty: Int = -1, toFull: Int = -1) -> [String: Any] {
        [
            kIOPSCurrentCapacityKey as String: percent,
            kIOPSMaxCapacityKey as String: 100,
            kIOPSIsChargingKey as String: charging,
            kIOPSIsChargedKey as String: charged,
            kIOPSPowerSourceStateKey as String: onAC ? kIOPSACPowerValue : kIOPSBatteryPowerValue,
            kIOPSTimeToEmptyKey as String: toEmpty,
            kIOPSTimeToFullChargeKey as String: toFull,
        ]
    }

    @Test func dischargingHasPercentAndTimeToEmpty() {
        let s = parseBattery(dict(toEmpty: 134))
        #expect(s?.percent == 84)
        #expect(s?.state == .discharging)
        #expect(s?.isCharging == false)
        #expect(s?.timeToEmptyMinutes == 134)
        #expect(s?.timeToFullMinutes == nil)
    }

    @Test func chargingHasTimeToFullNotEmpty() {
        let s = parseBattery(dict(percent: 50, charging: true, onAC: true, toEmpty: 300, toFull: 65))
        #expect(s?.state == .charging)
        #expect(s?.isCharging == true)
        #expect(s?.timeToEmptyMinutes == nil)
        #expect(s?.timeToFullMinutes == 65)
    }

    @Test func pluggedInAndFullIsCharged() {
        // The state macOS reports on AC once full (even while the battery drifts down).
        #expect(parseBattery(dict(percent: 100, charged: true, onAC: true, toEmpty: 400))?.state == .charged)
        #expect(parseBattery(dict(percent: 100, onAC: true))?.state == .charged)
    }

    @Test func pluggedInButHeldIsNotCharging() {
        let s = parseBattery(dict(percent: 80, onAC: true, toEmpty: 400))
        #expect(s?.state == .notCharging)
        #expect(s?.state.isPluggedIn == true)
        #expect(s?.timeToEmptyMinutes == nil)
    }

    @Test func calculatingTimesAreNil() {
        #expect(parseBattery(dict(toEmpty: -1))?.timeToEmptyMinutes == nil)
        #expect(parseBattery(dict(toEmpty: 0))?.timeToEmptyMinutes == nil)
        #expect(parseBattery(dict(charging: true, onAC: true, toFull: -1))?.timeToFullMinutes == nil)
    }

    @Test func missingPowerSourceStateDefaultsToBattery() {
        let d: [String: Any] = [kIOPSCurrentCapacityKey as String: 40, kIOPSMaxCapacityKey as String: 100]
        #expect(parseBattery(d)?.state == .discharging)
    }

    @Test func missingCapacityReturnsNil() {
        #expect(parseBattery([:]) == nil)
    }
}

@Suite struct BatteryTelemetryTests {
    /// Values as the registry returns them on an M3 MacBook Air (signed ones as UInt64 bit patterns).
    private let fixture: [String: Any] = [
        "UpdateTime": NSNumber(value: 1_790_783_683 as UInt64),
        "Voltage": NSNumber(value: 12_116 as UInt64),
        "Amperage": NSNumber(value: UInt64(bitPattern: -260)),
        "AppleRawCurrentCapacity": NSNumber(value: 3155 as UInt64),
        "NominalChargeCapacity": NSNumber(value: 4541 as UInt64),
        "DesignCapacity": NSNumber(value: 4563 as UInt64),
        "CycleCount": NSNumber(value: 127 as UInt64),
        "Temperature": NSNumber(value: 3018 as UInt64),
        "AdapterDetails": ["Watts": NSNumber(value: 30 as UInt64)],
        "PowerTelemetryData": [
            "SystemLoad": NSNumber(value: 3153 as UInt64),
            "AccumulatedSystemLoad": NSNumber(value: 123_128_612 as UInt64),
            "SystemLoadAccumulatorCount": NSNumber(value: 43_305 as UInt64),
        ],
    ]

    @Test func parsesRegistryValues() throws {
        let t = try #require(parseSmartBattery(fixture))
        #expect(t.updateTime == 1_790_783_683)
        #expect(t.amperageMA == -260)
        #expect(t.cycleCount == 127)
        #expect(t.temperatureC == 30.18)
        #expect(t.adapterWatts == 30)
        #expect(t.healthPercent == 100)   // 4541 / 4563 = 99.5 %
        #expect(abs(t.remainingWh! - 38.226) < 0.01)
        #expect(t.instantWatts == 3.153)
    }

    @Test func noUpdateTimeMeansNoBattery() {
        #expect(parseSmartBattery([:]) == nil)
    }

    @Test func instantWattsFallsBackToVoltageTimesCurrent() {
        let t = BatteryTelemetry(updateTime: 1, voltageMV: 12_000, amperageMA: -500)
        #expect(t.instantWatts == 6.0)
    }

    @Test func averageWattsUsesRunningSums() {
        let a = BatteryTelemetry(updateTime: 1, systemLoadMW: 9000, accumulatedSystemLoad: 1_000_000, systemLoadCount: 100)
        let b = BatteryTelemetry(updateTime: 2, systemLoadMW: 9000, accumulatedSystemLoad: 1_500_000, systemLoadCount: 200)
        #expect(averageWatts(from: a, to: b) == 5.0)       // 500 000 mW·samples / 100 samples
        #expect(averageWatts(from: nil, to: b) == 9.0)     // no previous → instant
        #expect(averageWatts(from: b, to: a) == 9.0)       // sums went backwards (reset) → instant
    }
}

@Suite struct BatteryEstimatorTests {
    @Test func firstReadingSeedsTheEstimate() {
        var e = BatteryEstimator()
        e.ingest(watts: 6, at: 0, discharging: true)
        #expect(e.expectedWatts == 6)
        #expect(e.minutesLeft(remainingWh: 30) == 300)
    }

    @Test func aQuietMinuteDoesNotPromiseHours() {
        // 20 min at 10 W, then one minute idle at 3 W: macOS would divide by ~3 W.
        var e = BatteryEstimator()
        var t: Double = 0
        for _ in 0...20 { e.ingest(watts: 10, at: t, discharging: true); t += 60 }
        e.ingest(watts: 3, at: t, discharging: true)
        let w = e.expectedWatts!
        #expect(w > 9 && w < 10)
    }

    @Test func typicalUsageTempersAnIdleSession() {
        // A history of 8 W use, then a fresh unplug that has only seen 3 W so far.
        var e = BatteryEstimator(typicalWatts: 8, typicalSeconds: 10 * 3600)
        e.ingest(watts: 3, at: 0, discharging: true)
        #expect(e.expectedWatts == 5.5)   // half recent, half typical
        #expect(e.minutesLeft(remainingWh: 38.5) == 420)   // 7 h, not 12.8 h
    }

    @Test func typicalWeightRampsInOverTheFirstHour() {
        var e = BatteryEstimator()
        e.ingest(watts: 4, at: 0, discharging: true)
        #expect(e.expectedWatts == 4)
        e.ingest(watts: 4, at: 60, discharging: true)
        #expect(e.typicalSeconds == 60)
    }

    @Test func pluggingInEndsTheSessionButTypicalKeepsLearning() {
        var e = BatteryEstimator()
        e.ingest(watts: 10, at: 0, discharging: true)
        e.ingest(watts: 10, at: 60, discharging: true)
        e.ingest(watts: 10, at: 120, discharging: false)
        #expect(e.recentWatts == nil)
        #expect(e.expectedWatts == nil)
        #expect(e.typicalWatts == 10)
        #expect(e.typicalSeconds == 120)                  // plugged-in use counts for typical
        e.ingest(watts: 4, at: 180, discharging: true)    // next unplug starts recent fresh
        #expect(e.recentWatts == 4)
        #expect(e.typicalSeconds == 180)
    }

    @Test func pluggedInReadingsAloneGiveNoTimeLeft() {
        var e = BatteryEstimator()
        e.ingest(watts: 8, at: 0, discharging: false)
        #expect(e.typicalWatts == 8)
        #expect(e.minutesLeft(remainingWh: 40) == nil)
    }

    @Test func longGapIsCapped() {
        var e = BatteryEstimator()
        e.ingest(watts: 10, at: 0, discharging: true)
        e.ingest(watts: 2, at: 8 * 3600, discharging: true)   // woke after a night asleep
        #expect(e.typicalSeconds == BatteryEstimator.maxStep)
        #expect(e.recentWatts! > 5)   // one reading can't swamp the average
    }

    @Test func noDataMeansNoEstimate() {
        #expect(BatteryEstimator().minutesLeft(remainingWh: 40) == nil)
        #expect(BatteryEstimator().expectedWatts == nil)
    }
}
