import SwiftUI
import MacStatsCore

/// Top of the popover. Shows the overview, or the drill-in when a breakdown is active.
/// Owns the popover open/close lifecycle that drives the refresh pipeline, and hosts the
/// guided tour over the overview.
struct RootView: View {
    @ObservedObject var model: AppModel
    /// Observed directly. The drill-in switch below depends on `store.activeBreakdownMetric`,
    /// and SwiftUI does NOT observe a nested ObservableObject reached through `model.store` —
    /// without this, entering/leaving a breakdown wouldn't re-render the view.
    @ObservedObject var store: MetricsStore
    /// Observed here only (not by the overview), so a tour step never re-renders the cards.
    @ObservedObject var tour: TourController
    /// The in-popover Settings screen (pushed from the overview footer); reset on close.
    @State private var showingSettings = false
    /// The open breakdown shows the "Right-click an app to quit it" hint (first few drill-ins).
    @State private var quitHint = false

    var body: some View {
        // Both screens have the same fixed size, so the window never resizes; switching
        // between them is an Apple-style push (breakdown slides in from the trailing edge,
        // the overview drifts back a little and fades), clipped to the panel.
        ZStack {
            if showingSettings {
                SettingsView(onTour: replayFromSettings, onBack: { showingSettings = false })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let metric = store.activeBreakdownMetric {
                BreakdownView(store: store, metric: metric, quitHint: quitHint,
                              onBack: { model.exitBreakdown() })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                OverviewView(store: store,
                             onSelect: { metric in
                                 quitHint = tour.breakdownOpened()
                                 model.enterBreakdown(metric)
                             },
                             onEmptyTrash: { model.confirmAndEmptyTrash() },
                             onSettings: { showingSettings = true },
                             offersTour: tour.offersTour,
                             onTour: startTour,
                             onDismissOffer: { tour.dismissOffer() })
                    .transition(.offset(x: -Design.panelWidth * 0.3).combined(with: .opacity))
            }
        }
        .frame(width: Design.panelWidth, height: Design.panelHeight)
        .tourHost(tour, showing: !showingSettings && store.activeBreakdownMetric == nil)
        .clipped()
        .background(PanelBackdrop())   // the Opacity setting (Appearance.swift)
        .animation(.snappy(duration: 0.3), value: store.activeBreakdownMetric)
        .animation(.snappy(duration: 0.3), value: showingSettings)
        .onAppear {
            model.setVisibility(.popoverOpen)
            tour.panelOpened()
        }
        .onDisappear {
            model.setVisibility(.idle)
            showingSettings = false
            tour.panelClosed()
        }
    }

    /// The overview's `?` and chip: the tour runs on the overview only.
    private func startTour() {
        showingSettings = false
        model.exitBreakdown()
        tour.start()
    }

    /// Settings → Take the Tour: pop back first, so the cutout never slides along with the push.
    private func replayFromSettings() {
        withAnimation(.snappy(duration: 0.3)) { showingSettings = false } completion: { tour.start() }
    }
}
