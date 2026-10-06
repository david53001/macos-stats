# MacStats guided tour + introduction — research and design (2026-10-06)

**Status:** research and design only. No source code has been changed for this yet.
**Branch:** `feat/stability-tour` (baseline commit `1ed61cf`).
**Repo:** `/Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats`. Build, test and SDK notes are in its `CLAUDE.md`.

This document stands on its own. Part A explains how the owner's other two apps, **BetterScreenshot** and **JVoice**, build their
intro and tour. Part B is the design for MacStats: what to build, the exact copy, the geometry, the persistence keys and the tests.
Part C lists the pitfalls specific to `MenuBarExtra`.

## Terms

- **Popover / panel:** the MacStats window that opens when you click the menu-bar graph icon. It is a SwiftUI
  `MenuBarExtra(.window)`, always **320 × 404 pt** (`Design.panelWidth` / `Design.panelHeight` in
  `Sources/MacStatsApp/Design.swift`), with squircle corners of 16 pt.
- **Card:** one inset rounded surface in the overview (CPU, Memory, Network, Battery, Trash). Its corners are
  **8 pt** continuous (`Design.cardCornerRadius` = panel radius 16 − panel inset 8).
- **Squircle / continuous corners:** Apple's smooth corner curve. In SwiftUI: `RoundedRectangle(cornerRadius:style: .continuous)`.
- **Concentric:** a rounded shape inside or around another has radius = the other's radius ± the gap between them, so the curves run parallel.
- **Tour:** an ordered list of **steps**. Each step highlights one real element, its **anchor**, and shows a short **callout**
  (BetterScreenshot calls it a "tag") with a title, a body, "n of m" and buttons.
- **Cutout:** the clear hole in the dim layer over the highlighted card. **Ring:** the thin outline drawn around the cutout.
- **Intro / welcome card:** the first screen a new user sees, asking whether they want the tour.
- **Explain step:** advances when the user presses Next. **Try step:** advances by itself when the user does the thing.
- **WCAG AA:** the web accessibility contrast minimum, 4.5:1 for normal-size text. **NN/g:** Nielsen Norman Group, a UX research firm.
- **Audience:** `new` or `existing`. Worked out once at the first launch of a build that has tours, then stored and never recomputed.

---

## Part A — How BetterScreenshot and JVoice do it

Sources read:
- BetterScreenshot: `/Users/davidghermansteinberg/Desktop/Home/Projects/Code/BetterScreenshot/`
  - `Packages/TourKit/CLAUDE.md` and `Sources/TourKit/*`: `TourModel`, `TourEngine`, `TourRules`, `TourAudience`, `TourAnchor`,
    `TourEvents`, `Overlay/TagStyle`, `TagLayout`, `TagViews`, `TagKeys`, `TagOverlayController`, `Help/InfoButton`
  - `App/Tours/CLAUDE.md`, `App/Tours/TourCoordinator.swift`
  - `App/MenuBar/OnboardingController.swift`
  - `App/Settings/SettingsView.swift` ("Tours & tips")
  - Spec `docs/superpowers/specs/2026-09-24-betterscreenshot-editor-recording-v3-design.md` §14 and §14.9
  - Review `docs/reviews/2026-09-26-tours-review.md`, which scored the tours 6/10 and is the main source of lessons
- JVoice: `/Users/davidghermansteinberg/Desktop/Home/Projects/Code/JVoice/`
  - `Sources/JVoice/Tours/CLAUDE.md`, `Tours/TourCatalog.swift`, `Tours/Kit/*` (a port of TourKit)
  - `Sources/JVoice/UI/WelcomeWindow.swift`

### A1. Step model
- `Tour` holds an `id` (`TourID`, a persisted raw value that is never renamed), a `version: Int`, a `surface` (the window it runs in),
  a `trigger` (`.surfaceShown`, `.event`, `.startedByApp`), `steps`, and an optional `handsOverTo` (a chain such as Welcome → Quick Access → Editor).
- `TourStep` holds an `anchor` id (`"<surface>.<name>"`), a `kind` (`.explain`, or `.tryIt(advanceOn: TourEvent)`), a `title`, a `body`,
  `requires: TourEvent?` (show the step only if that event was seen), and `placement` (`.automatic/.left/.right/.above/.below/.insideCorner`).
- `TourEngine` is a **pure value-type state machine**: start / next / skipStep / skipTour / handle(event) / pause / resume /
  skipIfAnchorMissing. Each call returns an `Effect` (`.show(step)`, `.finished(handsOverTo)`, `.skipped`, `.paused(at)`,
  `.nothingToShow`, `.none`) that the app's `TourCoordinator` carries out. Whether an anchor is on screen is passed in as a closure
  `isPresent: (String) -> Bool`, which keeps the engine testable. If an anchor is missing, its step is skipped. If nothing can be shown,
  the result is `.nothingToShow` and the tour is **not** marked as seen.
- `progress(isPresent:)` gives "n of m" counted over the steps that will actually show. It does not use the catalog index.
  This fixed review issue T2, where the counter jumped 1 → 3 → 4.

### A2. Anchors
- AppKit: `NSView.tourAnchor` stores the id as the view's accessibility identifier. SwiftUI: `.tourAnchor("id", cornerRadius:)` puts a
  transparent `NSView` behind the content. The overlay then finds the view through `NSWindow.view(forTourAnchor:)`.
- `tourOutline` reads the anchor's **own corner radius**, so the outline can be concentric with a card or pill instead of a fixed 6 pt box.

### A3. Drawing (spotlight and outline)
- There are two child **windows** over the host window. The decor panel is click-through: it holds the dim, the outline box and a
  leader line. The tag panel is clickable. Neither one ever becomes key.
- The dim is black at 20 % (35 % over dark hosts). It is an even-odd path of the window shape minus the outline's outer edge, drawn with
  `NSBezierPath(continuousRoundedRect:)`.
- Box: anchor + **4 pt padding**, a 2 pt stroke outside that. Inner radius = `anchorRadius + boxPadding`, so it is concentric
  (`TagStyle.boxRadius(anchorRadius:box:)`), and it is capped at a capsule.
- BetterScreenshot's tag is red `#C62D22`, darkened from `#FF453A` so it passes WCAG AA, with white text at 5.5:1. JVoice's tag is
  **monochrome**: near-black on light, white on dark, 19:1.

### A4. Tag (callout) layout and copy
- The tag is 200–260 pt wide, radius 12. Title 13 pt semibold, body 12 pt with **at most 2 lines**, footer 11 pt.
- The footer reads `n of m · Skip Tour · Next`. On the last Explain step, Next becomes **Done** and **Skip Tour is hidden** (review T6).
  Try steps show an outlined "Skip Step" instead of Next. Buttons are Title Case.
- Pure `TagLayout` decides the placement. It tries the step's own placement first, then the side that has room. A "big" anchor (60 % or
  more of the window on both axes) puts the tag beside the window or inside its top-right corner. Controls in a wide bar or in the title
  bar put the tag above or below. Everything is clamped to the screen with an 8 pt margin, and the leader line is routed around other controls.
- **Copy rules** are enforced by the lint test `CatalogLintTests`:
  - Title at most 4 words. Body at most 20 words, in 1–2 sentences.
  - Try bodies start with a verb.
  - Apostrophes are typographic (’).
  - Step titles are unique within a tour.
  - Shortcuts are written as `{shortcut:name}` placeholders, so they show the user's real keys.
  - `TagFitTests` measures each body in the real font at the tag's width and checks that it fits 2 lines.

### A5. Keys
- `TagKeys` is pure and unit-tested. **Return / keypad Enter = Next** on Explain steps, **Esc = Skip Tour**.
- The keys are ignored for key repeats, when a modifier is held, while text is being edited, and while the host claims them
  (`TourKeysClaiming`, used when a shortcut well is recording; `TourEscapeClaiming`, used for the editor's own Esc).
- There is **no Back** and there are no arrow keys.

### A6. Who sees it, persistence, replay
- **New users only, and they are asked first** (§14.9). The owner said: "If the user has data and they've already been using the app it
  shouldn't prompt them again … it can be very annoying."
- `TourAudience.classify` runs **first thing at launch, before the app writes any preference**. The user counts as `existing` if any of these is true:
  - any non-tour key is in the app's **own** defaults domain (`persistentDomain(forName: bundleID)`)
  - the support folder has content
  - a permission is already granted
  - the bundle id is unexpected

  When in doubt, the answer is existing ("a missed new user is harmless, a nagged one is not").
- The new user's welcome window ends with **"Want a quick tour?"**, body "We'll point out each part the first time you use it. You can
  skip any time.", and buttons **No Thanks** (Esc) / **Show Me Around** (Return, default). In JVoice, closing the window counts as No Thanks.
- Tours start by themselves only if `firstUseToursEnabled == true` (absent means off) and that tour's version has not been seen.
  Existing users **never** get an automatic tour.
- Persisted keys (`TourPreferenceKey`; nothing else is stored): `tourAudience`, `tourQuestionAnswered`, `firstUseToursEnabled`,
  `toursSeen` (tour id → version), `toursPaused` (tour id → step index).
- Replay comes from three places:
  - the ⓘ button in the top-right of every window, whose menu has Replay Tour, one item per step in JVoice ("Show Me"), and Keyboard Shortcuts
  - the menu bar's **Help & Tours** submenu
  - Settings → **Tours & tips**, which has a toggle and "Reset All Tours" with a confirmation that explains itself
- If the host window closes, the tour **pauses** and resumes at that step later.

### A7. Tests
- `TourEngineTests`, `TourRulesTests`, `TourAudienceTests`, `TagLayoutTests` (470 lines of geometry), `TagKeysTests`,
  `TagContrastTests` (WCAG for every text and background pair), `TagFitTests`, `CatalogLintTests`, `CatalogShapeTests`.
- End-to-end checks run in probes with `UserDefaults(suiteName:)`, never the real domain, and windows placed at desktop level with `orderBack`.

### A8. Lessons from the BetterScreenshot tours review that apply here
| Review issue | Lesson for MacStats |
|---|---|
| T1: contrast below AA | Callout text must clear 4.5:1 in light, dark, and at every Opacity setting. |
| T2: counter skipped numbers | Count only the steps that show. MacStats needs this when the Battery step is skipped on a desktop Mac. |
| T3/E1: tags over neighbouring UI | In a 320 × 404 panel the callout *will* cover other cards. It must never cover the **target**, and it should cover the least important area. |
| E2/R2: tours too long | Aim for **3–5 steps**. Welcome + Quick Access + Editor ran to 16 steps in a row and got cut. |
| P1: tour over a live task | Don't run Try steps that change real state (no "Empty Trash" or "Quit" in the tour). |
| W3: truncated text | Run a fit test at the real callout width. |
| T6: Title Case, no Skip Tour next to Done | Keep both rules. |

---

## Part B — The MacStats design

### B1. What carries over and what doesn't

| Sibling app approach | MacStats |
|---|---|
| Separate child windows for the overlay | **Don't.** The overlay is a SwiftUI layer *inside* the panel. A new window would steal focus, and the `MenuBarExtra` panel closes when it loses focus (Part C). |
| AppKit anchor lookup (accessibility id) | **SwiftUI `anchorPreference`** in the panel's own coordinate space. Every target is SwiftUI. |
| Separate Welcome window | **A welcome card inside the panel**, shown on the first open. No window ever appears on its own. |
| Pure engine + rules + lint tests | **Keep all of it**, as small pure types in `MacStatsCore`, tested with Swift Testing. |
| Multi-tour engine (surfaces, events, hand-over, Try steps, pause dictionary) | **Not needed.** There is one short Explain-only tour. A single `TourState` value replaces it. |
| Red or monochrome tag | **Native callout:** a card-shaped bubble on a system material, with system accent colour only for the ring and the primary button. |
| ⓘ button + Help & Tours menu | A **`?` button in the footer** next to the gear, plus **Settings → Help → Take the Tour**. |
| "Want a quick tour?" / No Thanks / Show Me Around | **Same strings**, so all three of the owner's apps match. |
| Existing users never offered | **Offer them once, quietly.** The owner asked for this. Details in B6. |

### B2. Files (proposed)
- `Sources/MacStatsCore/Tour.swift`: pure types `TourStep`, `TourCatalog`, `TourState`, `TourRules`, `TourAudience`, `TourKey`. No SwiftUI.
- `Sources/MacStatsCore/TourLayout.swift`: pure CoreGraphics maths for the cutout and the callout frame, plus pixel rounding.
- `Sources/MacStatsApp/TourOverlay.swift`:
  - `TourAnchorKey` (a preference key) and the `.tourAnchor(_:)` modifier
  - `TourController` (an `ObservableObject` owned by `AppModel`)
  - the views `TourOverlay`, `TourCallout`, `WelcomeCard` and `TourOfferChip`
- Small edits:
  - `MacStatsApp.swift`: classify the audience before `AppModel()`.
  - `RootView.swift`: overlay plus the start and pause hooks.
  - `OverviewView.swift`: anchors, the `?` button and the chip.
  - `SettingsView.swift`: a Help card.
- `Tests/MacStatsCoreTests/TourStateTests.swift`, `TourRulesTests.swift`, `TourLayoutTests.swift`, `TourCatalogLintTests.swift`.

Tour state lives in its **own** `TourController`, not in `MetricsStore`. Only `RootView` observes it, so a step change never re-renders
the cards, and a card's 0.5 s tick never re-runs the tour logic.

### B3. The tour: steps and exact copy

The tour has one welcome card, then **5 Explain steps** (4 on a Mac without a battery). Every step is Explain-only, so the tour never
changes real state. Copy follows BetterScreenshot's lint rules: title ≤ 4 words, body ≤ 20 words in 1–2 sentences, typographic ’,
no live numbers quoted (the values change under the tour).

**Welcome card** (new users, first open; no cutout, centred in the panel):
- Symbol: the menu-bar graph icon (`MenuBarLabel.sparkline`, drawn as a template image at about 36 pt). This ties the card to the icon the user just clicked.
- Title: **Welcome to MacStats**
- Body: **Your Mac’s CPU, memory, network and battery, live, from this graph icon in your menu bar.**
- Divider, then **Want a quick tour?** with the sub-line **Five quick stops. You can skip any time.**
- Buttons: **No Thanks** (Esc) · **Show Me Around** (Return, default/prominent)

| # | Anchor id | Title | Body | Shown when |
|---|---|---|---|---|
| 1 | `overview.cpu` | **How busy your Mac** | The big number is right now; the graph is the last minute. Click the card to see which apps. | always |
| 2 | `overview.memory` | **Memory in use** | How much memory apps are using. The dot turns yellow or red when your Mac runs short. | always |
| 3 | `overview.network` | **Internet speed** | ↓ is download and ↑ is upload, right now. The graph shows downloads over the last minute. | always |
| 4 | `overview.battery` | **Battery and time left** | Charge and a steady estimate of time left. Click for battery health and which apps use power. | `store.battery != nil` |
| 5 | `overview.footer` | **Settings and help** | The gear holds Settings. Click ? any time to see this tour again. | always (last: **Done**) |

Notes on the copy:
- Step 1 doesn't mention temperature, because the meta line reads "live" on chips without a usable sensor.
- Step 2's dot matches `pressureColor` in `OverviewView` (green / yellow / red = kernel memory pressure).
- Step 3's graph is `netDownHistory`, which is downloads only, so the copy is accurate.
- Trash gets no step. It is self-explanatory ("Trash · 1.2 GB · Empty"), and every extra step lowers completion (B9).
- Step 5 ends on where to find help again, which is the most useful thing to leave a new user with.
- Optional later addition, "first drill-in hint": the first time a user opens any breakdown, show one inline line at the top of the list:
  **Click an app to see its processes. Right-click to quit it.** Dismiss it on the first click, key `tourBreakdownHintSeen`.
  This teaches the expandable rows at the moment they matter, without making the overview tour longer. Build it after the
  row-jumping fix, so the hint doesn't point at rows that re-sort.

### B4. Overlay geometry (the "perfectly centred" requirement)

**Anchors.** Each target gets `.anchorPreference(key: TourAnchorKey.self, value: .bounds) { [id: $0] }`. `TourAnchorKey` is a
`[String: Anchor<CGRect>]` preference that merges dictionaries. Attach it **on the outside of the `StatCard`**, in `OverviewView`. It
must not go inside `CardButtonStyle`, so that the press `scaleEffect(0.985)` never changes the measured rect. The anchor also carries
the target's corner radius: 8 for cards, and 6 for the footer button group (`SubtleButtonStyle` default; the Quit button uses 8, but it isn't a target).

**Resolve in the panel's space.** In `RootView`, `.overlayPreferenceValue(TourAnchorKey.self) { anchors in GeometryReader { proxy in … proxy[anchor] … } }`
sits on the same 320 × 404 frame as the screens, so `proxy[anchor]` is already in panel coordinates. There are no window conversions and no NSView lookups.

**Cutout maths** (pure, in `TourLayout`):
```
inset   i = Design.cardSpacing / 2 = 3 pt   // halfway into the 6 pt gap between cards: the hole never touches a neighbour
cutout    = target.insetBy(dx: -i, dy: -i)  // equal on all four sides by construction
radius    = targetRadius + i                // 8 + 3 = 11: concentric with the card…
                                            // …and with the panel too: card edge to panel edge is 8, so 11 + (8 − 3) = 16 = panel radius
pixel-align: round each EDGE (minX, minY, maxX, maxY) to 1/scale (scale = @Environment(\.displayScale)),
             not origin + size, so the left and right margins can't differ by one device pixel.
clamp      : keep the cutout inside the panel rect (it already is: 8 − 3 = 5 pt to every panel edge).
```
For any target this keeps card (8), ring (9…11) and panel (16) concentric, all with continuous corners.

**Dim with hole.** Use one `Shape` (`TourDimShape`) that adds the panel rect (`RoundedRectangle` 16, `.continuous`) and the cutout
(`RoundedRectangle` radius, `.continuous`), filled with `FillStyle(eoFill: true)`. Its `animatableData` is the cutout's
(minX, minY, width, height), so moving between cards animates smoothly. The colour is `Color.black.opacity(0.25)` in light and `0.40`
in dark; tune these in the probe against the Liquid Glass at Opacity 0, 0.5 and 1.

**Ring.** `RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)` on the cutout rect.
`strokeBorder` keeps the stroke inside the hole, so it spans 1–3 pt outside the card with a 1 pt clear gap, and its inner edge has radius 9,
concentric with the card's 8. This is the macOS **focus ring** idea: the accent colour, just outside the control, following its shape.
That makes it the Apple-native way to say "this one", where the sibling apps use red. With **Increase Contrast** on, raise the width to 3
and drop the 1 pt gap. A 2 pt line on edges rounded to whole pixels is crisp at 2× scale.

**Callout frame** (pure, `TourLayout.callout(target cutout:, size:, panel:)`):
- Width = card width = 320 − 2 × 8 = **304 pt**, x = 8. The radius is **8**, concentric with the panel the same way the cards are.
- Height comes from the content: title (`.headline`), body (`.callout`, at most 2 lines at 304 − 2 × 12 = 280 pt), and the footer row (24 pt). That totals about 96–104 pt.
- Gap to the cutout = **6 pt** (`cardSpacing`).
- Rule:
  1. **Below** the cutout if `cutout.maxY + 6 + h ≤ panel.maxY − 8`.
  2. Otherwise **above**, if `cutout.minY − 6 − h ≥ panel.minY + 8`.
  3. Otherwise the side with more room, clamped. With panel height 404 and a card under 80 pt this never happens, but the test covers it.

  The callout never intersects the cutout, which the test asserts for every anchor. The placement must be **stable across ticks**: it
  depends only on the target rect, which `StatCard`'s fixed column widths and placeholder heights keep constant.
- Approximate results with the current layout (the probe confirms): CPU, Memory and Network → below; Battery and Footer → above.
- The welcome card is centred on both axes, (404 − h) / 2 rounded to a pixel, at the same 304 width and 8 radius.

**Callout look.** The fill is `.regularMaterial`, with `Color(nsColor: .windowBackgroundColor)` at 0.92 when Reduce Transparency is on.
It has a 0.5 pt hairline (`Design.cardHairline`) and one soft shadow (`radius 12, y 4, black 0.18`). Text is `.primary` and `.secondary`;
nothing is faded with the Opacity setting, so text contrast doesn't depend on that setting (BetterScreenshot T1 lesson).
- Footer row, left to right: `1 of 5` (`.caption`, `.secondary`, `monospacedDigit`) · Spacer · **Skip Tour** (plain, secondary;
  hidden on the last step) · **Back** (`SubtleButtonStyle`; hidden on step 1) · **Next** / **Done** (`.borderedProminent`, small control size).

### B5. Interaction

**Hit testing.** The dim layer **takes all clicks** (`contentShape(Rectangle())`, no action), so nothing under the tour can be
clicked or hovered by accident. A drill-in, the Empty Trash `NSAlert` or Quit would each break the tour. Only the callout's buttons work.

**Keyboard.** The panel is key while it's open, because `MenuBarExtra` makes it key; `GlassTintHook` already listens for
`didBecomeKey` on it. Use `keyboardShortcut` on buttons, which needs no focus management:
- Return = Next / Done / Show Me Around (`.keyboardShortcut(.defaultAction)`)
- Esc = Skip Tour / No Thanks (`.keyboardShortcut(.cancelAction)`)
- → = Next and ← = Back, as two zero-size buttons (`.frame(width: 0, height: 0).opacity(0)`). Don't use `.hidden()`: a hidden
  button's shortcut doesn't fire. They carry `.keyboardShortcut(.rightArrow, modifiers: [])` and `.leftArrow`.
- **To verify by hand:** Esc in a `MenuBarExtra` window may close the panel. With a `.cancelAction` button in the view tree, SwiftUI
  should consume Esc first. If the panel still closes, the close rule (B7) treats it as a pause, which is harmless but wrong. Fall back to
  `.onExitCommand` on the overlay.

**Motion.**
- Between steps the cutout and callout move with `.snappy(duration: 0.3)`, the same curve as the screen push in `RootView`. The overlay
  fades in and out over 0.2 s.
- With `@Environment(\.accessibilityReduceMotion)` on, there is **no movement**: the step changes with a 0.15 s cross-fade, or instantly.
- Nothing loops or pulses.

**VoiceOver.**
- The overlay container has `.accessibilityAddTraits(.isModal)`. The callout is `.accessibilityElement(children: .contain)`.
- On each step, post `AccessibilityNotification.Announcement("\(title). \(body) Step \(n) of \(m).")` (macOS 14+), using the same format as BetterScreenshot's `TagStyle.announcement`.

### B6. When the tour shows, and who sees it

**Classification (once).** In `MacStatsApp.init()`, **before `let model = AppModel()`**, call `TourAudience.classifyIfNeeded()`.
`AppModel.init` writes `didRegisterLoginItem` through `LoginItem.registerOnce()`, and later battery keys, so classifying any later would
call everyone "existing". The user is `existing` if any of these is true:
- any key except `TourKey.all` is in `UserDefaults.standard.persistentDomain(forName: "com.macstats.MacStats")`. The owner's domain today
  holds `didRegisterLoginItem`, `NSStatusItem VisibleCC Item-0` and seven `battery*` keys, so he is `existing`.
- the bundle id isn't `com.macstats.MacStats`. A bare `swift build` binary has no bundle id, so it is existing and never shows the welcome.

Otherwise the user is `new`. The result is stored in `tourAudience` and never recomputed. The rules are pure (`TourAudience.classify(keys:bundleID:)`)
and tested; the read of the domain is a single line in the app.

**New users.** On the **first popover open** (in `RootView.onAppear`, through `TourController.panelOpened()`):
- If `TourRules.shouldShowWelcome(audience: .new, seenVersion:)` holds, show the welcome card. That needs `tourSeenVersion` absent and
  no answer given yet.
- MacStats never opens a window by itself. The welcome appears only because the user clicked the icon, which is the least intrusive moment possible.
- **No Thanks** sets `tourSeenVersion = TourCatalog.version`. **Show Me Around** starts step 1.
- The installer already prints "click the graph icon in your menu bar" (`install.sh` line 46), which covers how a new user finds the icon at all.

**Existing users, the owner included: offered once, quietly.** No welcome card and no dim. The overview header (`PanelHeader`, which
shows "MacStats" on the left with empty space on the right) shows a small trailing chip: **Take the Tour** plus a ✕ button, with
`SubtleButtonStyle` and continuous corners.
- It shows while `TourRules.shouldOfferTour(audience: .existing, seenVersion:, offerShows:, dismissed:)` holds, meaning this tour
  version hasn't been seen, it hasn't been dismissed, and `offerShows < 3`.
- `offerShows` goes up once per popover open on which the chip appeared. That is at most 3 tiny writes, ever.
- Clicking the chip starts the tour at step 1, skipping the welcome. ✕ sets `tourOfferDismissed = true`.
- After 3 opens it disappears by itself. This avoids banner blindness and nagging, and the chip never moves anything else in the layout.
- A later catalog `version` bump offers the chip again, the same way. It never forces a tour.

**Replay (everyone, any time):**
- A **`?` button in the overview footer**, left of the gear, in `SubtleButtonStyle`, with `.help("Take the Tour")` and the accessibility
  label "Take the Tour". It starts the tour at step 1.
- **Settings → HELP card → Take the Tour.** It pops back to the overview with `withAnimation(.snappy(duration: 0.3)) { showingSettings = false } completion: { tour.start() }`.
  `withAnimation(_:completion:)` needs macOS 14, which is the deployment target. Starting only after the push finishes means the cutout
  never slides along with the transition.
- A replay never changes `tourAudience`. Finishing or skipping it sets `tourSeenVersion`, which also removes the chip.

### B7. Pure state and persistence

```swift
// MacStatsCore/Tour.swift — sketch, no SwiftUI
public struct TourState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case off, welcome, step(Int) }   // Int = index into TourCatalog.steps
    public private(set) var phase: Phase = .off
    public mutating func showWelcome()
    public mutating func start(at: Int = 0, isPresent: (TourStepID) -> Bool) // first presentable step ≥ at
    public mutating func next(isPresent:) -> Effect      // .show / .finished
    public mutating func back(isPresent:) -> Effect      // previous presentable; no-op on the first
    public mutating func skip() -> Effect                // .finished (marks seen)
    public mutating func panelClosed() -> Effect         // .paused(step) the 1st time, .finished the 2nd
    public func progress(isPresent:) -> (number: Int, total: Int)?   // over presentable steps only
}
public enum TourRules { classify…, shouldShowWelcome…, shouldOfferTour… }
public enum TourKey { // the ONLY keys tours write
    static let audience = "tourAudience"            // "new" | "existing"
    static let seenVersion = "tourSeenVersion"      // Int: finished, skipped or No Thanks
    static let resumeStep = "tourResumeStep"        // Int: set while paused by a panel close
    static let interruptions = "tourInterruptions"  // Int: closes during this run (0/1)
    static let offerShows = "tourOfferShows"        // Int: existing-user chip appearances
    static let offerDismissed = "tourOfferDismissed"// Bool
    static let all: Set<String> = [...]
}
```

**Closing the panel mid-tour.** Clicking anywhere else closes a `MenuBarExtra` panel, so this will happen. The first close pauses and
stores `tourResumeStep`, and the next open resumes at that step. A *second* close in the same run counts as Skip, and the user can replay
with `?`. The same rule applies to the welcome card: the first close asks again on the next open, and the second close counts as No Thanks.
This follows the JVoice lesson ("an unanswered window would otherwise come back every login") without losing a new user's one accidental click-away.

A missing anchor (Battery on a desktop Mac) is skipped, and "n of m" counts only the steps that show, so a desktop Mac reads 1 of 4 … 4 of 4.

### B8. Cost when it isn't on screen (must be zero)
- **No timers**, no polling, no observers added for the tour. The overlay is `if tour.isActive { TourOverlay(...) }`, so when the tour
  is off no views exist and no layers are drawn.
- `TourController.panelOpened()` reads 3–4 `UserDefaults` keys once per open (microseconds). It writes only when the chip shows
  (at most 3 writes ever) or when the tour state changes.
- The anchor preferences are a 5-entry dictionary that is rebuilt only when the overview lays out. The overview already re-lays out on
  every 0.5 s tick while open, and **not at all while closed**, because `store.pausePublishing()` is in effect. That adds no work while
  closed and next to none while open.
  - Measure with the same method as the polish pass (`docs/superpowers/plans/2026-09-29-polish-perf-progress.md`): `top -pid` CPU and
    `footprint` before and after, popover closed and open, with the tour both on and off.
  - If the open-panel cost shows up at all, make `TourAnchorKey` emit only while `tour.isActive`, through an environment flag read by the
    modifier. That costs one identity change when a tour starts.
- `TourController` is separate from `MetricsStore` (B2), so step changes re-render only the overlay.

### B9. Why it's shaped this way (psychology, briefly)
- **Short tours get finished.** Product-tour benchmarks (Chameleon's yearly benchmark reports) show completion highest for about 3-step
  tours and falling steeply past about 5. The BetterScreenshot review came to the same conclusion (E2/R2). MacStats has 5 steps and drops Trash.
- **User-initiated tours do better than forced ones**, and people skip upfront tutorials. This is the "paradox of the active user"
  (Carroll & Rosson, 1987): people want to *use* the app, not learn it. NN/g's guidance is to prefer contextual help over long upfront
  tutorials. So the tour is opt-in (asked once), skippable at every point, and the breakdown tip is just-in-time (B3 optional).
- **Recognition over recall** (Nielsen's heuristic 6): the `?` stays visible in the footer, so nobody has to remember where the tour went.
- **Progress and an end in sight:** "n of m" and a short tour lower the felt effort (goal-gradient effect).
- **Peak-end rule:** the tour ends on something useful ("? replays this"), not on a wall of text.
- **Hick's law / cognitive load:** one idea per step, at most 20 words, one primary button.
- **Respect existing users:** an unrequested modal on an app they already know is pure cost. Hence the passive chip that dismisses itself.

---

## Part C — `MenuBarExtra` pitfalls (read before implementing)

1. **The panel closes when it loses focus.** That is why MacStats uses `NSAlert` for Empty Trash and Force Quit
   (`AppModel.confirmAndEmptyTrash`, `ProcessActions.confirmForceQuit`). The tour must therefore use **no** sheets, popovers, `.alert`,
   `.confirmationDialog`, `NSAlert`, separate windows or `NSApp.activate`. Everything stays inside `RootView`'s ZStack.
2. **Views stay alive after close.** `MenuBarExtra` keeps the closed popover's view tree (see the comment in `AppModel.setVisibility`).
   Pause in `RootView.onDisappear`, which already resets `showingSettings` there, and make sure no animation or state change runs while closed.
3. **`.onAppear` and `.onDisappear` are the open and close signals.** `RootView` already calls `model.setVisibility(...)` from them. Hook
   `tour.panelOpened()` and `tour.panelClosed()` next to those calls, and don't add new observers.
4. **Fixed 320 × 404, `.clipped()`.** The overlay goes **inside** the clipped frame, so it gets the panel's squircle for free (`PanelShape`
   rounds and masks the window's root layer to 16 pt continuous). It must not change the frame size.
5. **Screen transitions.** The overview moves with `.offset(x: -96)` and an opacity change when you drill in. Show the overlay only while
   the overview is the current screen and the transition has finished (B6, Settings path). The welcome card and the chip appear only on the overview.
6. **Hover under the overlay.** `CardButtonStyle` and `SubtleButtonStyle` use `.onHover`. Check in the probe that the dim's
   `contentShape` stops hover highlights underneath, so a card doesn't light up under the dim.
7. **Opacity setting.** At Opacity 0 the glass is thinned, so the dim and the callout must stay legible. The callout uses its own material
   and never reads `uiOpacity`. Check Opacity 0, 0.5 and 1 in light and dark.
8. **Esc** may be bound to closing the panel. See B5.
9. **Prewarm and the 0.5 s tick** keep changing card values under the tour. That's fine as long as no copy quotes a number and the
   cutout depends only on the layout rect, which is fixed. If the `StatCard` value column ever stops being fixed width, the cutout would
   jitter. Keep `valueColumnWidth` fixed.
10. **Never test against the real defaults domain.** `TourController` takes a `UserDefaults` (default `.standard`). Tests and probes pass
    `UserDefaults(suiteName: "MacStatsTourProbe-<uuid>")` and delete it afterwards. To see the new-user flow on the owner's Mac, use the
    probe; never wipe `com.macstats.MacStats`.

---

## Part D — Tests and verification

**Unit tests** (Swift Testing, in `Tests/MacStatsCoreTests/`, run with `./Scripts/test.sh`):
- `TourStateTests`:
  - The full path: welcome → Show Me Around → steps 0…4 → Done means seen.
  - Back at step 0 does nothing. Back skips a missing Battery step.
  - Skip from any step means seen. No Thanks means seen.
  - `panelClosed` pauses the first time and resumes at the same step. The second close means seen.
  - Closing on the welcome card the first time asks again; the second close counts as No Thanks.
  - "n of m" with and without a battery: 1 of 5 … 5 of 5, and 1 of 4 … 4 of 4. There are no skipped numbers.
- `TourRulesTests`:
  - classify: an empty domain is new; only tour keys is new; `didRegisterLoginItem` is existing; `NSStatusItem VisibleCC Item-0` is
    existing; any `battery*` key is existing; a nil or other bundle id is existing.
  - `shouldShowWelcome` is true only for new users who haven't seen it.
  - `shouldOfferTour`: existing, unseen, fewer than 3 shows and not dismissed → true. A version bump re-offers. Dismissed → never.
- `TourLayoutTests`:
  - The cutout's four margins are equal for fractional inputs at scale 1, 2 and 3, to within 1/scale.
  - Every edge sits on the pixel grid.
  - radius = target radius + 3, and (radius + gap to panel edge) = 16 for full-width cards.
  - The cutout stays inside the panel.
  - For each real anchor rect (fixtures measured by the probe), the callout: lies inside the panel minus 8, never intersects the cutout,
    is 6 pt from it, goes below for CPU/Memory/Network and above for Battery/Footer, and has a fallback when neither side fits.
- `TourCatalogLintTests`:
  - Title ≤ 4 words; body ≤ 20 words in 1–2 sentences; no straight `'`.
  - Step ids are unique and match `TourStepID`. Buttons are Title Case.
  - Copy doesn't contain digits followed by "%" or "GB", so no live numbers.

**Off-screen probe** (follow `docs/reviews/2026-10-05-readings-accuracy/*/main.swift` and `~/.claude/skills/reviewer/references/capture.md`):
- **Setup:** a SwiftPM executable that compiles the real `MacStatsApp` views with a `MetricsStore` filled with fixed values. Host
  `RootView` in an `NSWindow` of 320 × 404 at `CGWindowLevelForKey(.desktopWindow) + 1`, call `orderBack(nil)`, and never activate.
- **Capture:** force each phase (welcome, steps 1–5, chip) and capture with
  `CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution])`. Do this in light and dark, at
  Opacity 0, 0.5 and 1, with and without a battery, and with Reduce Motion on.
- **Measure:** on each step capture, scan the row through the target's vertical centre and the column through its horizontal centre.
  Find the ring's outer edges and check that **left gap = right gap and top gap = bottom gap to within one device pixel**. This is the
  "perfectly centred" proof. Also print the callout and cutout rects, which become the `TourLayoutTests` fixtures.
- **Fit:** measure each body's line count in the callout's real font at 280 pt, using the BetterScreenshot `TagFitTests` approach.
- **Run** with a kill timeout: `(./probe & PID=$!; (sleep 120; kill $PID) & wait $PID)`. Then close the windows and delete the suite domain.

**Performance:** follow the B8 measurement. Take `top`, CPU and `footprint` with the popover closed (before and after) and open with
the tour off; the numbers must match within noise.

---

## Part E — Implementation order (each item is one small commit)
1. `MacStatsCore/Tour.swift` and `TourLayout.swift`, with their four test files (pure, test-first).
2. Audience classification in `MacStatsApp.init()` before `AppModel()`, plus `TourController` (taking a `UserDefaults`).
3. `.tourAnchor` on the 4 stat cards and the footer group in `OverviewView`, then `TourOverlay` (dim, cutout, ring, callout) in `RootView`.
4. The welcome card, the existing-user chip, the `?` button and the Settings Help card.
5. Keyboard, Reduce Motion and VoiceOver.
6. Probe captures, the centring measurement and the fit check. Turn the measured rects into test fixtures.
7. A perf check against B8, then the docs: the `CLAUDE.md` Status line and the progress note
   `docs/superpowers/plans/2026-10-06-stability-tour-progress.md`.
8. Optional: the first drill-in hint (B3), after the breakdown row-jumping fix lands.

## Open questions for the owner (defaults chosen; change if he disagrees)
- Ring colour: system **accent** (a native focus ring, the default here) or monochrome (as in JVoice)? BetterScreenshot's red would clash with the red memory-pressure dot.
- Existing-user chip: shown on up to **3** opens (the default here), or exactly 1?
- Include Trash as a 6th step? It is left out by default, for brevity.
