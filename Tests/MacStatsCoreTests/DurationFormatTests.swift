import Testing
@testable import MacStatsCore

@Suite struct DurationFormatTests {
    @Test func durations() {
        #expect(formatDuration(45) == "45m")
        #expect(formatDuration(400) == "6h 40m")
        #expect(formatDuration(120) == "2h")
    }

    @Test func timeLeftIsRoundedByHorizon() {
        #expect(formatTimeLeft(7) == "7m")              // the last minutes stay exact
        #expect(formatTimeLeft(47) == "45m")            // 5-min steps under 2 h
        #expect(formatTimeLeft(98) == "1h 40m")
        #expect(formatTimeLeft(118) == "2h")
        #expect(formatTimeLeft(128) == "2h 15m")        // 15-min steps under 6 h
        #expect(formatTimeLeft(338) == "5h 45m")
        #expect(formatTimeLeft(359) == "6h")
        #expect(formatTimeLeft(955) == "about 16h")     // the review's "15h 55m"
        #expect(formatTimeLeft(4011) == "about 67h")
    }

    @Test func timeToFullKeepsMinutesUnderAnHour() {
        #expect(formatTimeToFull(23) == "23m")
        #expect(formatTimeToFull(59) == "59m")
        #expect(formatTimeToFull(73) == "1h 15m")
        #expect(formatTimeToFull(154) == "2h 35m")
    }
}
