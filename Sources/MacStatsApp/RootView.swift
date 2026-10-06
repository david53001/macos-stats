import AppKit
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
                              onBack: { model.exitBreakdown() }, onMenuUsed: { tour.breakdownMenuUsed() })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                OverviewView(store: store,
                             onSelect: { metric in
                                 endTourForClick()
                                 quitHint = tour.breakdownOpened()
                                 model.enterBreakdown(metric)
                             },
                             onEmptyTrash: { model.confirmAndEmptyTrash() },
                             onSettings: {
                                 endTourForClick()
                                 showingSettings = true
                             },
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
        .background(PanelWindowObserver { model.panelWindowChanged($0) })
        .animation(.snappy(duration: 0.3), value: store.activeBreakdownMetric)
        .animation(.snappy(duration: 0.3), value: showingSettings)
        .onAppear {
            model.setPanelAppeared(true)
            tour.panelOpened()
        }
        .onDisappear {
            model.setPanelAppeared(false)
            showingSettings = false
            tour.panelClosed()
        }
    }

    /// A click on the highlighted card or the gear (the cutout lets it through): the user is doing
    /// what the callout says, so the tour ends there.
    private func endTourForClick() {
        if tour.isActive { tour.skip() }
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

/// Reports the panel window whenever it is shown, hidden or covered (occlusion) or becomes key,
/// so the refresh pipeline follows what is really on screen (`AppModel.panelWindowChanged`).
/// Two notification observers on our own window; nothing runs between events.
private struct PanelWindowObserver: NSViewRepresentable {
    let onChange: (NSWindow) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((NSWindow) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            observers = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification]
                .map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self, let window = self.window else { return }
                            self.onChange?(window)
                        }
                    }
                }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
