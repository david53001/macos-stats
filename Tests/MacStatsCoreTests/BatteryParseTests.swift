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
        "AppleRawMaxCapacity": NSNumber(value: 4422 as UInt64),
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
        #expect(t.healthPercent == 99)    // 4541 / 4563 = 99.5 %; System Settings truncates
        #expect(t.rawMaxMAh == 4422)
        // 3155 mAh × (12.116 V now + 10.5 V for 3 cells at 3.5 V) / 2: not 38.2 Wh at 12.1 V.
        #expect(abs(t.remainingWh! - 35.677) < 0.01)
        #expect(t.instantWatts == 3.153)
    }

    @Test func noUpdateTimeMeansNoBattery() {
        #expect(parseSmartBattery([:]) == nil)
    }

    @Test func instantWattsFallsBackToVoltageTimesCurrent() {
        let t = BatteryTelemetry(updateTime: 1, voltageMV: 12_000, amperageMA: -500)
        #expect(t.instantWatts == 6.0)
    }

    @Test func chargingCurrentIsNotTheMacsDraw() {
        // Intel, plugged in: V × A is the power going into the battery, not the Mac's load.
        let t = BatteryTelemetry(updateTime: 1, voltageMV: 12_000, amperageMA: 2_000)
        #expect(t.instantWatts == nil)
    }

    @Test func healthMatchesSystemSettings() {
        // system_profiler "Maximum Capacity": 99 % for both (Apple truncates).
        #expect(BatteryTelemetry(updateTime: 1, nominalMAh: 4542, designMAh: 4563).healthPercent == 99)
        #expect(BatteryTelemetry(updateTime: 1, nominalMAh: 4527, designMAh: 4563).healthPercent == 99)
        #expect(BatteryTelemetry(updateTime: 1, nominalMAh: 4600, designMAh: 4563).healthPercent == 100)
    }

    @Test func remainingEnergyAllowsForTheVoltageSag() {
        // A 2-cell pack (Intel MacBook Air): end at 7.0 V.
        let t = BatteryTelemetry(updateTime: 1, voltageMV: 8_000, currentMAh: 2_000)
        #expect(abs(t.remainingWh! - 15.0) < 1e-9)
        // Already at the end voltage: no further sag assumed.
        let low = BatteryTelemetry(updateTime: 1, voltageMV: 10_400, currentMAh: 100)
        #expect(abs(low.remainingWh! - 1.04) < 1e-9)
    }

    @Test func recentMaxHoldsThePeakOfTheLastReadings() {
        // Live: NominalChargeCapacity 4558, 4474, 4526 within minutes (health 99, 98, 99 %).
        var m = RecentMax(capacity: 3)
        #expect(m.add(4558) == 4558)
        #expect(m.add(4474) == 4558)
        #expect(m.add(4526) == 4558)
        #expect(m.add(4530) == 4530)   // 4558 has aged out
        #expect(m.values == [4474, 4526, 4530])
    }

    @Test func averageWattsUsesRunningSums() {
        let a = BatteryTelemetry(updateTime: 1, systemLoadMW: 9000, accumulatedSystemLoad: 1_000_000, systemLoadCount: 100)
        let b = BatteryTelemetry(updateTime: 2, systemLoadMW: 9000, accumulatedSystemLoad: 1_500_000, systemLoadCount: 200)
        #expect(averageWatts(from: a, to: b) == 5.0)       // 500 000 mW·samples / 100 samples
        #expect(averageWatts(from: nil, to: b) == 9.0)     // no previous → instant
        #expect(averageWatts(from: b, to: a) == 9.0)       // sums went backwards (reset) → instant
    }
}
