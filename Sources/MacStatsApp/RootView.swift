import SwiftUI
import MacStatsCore

/// Top of the popover. Shows the overview, or the drill-in when a breakdown is active.
/// Owns the popover open/close lifecycle that drives the refresh pipeline.
struct RootView: View {
    @ObservedObject var model: AppModel
    /// Observed directly. The drill-in switch below depends on `store.activeBreakdownMetric`,
    /// and SwiftUI does NOT observe a nested ObservableObject reached through `model.store` —
    /// without this, entering/leaving a breakdown wouldn't re-render the view.
    @ObservedObject var store: MetricsStore

    var body: some View {
        Group {
            if let metric = store.activeBreakdownMetric {
                BreakdownView(store: store, metric: metric,
                              onBack: { model.exitBreakdown() })
            } else {
                OverviewView(store: store,
                             onSelect: { model.enterBreakdown($0) })
            }
        }
        .onAppear { model.setVisibility(.popoverOpen) }
        .onDisappear { model.setVisibility(.idle) }
    }
}
