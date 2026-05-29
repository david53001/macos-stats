import SwiftUI
import MacStatsCore

/// The text shown in the menu bar. Milestone 1: CPU %. (Temp arrives in Milestone 2.)
struct MenuBarLabel: View {
    @ObservedObject var store: MetricsStore
    var body: some View {
        Text("\(Int(store.cpuPercent.rounded()))%")
            .monospacedDigit()
    }
}
