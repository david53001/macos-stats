import SwiftUI

@main
struct MacStatsApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var model: AppModel

    init() {
        // Before AppModel, which writes its own keys: after that everyone would look "existing".
        TourController.classifyAudienceIfNeeded(
            domainKeys: Set(UserDefaults.standard.persistentDomain(forName: "com.macstats.MacStats")?.keys.map { $0 } ?? []),
            bundleID: Bundle.main.bundleIdentifier)
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        // Hovering the menu-bar icon takes a fresh sample, so a click opens on current numbers.
        StatusItemHover.install { model.prewarm() }
        // A new user hasn't found the icon yet: open the panel once (the welcome card points at
        // it), as soon as the hover hook has found the status button.
        if TourController.welcomePending() {
            StatusItemHover.openPanelWhenFound()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            RootView(model: model, store: model.store, tour: model.tour)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Relaunching MacStats while it runs (Spotlight, Applications, Finder) opens its panel: the
/// only way to find it when the menu bar hides the icon (behind the notch, or too many items).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { StatusItemHover.openPanel() }
        return false
    }
}
