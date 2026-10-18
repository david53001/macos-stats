import AppKit
import SwiftUI
import MacStatsCore

/// Top of the popover. Shows the overview, or the drill-in when a breakdown is active.
/// Owns the popover open/close lifecycle that drives the refresh pipeline, and hosts the
/// guided tour and the one-time login question over it (never both at once: `AppModel`).
struct RootView: View {
    @ObservedObject var model: AppModel
    /// Observed directly. The drill-in switch below depends on `store.activeBreakdownMetric`,
    /// and SwiftUI does NOT observe a nested ObservableObject reached through `model.store` —
    /// without this, entering/leaving a breakdown wouldn't re-render the view.
    @ObservedObject var store: MetricsStore
    /// Observed here only (not by the overview), so a tour step never re-renders the cards.
    @ObservedObject var tour: TourController
    /// The one-time "Open MacStats at login?" card over the screens (`LoginPrompt.swift`).
    @ObservedObject var loginPrompt: LoginPrompt
    /// The open breakdown shows the "Click to expand · Right-click to quit" hint (first few drill-ins).
    @State private var quitHint = false

    var body: some View {
        // Both screens have the same fixed size, so the window never resizes; switching
        // between them is an Apple-style push (breakdown slides in from the trailing edge,
        // the overview drifts back a little and fades), clipped to the panel. The login card,
        // when due, floats over them inside that same frame: it never changes the window's size.
        ZStack {
            if model.showingSettings {
                SettingsView(onTour: replayFromSettings, onBack: { model.showingSettings = false })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let metric = store.activeBreakdownMetric {
                BreakdownView(store: store, metric: metric, quitHint: quitHint,
                              onBack: { model.exitBreakdown() }, onMenuUsed: { tour.breakdownMenuUsed() })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                // A click on the highlighted card or the gear (the cutout lets it through) does what
                // the callout says; the tour stays on its step, hidden, until the overview is back.
                OverviewView(store: store,
                             onSelect: { metric in
                                 quitHint = tour.breakdownOpened()
                                 model.enterBreakdown(metric)
                             },
                             onEmptyTrash: { model.confirmAndEmptyTrash() },
                             onSettings: { model.showingSettings = true },
                             offersTour: tour.offersTour,
                             onTour: startTour,
                             onDismissOffer: { tour.dismissOffer() })
                    .transition(.offset(x: -Design.panelWidth * 0.3).combined(with: .opacity))
            }
        }
        .frame(width: Design.panelWidth, height: Design.panelHeight)
        .tourHost(tour, showing: !model.showingSettings && store.activeBreakdownMetric == nil)
        .environment(\.loginPromptActive, loginPrompt.isShowing)
        .overlayPreferenceValue(LoginPromptAnchorKey.self) { LoginPromptOverlay(prompt: loginPrompt, anchors: $0) }
        .clipped()
        .background(PanelBackdrop())   // the Opacity setting (Appearance.swift)
        .background(PanelWindowObserver { model.panelWindowChanged($0) })
        .animation(.snappy(duration: 0.3), value: store.activeBreakdownMetric)
        .animation(.snappy(duration: 0.3), value: model.showingSettings)
        // A tour started during this open (chip, `?`, Settings → General → Take the Tour): the open isn't a use.
        .onChange(of: tour.isActive) { _, active in if active { loginPrompt.tourShown() } }
        // The tour pauses and resumes with the refresh pipeline's open/closed (`AppModel`), which
        // also follows the window, not only these.
        .onAppear { model.setPanelAppeared(true) }
        // A close also resets the screen (Settings, a breakdown) to the overview: `AppModel`, which
        // follows the window (this `onDisappear` doesn't fire when the window is ordered out).
        .onDisappear { model.setPanelAppeared(false) }
    }

    /// The overview's `?` and chip: the tour runs on the overview only.
    private func startTour() {
        model.showingSettings = false
        model.exitBreakdown()
        tour.start()
    }

    /// Settings → Take the Tour: pop back first, so the cutout never slides along with the push.
    private func replayFromSettings() {
        withAnimation(.snappy(duration: 0.3)) { model.showingSettings = false } completion: { tour.start() }
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
