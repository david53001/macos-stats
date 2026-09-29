import SwiftUI

@main
struct MacStatsApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            RootView(model: model, store: model.store)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}
