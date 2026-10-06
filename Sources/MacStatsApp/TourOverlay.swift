import SwiftUI
import MacStatsCore

// The guided tour's views, all inside the panel (a separate window would take focus, which
// closes a menu-bar panel). `.tourHost` puts the overlay on the panel's fixed frame; each target
// reports its rect with `.tourAnchor`, only while the tour is on screen, so it costs nothing
// otherwise. Geometry: `TourLayout` (MacStatsCore); design: docs/research/2026-10-06-tour-design.md.

/// A highlighted element's bounds and corner radius.
struct TourAnchor: Equatable {
    let bounds: Anchor<CGRect>
    let radius: CGFloat
}

struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [String: TourAnchor] = [:]
    static func reduce(value: inout [String: TourAnchor], nextValue: () -> [String: TourAnchor]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct TourActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the tour (or the welcome) is on screen: anchors report their rects only then.
    var tourActive: Bool {
        get { self[TourActiveKey.self] }
        set { self[TourActiveKey.self] = newValue }
    }
}

extension View {
    /// Marks a tour target. Apply it outside the target's button style, so a pressed card's
    /// scale never moves the rect.
    func tourAnchor(_ id: String, radius: CGFloat) -> some View {
        modifier(TourAnchorModifier(id: id, radius: radius))
    }

    /// The tour overlay over this (fixed-size) panel content, while `tour` is active and
    /// `showing` (the overview is the current screen). Shared by `RootView` and the render probe.
    func tourHost(_ tour: TourController, showing: Bool) -> some View {
        modifier(TourHost(tour: tour, showing: showing))
    }
}

private struct TourAnchorModifier: ViewModifier {
    let id: String
    let radius: CGFloat
    @Environment(\.tourActive) private var active

    func body(content: Content) -> some View {
        if active {
            content.anchorPreference(key: TourAnchorKey.self, value: .bounds) {
                [id: TourAnchor(bounds: $0, radius: radius)]
            }
        } else {
            content
        }
    }
}

private struct TourHost: ViewModifier {
    @ObservedObject var tour: TourController
    let showing: Bool

    func body(content: Content) -> some View {
        let active = tour.isActive && showing
        content
            .environment(\.tourActive, active)
            .overlayPreferenceValue(TourAnchorKey.self) { anchors in
                ZStack {
                    if active {
                        TourOverlay(tour: tour, anchors: anchors).transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: active)
            }
    }
}

/// The dim with a squircle hole over the current target, the accent ring inside the hole's
/// edge, and the callout (or the welcome card). Swallows every click and hover under it, so
/// nothing behind the tour can be opened by accident; only its own buttons work.
private struct TourOverlay: View {
    @ObservedObject var tour: TourController
    let anchors: [String: TourAnchor]

    @Environment(\.displayScale) private var scale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var calloutHeight: CGFloat?
    @State private var welcomeHeight: CGFloat?

    /// -1 on the welcome card, else the step index: what the motion animates between.
    private var phaseKey: Int { tour.currentStep?.index ?? -1 }

    var body: some View {
        GeometryReader { proxy in
            let panel = CGRect(origin: .zero, size: proxy.size)
            ZStack(alignment: .topLeading) {
                content(panel: panel, hole: hole(proxy, panel: panel))
                    // Reduce Motion: a short cross-fade between steps instead of moving.
                    .id(reduceMotion ? phaseKey : 0)
                    .transition(.opacity)
                keyboardShortcuts
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.3), value: phaseKey)
        }
        .accessibilityAddTraits(.isModal)
    }

    /// The current target's cutout, nil on the welcome card (or before its anchor resolved).
    private func hole(_ proxy: GeometryProxy, panel: CGRect) -> (rect: CGRect, radius: CGFloat)? {
        guard let step = tour.currentStep?.step, let anchor = anchors[step.anchor] else { return nil }
        return TourLayout.cutout(target: proxy[anchor.bounds], targetRadius: anchor.radius, panel: panel,
                                 scale: scale)
    }

    @ViewBuilder
    private func content(panel: CGRect, hole: (rect: CGRect, radius: CGFloat)?) -> some View {
        // On the welcome card the hole is a point at the centre, so it opens out to the first card.
        let cut = hole ?? (CGRect(x: panel.midX, y: panel.midY, width: 0, height: 0), 0)
        ZStack(alignment: .topLeading) {
            TourDimShape(cutout: cut.rect, cutoutRadius: cut.radius)
                .fill(Color.black.opacity(colorScheme == .dark ? 0.40 : 0.25), style: FillStyle(eoFill: true))
                .contentShape(Rectangle())
                .onTapGesture {}
                .onHover { _ in }
                .accessibilityHidden(true)

            if tour.state.phase == .welcome {
                let frame = TourLayout.welcome(height: welcomeHeight ?? 0, panel: panel, scale: scale)
                WelcomeCard(showsPermissions: tour.defersPermissionPrompts,
                            onNoThanks: { tour.noThanks() }, onStart: { tour.start() })
                    .frame(width: frame.width)
                    .measuredHeight($welcomeHeight)
                    .offset(x: frame.minX, y: frame.minY)
            } else if let hole, let current = tour.currentStep, let progress = tour.progress {
                let frame = TourLayout.callout(cutout: hole.rect, height: calloutHeight ?? 0, panel: panel,
                                               scale: scale)
                ZStack(alignment: .topLeading) {
                    TourCallout(step: current.step, progress: progress,
                                onSkip: { tour.skip() }, onBack: { tour.back() }, onNext: { tour.next() })
                        .frame(width: frame.width)
                        .measuredHeight($calloutHeight)
                        .offset(x: frame.minX, y: frame.minY)
                }
                .frame(width: panel.width, height: panel.height, alignment: .topLeading)
                // Keeps the callout's shadow off the hole, so the highlighted card's margins
                // look the same on all four sides.
                .mask(TourDimShape(cutout: hole.rect, cutoutRadius: hole.radius).fill(style: FillStyle(eoFill: true)))
            }

            // Above the callout, so its shadow never tints the ring.
            if let hole {
                RoundedRectangle(cornerRadius: hole.radius, style: .continuous)
                    .strokeBorder(Color.accentColor,
                                  lineWidth: contrast == .increased ? TourLayout.ringWidth + 1 : TourLayout.ringWidth)
                    .frame(width: hole.rect.width, height: hole.rect.height)
                    .offset(x: hole.rect.minX, y: hole.rect.minY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: panel.width, height: panel.height, alignment: .topLeading)
    }

    /// → Next, ← Back, Esc Skip Tour (Return is the callout's default button). Zero-size and
    /// transparent, not `.hidden()`: a hidden button's shortcut doesn't fire.
    @ViewBuilder private var keyboardShortcuts: some View {
        if tour.currentStep != nil {
            ZStack {
                Button("") { tour.next() }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { tour.back() }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { tour.skip() }.keyboardShortcut(.cancelAction)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }
}

/// The panel's squircle with the cutout's squircle taken out (even-odd fill). The cutout
/// animates, so the hole glides from card to card.
private struct TourDimShape: Shape {
    var cutout: CGRect
    var cutoutRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>> {
        get {
            AnimatablePair(AnimatablePair(cutout.minX, cutout.minY),
                           AnimatablePair(AnimatablePair(cutout.width, cutout.height), cutoutRadius))
        }
        set {
            cutout = CGRect(x: newValue.first.first, y: newValue.first.second,
                            width: newValue.second.first.first, height: newValue.second.first.second)
            cutoutRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: Design.panelCornerRadius, style: .continuous)
        if cutout.width > 0, cutout.height > 0 {
            let r = min(cutoutRadius, cutout.width / 2, cutout.height / 2)
            path.addRoundedRect(in: cutout, cornerSize: CGSize(width: r, height: r), style: .continuous)
        }
        return path
    }
}

/// The callout and welcome card surface: a system material (solid with Reduce Transparency), a
/// hairline and one soft shadow. Never reads the Opacity setting, so text contrast doesn't
/// depend on it.
private struct TourSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TourLayout.calloutRadius, style: .continuous)
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

/// One step's bubble: title, body (always two lines' room, so every step has the same height
/// and the bubble never jumps), "n of m" and the buttons.
struct TourCallout: View {
    let step: TourStep
    let progress: (number: Int, total: Int)
    let onSkip: () -> Void
    let onBack: () -> Void
    let onNext: () -> Void

    private var isFirst: Bool { progress.number == 1 }
    private var isLast: Bool { progress.number == progress.total }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(step.title).font(.headline)
            Text(step.body)
                .font(.callout)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("\(progress.number) of \(progress.total)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 0)
                if !isLast {
                    Button(TourCatalog.skipTour, action: onSkip)
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !isFirst {
                    Button(TourCatalog.back, action: onBack)
                        .buttonStyle(SubtleButtonStyle())
                }
                Button(isLast ? TourCatalog.done : TourCatalog.next, action: onNext)
                    .buttonStyle(SubtleButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
            .frame(height: 24)
            .padding(.top, 6)
        }
        .padding(Design.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TourSurface())
        .accessibilityElement(children: .contain)
    }
}

/// A new user's first open: what MacStats is, why macOS is about to ask for two permissions,
/// and whether they want the tour. Centred in the panel over the dim.
struct WelcomeCard: View {
    /// The two permission lines, only while those prompts are still waiting for this card.
    let showsPermissions: Bool
    let onNoThanks: () -> Void
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // The menu-bar icon the user just clicked.
            Image(nsImage: MenuBarLabel.sparkline)
                .renderingMode(.template)
                .resizable()
                .frame(width: 36, height: 36)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            Text(TourCatalog.welcomeTitle)
                .font(.title3.weight(.semibold))
                .padding(.top, 8)
            Text(TourCatalog.welcomeBody)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            if showsPermissions {
                VStack(alignment: .leading, spacing: 6) {
                    permissionLine("bell", TourCatalog.alertsPermission)
                    permissionLine("trash", TourCatalog.finderPermission)
                }
                .padding(.top, 12)
            }
            Divider().padding(.vertical, 12)
            Text(TourCatalog.welcomeQuestion).font(.headline)
            Text(TourCatalog.welcomeSubline)
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 2)
            HStack(spacing: 8) {
                Button(action: onNoThanks) { Text(TourCatalog.noThanks).frame(maxWidth: .infinity) }
                    .buttonStyle(SubtleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(action: onStart) { Text(TourCatalog.showMeAround).frame(maxWidth: .infinity) }
                    .buttonStyle(SubtleButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, Design.cardPadding)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(TourSurface())
        .accessibilityElement(children: .contain)
    }

    private func permissionLine(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The existing-user offer in the overview header: "Take the Tour" and a ✕. Laid out as an
/// overlay, so it never moves the title.
struct TourOfferChip: View {
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onStart) { Text(TourCatalog.takeTheTour).font(.caption.weight(.medium)) }
                .buttonStyle(SubtleButtonStyle(height: 20))
            Button(action: onDismiss) { Image(systemName: "xmark").font(.caption2.weight(.semibold)) }
                .buttonStyle(SubtleButtonStyle(height: 20))
                .accessibilityLabel("Dismiss")
                .help("Dismiss")
        }
    }
}

/// The footer's `?`, left of the gear: replays the tour from step 1.
struct HelpButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "questionmark")
                .frame(width: Design.footerIconWidth)
                .accessibilityLabel(TourCatalog.takeTheTour)
        }
        .buttonStyle(SubtleButtonStyle(cornerRadius: Design.cardCornerRadius))   // concentric, like Quit
        .help(TourCatalog.takeTheTour)
    }
}

private struct MeasuredHeightKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

private extension View {
    /// Writes the view's laid-out height into `height`, and hides it until it is known (its
    /// frame is computed from that height).
    func measuredHeight(_ height: Binding<CGFloat?>) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: MeasuredHeightKey.self, value: geo.size.height)
        })
        .onPreferenceChange(MeasuredHeightKey.self) { if let h = $0, h != height.wrappedValue { height.wrappedValue = h } }
        .opacity(height.wrappedValue == nil ? 0 : 1)
    }
}
