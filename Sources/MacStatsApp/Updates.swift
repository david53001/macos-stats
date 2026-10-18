import AppKit
import Sparkle
import UserNotifications

/// Auto-updates via Sparkle 2 (docs/sparkle-updates/README.md).
///
/// Configuration lives in `Resources/Info.plist`: `SUFeedURL` (the appcast attached to the
/// latest GitHub release), `SUPublicEDKey` (updates must be signed with the matching EdDSA key)
/// and `SUEnableAutomaticChecks` (check daily without first asking permission). The app is not
/// sandboxed, so Sparkle installs via its bundled `Autoupdate` / `Updater.app`; the framework's
/// XPC services (only for sandboxed apps) are removed by `Scripts/bundle.sh`.
///
/// MacStats is a menu-bar app with no windows of its own, so scheduled checks use Sparkle's
/// "gentle reminders": a found update's window opens *behind* the user's windows instead of
/// taking focus. So that it isn't missed, MacStats also posts one notification for it and, until
/// the user looks at it, shows a dot on the panel's Settings gear and "Version X is available."
/// in Settings → Updates. Clicking the notification or "Show Update…" brings Sparkle's window
/// forward.
@MainActor
final class Updates: NSObject, ObservableObject {
    static let shared = Updates()

    /// Whether a check can start now (false while one is running), for the Settings button.
    @Published private(set) var canCheck = false
    /// Set while a scheduled check has found an update the user hasn't looked at yet.
    @Published private(set) var pendingVersion: String?

    private var controller: SPUStandardUpdaterController!
    private var canCheckObservation: NSKeyValueObservation?

    private override init() {
        super.init()
        #if SPARKLE_E2E_TEST
        let updaterDelegate: SPUUpdaterDelegate? = self
        #else
        let updaterDelegate: SPUUpdaterDelegate? = nil
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: updaterDelegate,
                                                  userDriverDelegate: self)
    }

    /// Starts the updater (and its schedule). Called once at launch.
    func start() {
        // Clicks on our update notification come here (the alert notifications don't need any).
        UNUserNotificationCenter.current().delegate = self
        controller.startUpdater()
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value }
        }
    }

    /// "Check for Updates…" / "Show Update…": shows Sparkle's window with the result, or brings
    /// the waiting update's window forward.
    func checkForUpdates() {
        NSApp.activate()   // a menu-bar app: otherwise the window can open behind others
        controller.checkForUpdates(nil)
    }

    nonisolated static let notificationID = "MacStats.updateAvailable"

    /// One notification per scheduled find that Sparkle shows in the background. Needs the
    /// notification permission MacStats already asks for (alerts); without it this does nothing.
    private func postUpdateNotification(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "MacStats \(version) is available"
        content.body = "Click to see what's new and install it."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
    }

    private func clearPending() {
        pendingVersion = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
    }

    /// Settings → Updates → "Check automatically" (Sparkle stores it in our defaults as
    /// `SUEnableAutomaticChecks`; the Info.plist value is only the default).
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

extension Updates: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        let version = update.displayVersionString
        Task { @MainActor in
            self.pendingVersion = version
            if handleShowingUpdate { self.postUpdateNotification(version: version) }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.clearPending() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.clearPending() }
    }
}

extension Updates: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let isUpdate = response.notification.request.identifier == Updates.notificationID
            && response.actionIdentifier == UNNotificationDefaultActionIdentifier
        Task { @MainActor in
            if isUpdate { self.checkForUpdates() }
            completionHandler()
        }
    }
}

#if SPARKLE_E2E_TEST
/// Only in the throwaway build of `Scripts/sparkle-e2e-test.sh` (`-DSPARKLE_E2E_TEST`): log each
/// step to stderr for the script, and install a downloaded update right away instead of on quit
/// (the script can't quit the app gracefully without an Apple-event permission prompt).
extension Updates: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NSLog("SPARKLE-E2E found %@ (build %@)", item.displayVersionString, item.versionString)
    }

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        NSLog("SPARKLE-E2E downloaded %@", item.versionString)
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        NSLog("SPARKLE-E2E installing %@", item.versionString)
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        NSLog("SPARKLE-E2E ready to install %@; installing now", item.versionString)
        immediateInstallHandler()
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        NSLog("SPARKLE-E2E aborted: %@", (error as NSError).description)
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                             error: Error?) {
        NSLog("SPARKLE-E2E cycle finished, error: %@", error.map { ($0 as NSError).description } ?? "none")
    }
}
#endif
