import Testing
import IOKit.ps
@testable import MacStatsCore

@Suite struct BatteryParseTests {
    @Test func parsesPercentAndTime() {
        let dict: [String: Any] = [
            kIOPSCurrentCapacityKey as String: 84,
            kIOPSMaxCapacityKey as String: 100,
            kIOPSIsChargingKey as String: false,
            kIOPSTimeToEmptyKey as String: 134,
        ]
        let s = parseBattery(dict)
        #expect(s?.percent == 84)
        #expect(s?.isCharging == false)
        #expect(s?.timeToEmptyMinutes == 134)
    }

    @Test func chargingHasNoTimeToEmpty() {
        let dict: [String: Any] = [
            kIOPSCurrentCapacityKey as String: 50,
            kIOPSMaxCapacityKey as String: 100,
            kIOPSIsChargingKey as String: true,
            kIOPSTimeToEmptyKey as String: -1,
        ]
        let s = parseBattery(dict)
        #expect(s?.percent == 50)
        #expect(s?.isCharging == true)
        #expect(s?.timeToEmptyMinutes == nil)
    }

    @Test func missingCapacityReturnsNil() {
        #expect(parseBattery([:]) == nil)
    }
}
