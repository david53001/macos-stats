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
