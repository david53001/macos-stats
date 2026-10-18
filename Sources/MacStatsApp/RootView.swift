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
    /// The one-time "Open MacStats at login?" card over the screens (`LoginPrompt.swift`).
    @ObservedObject var loginPrompt: LoginPrompt

    var body: some View {
        // Both screens have the same fixed size, so the window never resizes; switching
        // between them is an Apple-style push (breakdown slides in from the trailing edge,
        // the overview drifts back a little and fades), clipped to the panel. The login card,
        // when due, floats over them inside that same frame: it never changes the window's size.
        screens
            .environment(\.loginPromptActive, loginPrompt.isShowing)
            .overlayPreferenceValue(LoginPromptAnchorKey.self) { LoginPromptOverlay(prompt: loginPrompt, anchors: $0) }
            .background(PanelBackdrop())   // the Opacity setting (Appearance.swift)
            // A close also resets the screen (Settings, a breakdown) to the overview: `AppModel`.
            .background(PanelVisibilityObserver { model.panelVisibilityChanged(onScreen: $0) })
            .animation(.snappy(duration: 0.3), value: store.activeBreakdownMetric)
            .animation(.snappy(duration: 0.3), value: model.showingSettings)
            .onAppear { model.setVisibility(.popoverOpen) }
            .onDisappear { model.setVisibility(.idle) }
    }

    private var screens: some View {
        ZStack {
            if model.showingSettings {
                SettingsView(onBack: { model.showingSettings = false })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let metric = store.activeBreakdownMetric {
                BreakdownView(store: store, metric: metric,
                              onBack: { model.exitBreakdown() })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                OverviewView(store: store,
                             onSelect: { model.enterBreakdown($0) },
                             onEmptyTrash: { model.confirmAndEmptyTrash() },
                             onSettings: { model.showingSettings = true })
                    .transition(.offset(x: -Design.panelWidth * 0.3).combined(with: .opacity))
            }
        }
        .frame(width: Design.panelWidth, height: Design.panelHeight)
        .clipped()
    }
}
