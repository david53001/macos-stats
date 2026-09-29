import AppKit

/// Calls `onHover` when the pointer enters MacStats' menu-bar icon — the moment before a
/// likely click — so the popover can open on a fresh sample.
///
/// `MenuBarExtra` has no hover callback, so we attach a tracking area to the status-bar
/// button it creates (a public `NSStatusBarButton` inside our own `NSStatusBarWindow`).
/// If the button can't be found, hover does nothing and opening works as before.
@MainActor
final class StatusItemHover: NSResponder {
    private static var shared: StatusItemHover?

    private let onHover: () -> Void
    private weak var button: NSStatusBarButton?

    /// Installs the hover hook once. The status item is created by the `MenuBarExtra` scene
    /// after `App.init`, so attach shortly after launch, and again whenever the displays
    /// change (the menu bar can rebuild its status windows then).
    static func install(onHover: @escaping () -> Void) {
        guard shared == nil else { return }
        let hover = StatusItemHover(onHover: onHover)
        shared = hover
        for delay in [0.5, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { hover.attach() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in hover.attach() }
        }
    }

    private init(onHover: @escaping () -> Void) {
        self.onHover = onHover
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func attach() {
        guard let found = NSApp.windows.lazy
                .compactMap({ $0.contentView.flatMap(Self.statusButton(in:)) }).first,
              found !== button else { return }
        found.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
        button = found
    }

    private static func statusButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let button = statusButton(in: sub) { return button }
        }
        return nil
    }

    override func mouseEntered(with event: NSEvent) { onHover() }
}
