import Foundation
import UserNotifications
import MacStatsCore

/// Posts threshold alerts as user notifications. Asks permission once; if denied,
/// posting silently no-ops. Requires the bundled app (not the bare SPM binary).
@MainActor
final class AlertNotifier {
    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ kind: AlertKind) {
        let content = UNMutableNotificationContent()
        switch kind {
        case .highCPU:
            content.title = "High CPU usage"
            content.body = "CPU has been above 85% for the last 30 seconds."
        case .memoryPressure:
            content.title = "Memory pressure high"
            content.body = "Your Mac is low on available memory."
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
