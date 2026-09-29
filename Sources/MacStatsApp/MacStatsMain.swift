import SwiftUI

@main
struct MacStatsApp: App {
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        // Hovering the menu-bar icon takes a fresh sample, so a click opens on current numbers.
        StatusItemHover.install { model.prewarm() }
    }

    var body: some Scene {
        MenuBarExtra {
            RootView(model: model, store: model.store)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}
