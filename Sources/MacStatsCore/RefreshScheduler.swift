import Foundation

/// Whether the user is currently looking at the popover.
public enum Visibility: Equatable {
    case idle          // popover closed — only menu-bar values matter
    case popoverOpen   // popover open — refresh fast
}

/// The adaptive refresh interval (seconds) for a given visibility.
/// Idle is slow & cheap; open is 1s. (Milestone 3 adds a drilled-in case.)
public func refreshInterval(for visibility: Visibility) -> TimeInterval {
    switch visibility {
    case .idle: return 3.0
    case .popoverOpen: return 1.0
    }
}

/// Open-phase priming burst. When the popover opens, the sparklines start empty, so for
/// the first `burstSamples` samples we collect rapidly (`burstInterval` apart) to fill the
/// graph with real data within ~1 second, then settle to the normal open cadence.
/// These two constants are the single knob for the burst's feel.
public let burstInterval: TimeInterval = 0.1   // ~100ms between priming samples
public let burstSamples: Int = 10              // ~1s of burst ⇒ ~10 real points

/// Interval until the next sample while the popover is open, given how many samples have
/// already been collected since it opened. Fast during the burst, then the steady cadence.
public func openPhaseInterval(samplesSinceOpen: Int) -> TimeInterval {
    samplesSinceOpen < burstSamples
        ? burstInterval
        : refreshInterval(for: .popoverOpen)
}
