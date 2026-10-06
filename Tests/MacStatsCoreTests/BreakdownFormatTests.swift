import Testing
@testable import MacStatsCore

@Suite struct BreakdownFormatTests {
    @Test func cpuTextIsUnchanged() {
        #expect(breakdownValueText(.cpu, 0) == "0.0%")
        #expect(breakdownValueText(.cpu, 2.04) == "2.0%")
        #expect(breakdownValueText(.cpu, 9.94) == "9.9%")
        #expect(breakdownValueText(.cpu, 9.95) == "10%")
        #expect(breakdownValueText(.cpu, 42.4) == "42%")
    }

    @Test func memoryTextIsUnchanged() {
        #expect(breakdownValueText(.memory, 500 * 1_048_576) == "500 MB")
        #expect(breakdownValueText(.memory, 1023 * 1_048_576) == "1023 MB")
        #expect(breakdownValueText(.memory, 1024 * 1_048_576) == "1.0 GB")
        #expect(breakdownValueText(.memory, 2.26 * 1_073_741_824) == "2.3 GB")
    }

    @Test func energyTextIsUnchanged() {
        #expect(breakdownValueText(.energy, 0.034) == "0.03 W")
        #expect(breakdownValueText(.energy, 1.26) == "1.3 W")
        #expect(breakdownValueText(.energy, 12.4) == "12 W")
        #expect(formatWatts(3.25) == "3.2 W" || formatWatts(3.25) == "3.3 W")
        #expect(formatWatts(14.6) == "15 W")
    }

    @Test func energyBelowTheLastDigitSaysSo() {
        #expect(breakdownValueText(.energy, 0) == "<0.01 W")
        #expect(breakdownValueText(.energy, 0.0049) == "<0.01 W")
        #expect(breakdownValueText(.energy, 0.005) == "0.01 W")
    }

    @Test func processNamesDropTheirAppsName() {
        #expect(processDisplayName("Google Chrome Helper (Renderer)", inApp: "Google Chrome") == "Helper (Renderer)")
        #expect(processDisplayName("Code Helper (Plugin)", inApp: "Code") == "Helper (Plugin)")
        #expect(processDisplayName("Google Chrome", inApp: "Google Chrome") == "Google Chrome")
        #expect(processDisplayName("Codex", inApp: "Code") == "Codex")          // not a word boundary
        #expect(processDisplayName("mdworker", inApp: "Other processes") == "mdworker")
    }

    @Test func stepsMatchThePrintedPrecision() {
        #expect(breakdownValueStep(.cpu, 3) == 0.1)
        #expect(breakdownValueStep(.cpu, 12) == 1)
        #expect(breakdownValueStep(.memory, 300 * 1_048_576) == 1_048_576)
        #expect(abs(breakdownValueStep(.memory, 3 * 1_073_741_824) - 107_374_182.4) < 1)
        #expect(breakdownValueStep(.energy, 0.5) == 0.01)
        #expect(breakdownValueStep(.energy, 5) == 0.1)
        #expect(breakdownValueStep(.energy, 15) == 1)
    }

    @Test func aValueQuantisedToItsStepPrintsTheSame() {
        for metric in [BreakdownMetric.cpu, .memory, .energy] {
            let values: [Double] = switch metric {
            case .cpu: [0.04, 0.26, 3.33, 9.4, 15.6, 77.2]
            case .memory: [12_345_678, 900_000_000, 2_400_000_000, 9_999_999_999]
            case .energy: [0.004, 0.333, 2.27, 33.3]
            }
            for v in values {
                let step = breakdownValueStep(metric, v)
                #expect(breakdownValueText(metric, (v / step).rounded() * step) == breakdownValueText(metric, v))
            }
        }
    }

    @Test func loginwindowCantBeQuit() {
        #expect(!canQuitProcess(named: "loginwindow"))
        #expect(canQuitProcess(named: "Dock"))
        #expect(canQuitProcess(named: "Code Helper (Renderer)"))
    }
}
