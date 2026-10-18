import AppKit
import SwiftUI
import ServiceManagement
import MacStatsCore

/// The one-time "Open MacStats at login?" question (rules and open/close cycle, both tested:
/// `MacStatsCore/LaunchAtLoginPrompt.swift`).
///
/// It is a card floating over the panel's own content, never a window or alert: it shows only
/// inside a panel the user just opened, so it can't take focus from what they were typing, and
/// it is drawn inside the panel's fixed 320 × 404 pt frame, so the window never changes size.
/// Whether it shows is decided while the panel is closed (at launch and at each close), so it is
/// there from the open's first frame.
@MainActor
final class LoginPrompt: ObservableObject {
    enum Answer { case none, accepted }

    /// The card is up in the current open, or will be in the next one.
    @Published private(set) var isShowing: Bool
    @Published private(set) var answer: Answer = .none

    private var session: LaunchAtLoginPromptSession
    /// Bumped on every open/close, so a delayed auto-dismiss can't reach a later open.
    private var generation = 0

    init() {
        let session = LaunchAtLoginPromptSession(isEnabled: Self.isEnabled)
        self.session = session
        isShowing = session.isShowing
    }

    /// From the panel window (`PanelVisibilityObserver`): it was put on screen or taken off.
    func panelVisibilityChanged(onScreen: Bool) {
        guard onScreen != session.isPanelOnScreen else { return }
        generation += 1
        if onScreen {
            session.panelShown(at: Date())
        } else {
            session.panelHidden(at: Date(), isEnabled: Self.isEnabled)
            answer = .none
        }
        isShowing = session.isShowing
    }

    func accept() {
        session.answered()
        answer = .accepted
        // A short confirmation when it simply worked; the other outcomes wait for the user.
        if LaunchAtLogin.shared.setEnabled(true) == .enabled {
            let open = generation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.6))
                guard let self, self.generation == open, self.isShowing else { return }
                self.dismiss()
            }
        }
    }

    func decline() {
        session.answered()
        dismiss()
    }

    /// Takes the card away for the rest of this open (a click outside it, Done, No Thanks). Unread
    /// (under a second) it stays due for the next open; after that it counts as asked.
    func dismiss() {
        session.dismiss(at: Date())
        withAnimation(.easeOut(duration: 0.2)) { isShowing = session.isShowing }
    }

    private static func isEnabled() -> Bool {
        LaunchAtLogin.shared.refresh()
        return LaunchAtLogin.shared.status == .enabled
    }
}

/// The question over a dimmed panel (the panel keeps its size). The card covers the Memory and
/// Network cards edge to edge (their bounds come from `.loginPromptAnchor()` in the overview), so
/// its edges line up with the cards' and no value is cut in half; centred if those aren't on
/// screen. The dim takes clicks and hovers, so nothing under it opens by accident; a click on it
/// just puts the card away. Same dim strength as the guided tour on `feat/stability-tour`.
///
/// Launch at login turned on elsewhere (System Settings) while the card is up isn't watched: the
/// status is re-read whenever the panel closes (opening System Settings closes it), and the card
/// isn't shown again after that.
struct LoginPromptOverlay: View {
    @ObservedObject var prompt: LoginPrompt
    let anchors: [Anchor<CGRect>]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if prompt.isShowing {
                    Rectangle()
                        .fill(Color.black.opacity(colorScheme == .dark ? 0.40 : 0.30))
                        .onHover { _ in }
                        .contentShape(Rectangle())
                        .onTapGesture { prompt.dismiss() }
                        .accessibilityHidden(true)
                        .transition(.opacity)
                    card(in: proxy)
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func card(in proxy: GeometryProxy) -> some View {
        if let target = anchors.map({ proxy[$0] }).reduce(nil, { $0?.union($1) ?? $1 }) {
            LoginPromptCard(prompt: prompt, minHeight: target.height)
                .frame(width: target.width)
                .offset(x: target.minX, y: target.minY)
        } else {
            LoginPromptCard(prompt: prompt, minHeight: 0)
                .padding(.horizontal, Design.panelInset)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// Marks a card the login question covers (Memory and Network). Reports its bounds only while
/// the question is due (`loginPromptActive`), so it costs nothing otherwise.
struct LoginPromptAnchorKey: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value += nextValue()
    }
}

private struct LoginPromptActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the login question is due or up: `.loginPromptAnchor()` reports only then.
    var loginPromptActive: Bool {
        get { self[LoginPromptActiveKey.self] }
        set { self[LoginPromptActiveKey.self] = newValue }
    }
}

extension View {
    func loginPromptAnchor() -> some View { modifier(LoginPromptAnchorModifier()) }
}

private struct LoginPromptAnchorModifier: ViewModifier {
    @Environment(\.loginPromptActive) private var active

    func body(content: Content) -> some View {
        if active {
            content.anchorPreference(key: LoginPromptAnchorKey.self, value: .bounds) { [$0] }
        } else {
            content
        }
    }
}

/// The card: question, then the outcome in the same place, its content centred vertically in
/// at least `minHeight` (the two cards it covers). Return is the highlighted button, Esc the
/// other one (No Thanks, Done), as in a macOS alert.
struct LoginPromptCard: View {
    @ObservedObject var prompt: LoginPrompt
    let minHeight: CGFloat
    @ObservedObject private var login = LaunchAtLogin.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch (prompt.answer, login.status) {
            case (.none, _):
                message("Open MacStats at login?",
                        "Your stats stay one click away after a restart. You can change this any time in Settings.")
                buttons {
                    Button(action: prompt.decline) { Text("No Thanks").frame(maxWidth: .infinity) }
                        .buttonStyle(SubtleButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button(action: prompt.accept) { Text("Open at Login").frame(maxWidth: .infinity) }
                        .buttonStyle(SubtleButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
            case (.accepted, .enabled):
                message("MacStats will open at login.", "Change it any time in Settings.")
            case (.accepted, .requiresApproval):
                message("One more step", "Allow MacStats in Login Items to finish.")
                buttons {
                    Button(action: prompt.dismiss) { Text("Done").frame(maxWidth: .infinity) }
                        .buttonStyle(SubtleButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button {
                        login.openLoginItems()
                        prompt.dismiss()
                    } label: { Text("Open Login Items").frame(maxWidth: .infinity) }
                        .buttonStyle(SubtleButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
            case (.accepted, _):
                message("Couldn't turn it on.", "You can try again in Settings → Launch at login.")
                buttons {
                    // The only button, so it's the default one (Esc still closes the panel; it's
                    // already answered by now).
                    Button(action: prompt.dismiss) { Text("Done").frame(maxWidth: .infinity) }
                        .buttonStyle(SubtleButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Design.cardPadding)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
        .background(PromptSurface())
        .animation(.snappy(duration: 0.25), value: prompt.answer)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(detail)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
    }
}

/// The card's surface, the same as the guided tour's callouts and welcome card (`TourSurface`
/// on `feat/stability-tour`, values copied exactly): a system material (it floats over the
/// dimmed cards, so a plain tint would let their text show through), a near-solid window
/// colour with Reduce Transparency, the cards' hairline and the tour's one soft shadow
/// (`.black` 0.18, radius 12, y 4), so the two floating surfaces in the panel look alike.
private struct PromptSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Design.cardCornerRadius, style: .continuous)
        Group {
            if reduceTransparency {
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .overlay(shape.strokeBorder(Color.primary.opacity(Design.cardHairline), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

/// Reports when the panel window goes on or off screen. `onAppear` / `onDisappear` don't track
/// a `MenuBarExtra` window being ordered in and out reliably, while the window's occlusion
/// notification fires on every show and hide; `isVisible` tells which it was.
struct PanelVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    self.onChange?(window.isVisible)
                }
            }
            if window.isVisible { onChange?(true) }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
