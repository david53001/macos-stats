# Squircle UI pass — progress note (2026-10-06)

Status: **done and committed** (code in `1ed61cf` on branch `feat/stability-tour`; this note in the commit
after it). Not released, not pushed as a release. Nothing is in progress.

## Terms

- **Squircle / continuous corners**: Apple's rounded-rectangle curve, where the straight edge eases into the
  corner instead of meeting a circular arc. In SwiftUI: `RoundedRectangle(cornerRadius:style: .continuous)`;
  in Core Animation: `layer.cornerCurve = .continuous`.
- **Concentric**: a shape nested inside another uses `inner radius = outer radius − gap`, so the gap between
  the two curves is even all the way round (how Apple nests cards, buttons and rows).
- **Popover / panel**: the window that opens when you click MacStats' menu-bar icon. SwiftUI creates it
  (`MenuBarExtra(.window)` → private `SwiftUI.MenuBarExtraWindow`, an `NSPanel`).

## What was wrong

The cards were already continuous-corner, 8 pt, designed to be concentric with a 16 pt panel
(`Design.panelCornerRadius` in `Sources/MacStatsApp/Design.swift`). But the panel window itself had
**~5 pt circular corners** drawn by the system, and no code ever applied the 16 pt value to it.
Found by dumping the panel's layer tree: the root layer had `cornerRadius 0`, `cornerCurve circular`.

## What changed

| Change | Where |
|---|---|
| `PanelShape.apply(to:)` rounds the panel window's root layer (`contentView.superview.layer`) to 16 pt, `.continuous`, `masksToBounds = true`, then `window.invalidateShadow()` so the shadow follows the new outline. The root layer already clips the Liquid Glass backdrop, so the glass and its rim follow too. | `Sources/MacStatsApp/Appearance.swift` |
| Re-applied on every show/appearance change by calling it from the existing `GlassTintHook.HookView.apply()` (the system rebuilds the panel's glass on each open). | same file |
| `SubtleButtonStyle` got a `cornerRadius` parameter (default 6). Footer **Quit** and **gear** use `Design.cardCornerRadius` (8 pt) — they sit 8 pt in from the panel's bottom corners, so 16 − 8 = 8 is concentric. | `StatCard.swift`, `OverviewView.swift` |
| Settings → Opacity **Default** button: system `.bordered` → `SubtleButtonStyle()` so it matches Empty/Quit. Shared spec updated to say so. | `SettingsView.swift`, `docs/design-language/opacity-setting.md` §2 |

Deliberately unchanged: usage/battery bars stay **capsules** (Apple's own bars are capsules); the status
dot stays a circle; the **Empty** button stays 6 pt (strict concentric radius inside the Trash card would be
~1 pt and look boxy — Apple also floors small inner radii); app icons keep their own macOS squircle (our
5.5 pt clip on the 24 pt icon doesn't touch it).

## Verification done

1. **Real popover** (opened programmatically, captured from inside the app with `CGWindowListCreateImage`):
   16 pt squircle outline, rim and shadow follow it at both zoomed corners, and it survives close → reopen
   (layer dump after reopen still `r=16 curve=continuous`). Dark mode only.
2. **Every drill-in, dark + light, off-screen** (see technique below): overview, CPU (incl. "Measuring…"),
   Memory, Battery, each with an app row expanded into its processes, Settings, and a pass with all hover
   states forced on. All surfaces continuous and concentric: list card 8 pt, row hover highlights 4 pt inside
   the list's 4 pt padding, scrolled rows clipped to the card's squircle.
3. `./Scripts/test.sh` → 255 tests pass; `./Scripts/bundle.sh` installed to `~/Applications/MacStats.app`.

## Open items / not verified

- **The audit above was run on the code as of `1ed61cf`.** Later commits on `feat/stability-tour` (stability
  + guided-tour review rounds 1–6, see `CLAUDE.md` Status) changed the breakdown rows, Battery details, header
  chip and added the tour overlay. The tour's cutout was designed concentric (card 8 / cutout 11 / panel 16,
  `Sources/MacStatsCore/TourLayout.swift`), but the rest has **not** been re-audited for squircle/concentric
  shapes — re-run the off-screen technique below before the next release.

- The **real** popover's outline was only captured in **dark mode**; light mode was checked in the off-screen
  render (which uses a stand-in `NSVisualEffectView` background, not the real Liquid Glass).
- `PanelShape` is applied one run-loop turn after the panel shows (same deferral as the opacity hook), so the
  very first open after launch *could* show one frame with the system's small corners. Not observed; not
  checked frame by frame. Later opens reuse the already-rounded window.
- Uses no private API, but relies on the panel's root layer clipping its sublayers; if a future macOS draws
  the glass outside that layer, the outline would revert to the system's (fails safe, nothing breaks).
- **JVoice and BetterScreenshot** share this design language (`docs/design-language/README.md`) and probably
  have the same small system window corners — not checked yet.

## Technique: render the UI off-screen without disturbing the user

Used so the user could keep working: a temporary hook (deleted before commit) that runs a **second copy** of
the app with **no menu-bar icon**, hosts `RootView` in a borderless window placed at (-30000, -30000) — never
on any display — drives it, captures PNGs, and quits. Captures went to the session scratchpad.

To reuse: add this file as `Sources/MacStatsApp/DebugSnapshot.swift`, and in `MacStatsMain.swift` add
`DebugSnapshot.run(model: model)` at the end of `init()` and change `MenuBarExtra {` to
`MenuBarExtra(isInserted: .constant(!DebugSnapshot.enabled)) {`. Then:

```bash
./Scripts/bundle.sh          # NOTE: quits the user's running MacStats; relaunch with `open ~/Applications/MacStats.app`
MACSTATS_SNAPSHOT=1 ~/Applications/MacStats.app/Contents/MacOS/MacStats   # ~45 s, exits by itself
```

Remove both edits and the file before committing.

```swift
// TEMPORARY debug hook — remove before commit.
import AppKit
import SwiftUI
import MacStatsCore

@MainActor
enum DebugSnapshot {
    static let enabled = ProcessInfo.processInfo.environment["MACSTATS_SNAPSHOT"] != nil
    static let out = NSTemporaryDirectory() + "macstats-shots"   // pick any folder
    static var window: NSWindow!
    static var model: AppModel!
    static var steps: [(Double, () -> Void)] = []

    static func run(model m: AppModel) {
        guard enabled else { return }
        model = m
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { start() }
    }

    static func start() {
        let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: Design.panelWidth, height: Design.panelHeight),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.isReleasedWhenClosed = false
        let effect = NSVisualEffectView()            // stand-in for the real Liquid Glass
        effect.material = .popover; effect.blendingMode = .withinWindow; effect.state = .active
        let host = NSHostingView(rootView: RootView(model: model, store: model.store))
        host.frame = effect.bounds; host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        w.contentView = effect
        w.orderFrontRegardless()                     // off-screen: never visible, never activates the app
        w.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window = w
        for scheme in ["dark", "light"] {
            step(0.5) { w.appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua) }
            step(1.5) { shot("\(scheme)-overview") }
            step(0.1) { model.enterBreakdown(.cpu) }
            step(3.0) { shot("\(scheme)-cpu") }
            step(0.1) { expandFirst() }
            step(1.0) { shot("\(scheme)-cpu-expanded") }
            // … same for .memory and .energy …
            step(0.1) { model.exitBreakdown() }
            step(1.0) { click(NSPoint(x: Design.panelWidth - 22, y: 20)) }   // footer gear → Settings
            step(1.0) { shot("\(scheme)-settings") }
            step(0.1) { click(NSPoint(x: 30, y: Design.panelHeight - 18)) } // back
        }
        step(0.5) { exit(0) }
        next()
    }

    static func step(_ d: Double, _ body: @escaping () -> Void) { steps.append((d, body)) }
    static func next() {
        guard !steps.isEmpty else { return }
        let (d, body) = steps.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + d) { body(); next() }
    }

    /// Captures just this window, even though it is off every display.
    static func shot(_ name: String) {
        guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                [.bestResolution, .boundsIgnoreFraming]) else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }

    /// Clicks the first app row with several processes. Row geometry (points, from captures, 2026-10-06):
    /// list top 36 / 83 / 136 for CPU / Memory / Battery; row height 41 (CPU) or 36.
    /// (Finding rows via the accessibility tree by app name did not work.)
    static func expandFirst() {
        let store = model.store
        guard let i = store.breakdown.firstIndex(where: { $0.processes.count > 1 }),
              let metric = store.activeBreakdownMetric else { return }
        let (top, h): (CGFloat, CGFloat) = metric == .cpu ? (36, 41) : metric == .memory ? (83, 36) : (136, 36)
        click(NSPoint(x: 120, y: Design.panelHeight - (top + 4 + h * (CGFloat(i) + 0.5))))
    }

    /// Synthetic click delivered straight to the window (works for SwiftUI buttons and tap gestures).
    static func click(_ p: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(e) }
        }
    }
}
```

Hover states can't be triggered this way (SwiftUI `onHover` needs real pointer tracking). To see them,
temporarily change `@State private var hovering = false` to `true` in `BreakdownView.swift` and
`StatCard.swift`, capture, and revert.
