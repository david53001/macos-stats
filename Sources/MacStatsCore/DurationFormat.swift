import Foundation

/// "6h 40m", "6h" on the hour, or "45m" under an hour.
public func formatDuration(_ minutes: Int) -> String {
    guard minutes >= 60 else { return "\(minutes)m" }
    return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
}

/// Time left on battery, rounded about as coarsely as it is uncertain. Against the drain that
/// really followed, one reading is off by ~30 % on average (round-3 review, 5 days of this Mac's
/// powerlog), so "15h 55m" claimed a precision it doesn't have. To the minute under 15 min, to
/// 5 min under 2 h, to 15 min under 6 h, then "about N h".
public func formatTimeLeft(_ minutes: Int) -> String {
    switch minutes {
    case ..<15: return formatDuration(minutes)
    case ..<120: return formatDuration(rounded(minutes, to: 5))
    case ..<360: return formatDuration(rounded(minutes, to: 15))
    default: return "about \(Int((Double(minutes) / 60).rounded()))h"
    }
}

/// Time to full or to a charge limit: measured to within a couple of minutes near the end, so
/// to the minute under an hour, and to 5 min above.
public func formatTimeToFull(_ minutes: Int) -> String {
    formatDuration(minutes < 60 ? minutes : rounded(minutes, to: 5))
}

private func rounded(_ minutes: Int, to step: Int) -> Int {
    Int((Double(minutes) / Double(step)).rounded()) * step
}
