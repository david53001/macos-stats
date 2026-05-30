import Testing
@testable import MacStatsCore

@Suite struct CPUTemperatureTests {
    @Test func averagesCPUClusterSensors() {
        let sensors: [(name: String, celsius: Double)] = [
            ("PMU tdie1", 50), ("PMU2 tdie5", 60),   // CPU/SoC die (substring "tdie")
            ("PMU tdev2", 70),                        // peripheral device — ignored
            ("gas gauge battery", 30),                // battery — ignored
        ]
        #expect(cpuTemperature(from: sensors) == 55)   // avg of 50 and 60
    }
    @Test func ignoresOutOfRangeReadings() {
        let sensors: [(name: String, celsius: Double)] = [
            ("PMU tdie1", 0), ("PMU tdie2", 200), ("PMU tdie3", 40),
        ]
        #expect(cpuTemperature(from: sensors) == 40)
    }
    @Test func emptyOrNoMatchReturnsNil() {
        #expect(cpuTemperature(from: []) == nil)
        #expect(cpuTemperature(from: [("gas gauge battery", 30), ("NAND CH0 temp", 35)]) == nil)
    }
}
