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

/// The question over a dimmed panel, centred in it (the panel keeps its size). The dim takes
/// clicks and hovers, so nothing under it opens by accident; a click on it just puts the card
/// away. Same dim strength as the guided tour on `feat/stability-tour`.
struct LoginPromptOverlay: View {
    @ObservedObject var prompt: LoginPrompt
    @ObservedObject private var login = LaunchAtLogin.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if prompt.isShowing {
                Rectangle()
                    .fill(Color.black.opacity(colorScheme == .dark ? 0.40 : 0.30))
                    .onHover { _ in }
                    .contentShape(Rectangle())
                    .onTapGesture { prompt.dismiss() }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                LoginPromptCard(prompt: prompt)
                    .padding(.horizontal, Design.panelInset)
                    .transition(.opacity)
            }
        }
        // Turned on somewhere else (System Settings) while the question is up: nothing to ask.
        .onChange(of: login.status) { _, status in
            if status == .enabled, prompt.answer == .none, prompt.isShowing { prompt.dismiss() }
        }
    }
}

/// The card: question, then the outcome in the same place. Sized by its content (it floats, so
/// a change of height moves nothing else).
struct LoginPromptCard: View {
    @ObservedObject var prompt: LoginPrompt
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
                    Button(action: prompt.accept) { Text("Open at Login").frame(maxWidth: .infinity) }
                        .buttonStyle(SubtleButtonStyle(prominent: true))
                }
            case (.accepted, .enabled):
                message("MacStats will open at login.", "Change it any time in Settings.")
            case (.accepted, .requiresApproval):
                message("One more step", "Allow MacStats in Login Items to finish.")
                buttons {
                    Button(action: prompt.dismiss) { Text("Done").frame(maxWidth: .infinity) }
                        .buttonStyle(SubtleButtonStyle())
                    Button {
                        login.openLoginItems()
                        prompt.dismiss()
                    } label: { Text("Open Login Items").frame(maxWidth: .infinity) }
                        .buttonStyle(SubtleButtonStyle(prominent: true))
                }
            case (.accepted, _):
                message("Couldn't turn it on.", "You can try again in Settings → Launch at login.")
                buttons {
                    Button(action: prompt.dismiss) { Text("Done").frame(maxWidth: .infinity) }
                        .buttonStyle(SubtleButtonStyle())
                }
            }
        }
        .padding(Design.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
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

/// The card's surface: a system material (it floats over the dimmed cards, so a plain tint
/// would let their text show through), the cards' hairline and one soft shadow. The material
/// turns solid by itself with Reduce Transparency. Same surface as the tour's callouts.
private struct PromptSurface: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Design.cardCornerRadius, style: .continuous)
        shape.fill(.regularMaterial)
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
