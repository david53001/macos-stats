import SwiftUI

@main
struct MacStatsApp: App {
    var body: some Scene {
        MenuBarExtra("MacStats") {
            Text("MacStats is running.")
                .padding()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .padding(.bottom)
        }
        .menuBarExtraStyle(.window)
    }
}
