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
    /// The in-popover Settings screen (pushed from the overview footer); reset on close.
    @State private var showingSettings = false

    var body: some View {
        // Both screens have the same fixed size, so the window never resizes; switching
        // between them is an Apple-style push (breakdown slides in from the trailing edge,
        // the overview drifts back a little and fades), clipped to the panel.
        ZStack {
            if showingSettings {
                SettingsView(onBack: { showingSettings = false })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let metric = store.activeBreakdownMetric {
                BreakdownView(store: store, metric: metric,
                              onBack: { model.exitBreakdown() })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                OverviewView(store: store,
                             onSelect: { model.enterBreakdown($0) },
                             onEmptyTrash: { model.confirmAndEmptyTrash() },
                             onSettings: { showingSettings = true })
                    .transition(.offset(x: -Design.panelWidth * 0.3).combined(with: .opacity))
            }
        }
        .frame(width: Design.panelWidth, height: Design.panelHeight)
        .clipped()
        .background(PanelBackdrop())   // the Opacity setting (Appearance.swift)
        .animation(.snappy(duration: 0.3), value: store.activeBreakdownMetric)
        .animation(.snappy(duration: 0.3), value: showingSettings)
        .onAppear { model.setVisibility(.popoverOpen) }
        .onDisappear {
            model.setVisibility(.idle)
            showingSettings = false
        }
    }
}
