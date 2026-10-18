import AppKit
import SwiftUI
import ServiceManagement
import MacStatsCore

/// The one-time "Open MacStats at login?" question (rules: `MacStatsCore/LaunchAtLoginPrompt.swift`).
///
/// It is a card at the top of the panel, never a window or alert: it shows only inside a panel
/// the user just opened, so it can't take focus from what they were typing or doing, and it
/// never moves or covers anything mid-use. Whether it shows is decided while the panel is
/// closed (at launch and at each close), so the panel opens at its final size on frame one and
/// nothing resizes while it's open; after an answer the card keeps its size and shows the result
/// until the panel closes.
@MainActor
final class LoginPrompt: ObservableObject {
    enum Answer { case none, accepted, declined }

    /// The card is part of the panel's next (or current) open.
    @Published private(set) var isShowing = false
    @Published private(set) var answer: Answer = .none

    private let rules = LaunchAtLoginPrompt()
    private var openedAt: Date?

    init() {
        isShowing = isDue()
    }

    /// From the panel window (`PanelVisibilityObserver`): it was put on screen or taken off.
    func panelVisibilityChanged(onScreen: Bool) {
        if onScreen {
            guard openedAt == nil else { return }
            openedAt = Date()
            if isShowing { rules.markAsked() }   // seen = asked; at most once ever
        } else {
            guard let start = openedAt else { return }
            openedAt = nil
            if isShowing {
                // Asked (answered or not); the card is gone from the next open on.
                isShowing = false
                answer = .none
            } else if rules.recordUse(seconds: Date().timeIntervalSince(start)) {
                isShowing = isDue()
            }
        }
    }

    func accept() {
        answer = .accepted
        LaunchAtLogin.shared.setEnabled(true)
    }

    func decline() {
        answer = .declined
    }

    /// Reads the system status only once everything else says yes (it's an XPC call).
    private func isDue() -> Bool {
        guard rules.couldAsk else { return false }
        LaunchAtLogin.shared.refresh()
        return rules.shouldAsk(enabled: LaunchAtLogin.shared.status == .enabled)
    }
}

/// The card. Text is `.primary` on a near-opaque window-colour layer, so it keeps ≥ 4.5:1
/// contrast whatever shows through the panel and whatever the Opacity setting is (worst-case
/// numbers in docs/sparkle-updates/README.md). Same continuous corners and hairline as the cards.
struct LoginPromptCard: View {
    @ObservedObject var prompt: LoginPrompt
    @ObservedObject private var login = LaunchAtLogin.shared

    var body: some View {
        // The question's layout always sets the size, so the card never resizes on answering.
        ZStack(alignment: .leading) {
            question
                .opacity(prompt.answer == .none ? 1 : 0)
                .allowsHitTesting(prompt.answer == .none)
                .accessibilityHidden(prompt.answer != .none)
            if prompt.answer != .none {
                result
            }
        }
        .padding(.horizontal, Design.cardPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PromptBackground())
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Open MacStats at login?").font(.callout.weight(.semibold))
                Text("Your stats stay one click away after a restart.").font(.caption)
            }
            HStack(spacing: 6) {
                Spacer()
                Button("Not Now") { prompt.decline() }
                    .buttonStyle(SubtleButtonStyle())
                Button("Open at Login") { prompt.accept() }
                    .buttonStyle(SubtleButtonStyle())
            }
        }
    }

    @ViewBuilder private var result: some View {
        switch (prompt.answer, login.status) {
        case (.accepted, .enabled):
            message("MacStats will open at login.", "Change it any time in Settings.")
        case (.accepted, .requiresApproval):
            VStack(alignment: .leading, spacing: 8) {
                message("One more step", "Allow MacStats in Login Items to finish.")
                HStack {
                    Spacer()
                    Button("Open Login Items") { login.openLoginItems() }
                        .buttonStyle(SubtleButtonStyle())
                }
            }
        case (.accepted, _):
            message("Couldn't turn it on.", "You can try again in Settings → Launch at login.")
        default:
            message("No problem.", "You can turn it on any time in Settings.")
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.semibold))
            Text(detail).font(.caption)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A slightly transparent window-colour layer under the usual card tint + hairline: 90 % of
/// `windowBackgroundColor`, enough that even a pure white (dark mode) or black (light mode)
/// backdrop can't pull primary text under 4.5:1.
private struct PromptBackground: View {
    static let baseOpacity = 0.9

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Design.cardCornerRadius, style: .continuous)
        shape.fill(Color(nsColor: .windowBackgroundColor).opacity(Self.baseOpacity))
            .overlay(CardBackground())
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
