import Testing
@testable import MacStatsCore

@Suite struct AppleSensorReaderSmokeTests {
    @Test func returnsSensorsWithoutCrashing() {
        let sensors = readAppleThermalSensors()
        for s in sensors where s.celsius != 0 {
            #expect(s.celsius > -50 && s.celsius < 150)
        }
        _ = sensors  // primarily a does-not-crash check
    }
}
