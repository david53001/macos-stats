import SwiftUI
import MacStatsCore

/// Top of the popover. Shows the overview, or the drill-in when a breakdown is active.
/// Owns the popover open/close lifecycle that drives the refresh pipeline.
struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let metric = model.store.activeBreakdownMetric {
                BreakdownView(store: model.store, metric: metric,
                              onBack: { model.exitBreakdown() })
            } else {
                OverviewView(store: model.store,
                             onSelect: { model.enterBreakdown($0) })
            }
        }
        .onAppear { model.setVisibility(.popoverOpen) }
        .onDisappear { model.setVisibility(.idle) }
    }
}
