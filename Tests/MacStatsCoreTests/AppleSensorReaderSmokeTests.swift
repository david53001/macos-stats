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

    @Test func cachedReaderAgreesWithOneShotRead() {
        // The cached reader must see the same CPU sensors as a fresh enumeration: both nil
        // (no usable sensor on this machine) or both a sane temperature, repeatably.
        let reader = CPUTemperatureReader()
        let first = reader.read()
        let second = reader.read()                      // served from the cached services
        let oneShot = cpuTemperature(from: readAppleThermalSensors())
        #expect((first == nil) == (oneShot == nil))
        #expect((second == nil) == (first == nil))
        if let second { #expect(second > 0 && second < 150) }
    }
}
