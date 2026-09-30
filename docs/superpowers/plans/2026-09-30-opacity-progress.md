# Opacity setting — progress (2026-09-30)

Branch `feat/opacity-setting`, git worktree
`/Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats/.claude/worktrees/opacity`
(based on `feat/polish-perf`). Spec: `docs/design-language/opacity-setting.md` §2 (same setting in
MacStats, JVoice and BetterScreenshot).

## Status: DONE (committed on `feat/opacity-setting`; not merged)

- [x] Investigated `MenuBarExtraWindow` (findings below)
- [x] Pure mapping `Sources/MacStatsCore/UIOpacity.swift` + `Tests/MacStatsCoreTests/UIOpacityTests.swift`
- [x] `Sources/MacStatsApp/Appearance.swift` (backdrop + glass tint), `SettingsView.swift` (Settings screen,
      Appearance card, footer gear button); small edits to `RootView.swift`, `OverviewView.swift`, `StatCard.swift`
- [x] `swift build` clean, `./Scripts/test.sh` 95/95 pass
- [x] Screenshots at 0 / 0.5 / 1, dark + light (outside the repo, in the session scratchpad)
- [x] Machine restored: system appearance Dark, `uiOpacity` unset (= default 0.5), clean build installed

## What the user sees

Overview footer → gear button (bottom-right; Quit stays bottom-left) → pushes a **Settings** screen
(same 320×404 panel, header with "‹ Settings" back button, same push transition as the per-app breakdown) →
**APPEARANCE** card → **Opacity** row: bordered small **Default** button (disabled at the default), a continuous
`Slider` labelled "Transparent" … "Opaque", one line of help text. Changes apply live to the popover itself and
persist as `uiOpacity` (Double, 0…1, default 0.5) in the standard defaults domain `com.macstats.MacStats`.
The Settings screen resets to the overview when the popover closes.

## Findings: what controls the popover background (macOS 26.6)

Method: a temporary debug hook (removed before commit) dumped the window's view + layer tree when the popover
became key, and captured the popover region with `CGWindowListCreateImage` from inside the app (Terminal has no
Screen Recording permission, so `screencapture` fails; an app may capture its own windows plus the wallpaper).

- The window is `SwiftUI.MenuBarExtraWindow` (an `NSPanel`), non-opaque, clear `backgroundColor`, alpha 1.
- The background is **SwiftUI's own Liquid Glass**, drawn inside our layer tree: a `CABackdropLayer` with a
  `glassBackground` `CAFilter`, an `SDFPortalLayer`, and `CASDFLayer`s; text layers carry a `vibrantColorMatrix`
  filter. (The 2026-09-29 note "drawn by the window server, no backdrop layer" was about the view tree only; the
  backdrop layer is there, and the window server composites it.)
- `containerBackground(_:for: .window)` is **ignored** by `MenuBarExtra` (tested with `.clear` and custom glass,
  applied live and at launch) — so the glass cannot be replaced with public API.
- Fading the backdrop layer (`opacity` 0.5) or the window shows the page behind **unblurred**, i.e. sharp text
  under our text — unreadable. Rejected (as is whole-window `alphaValue`, which fades the text too).
- The `glassBackground` filter's inputs are writable via KVC (`filters.glassBackground.<key>`). System values
  (dark mode): `inputBlurRadius` 4, `inputFaceColorMatrixFillColor` black @ 0.4, `inputFaceColorMatrixWhite` 0.6,
  `inputFaceColorMatrixBlack` 0.2. Lowering the **fill colour's alpha** lightens the tint while keeping the blur —
  the chosen see-through mechanism. Changing white/black/blur made text over a white page illegible — rejected.
- The panel window is reused between opens and the system rebuilds the glass on each show and on appearance
  changes, so `Appearance.swift` re-applies on window occlusion change / become-key and on appearance change.

## Mapping (`UIOpacity`)

| value | solid window-background layer alpha | glass fill-alpha multiplier | card fill |
|---|---|---|---|
| 0.0 | 0 | 0.25 (clamp) | 0.04 |
| 0.5 (default) | 0 (nothing drawn) | 1 (glass untouched) | 0.05 |
| 1.0 | 1 (fully solid) | 1 | 0.05 |

Piecewise-linear in between. Reduce Transparency on → the glass multiplier is forced to 1 (system value).

## Contrast measurements (primary text vs. median background behind it, from captures)

- Dark mode over a white page: 0.5 → ~7.0:1; 0.0 → ~4.1:1 (floor is 3:1 at 0.0) — clamp 0.25 leaves margin.
- Light mode over a dark wallpaper: 0.5 → ~10.9:1; 0.0 → ~7:1.

## Known limits / not verified

- The transparent side depends on SwiftUI's private glass internals. If a future macOS renames the layer/filter
  key, the code finds nothing and the popover simply stays at the default look (fails safe).
- Because the tint is re-applied one run-loop turn after the panel shows, a single frame at the default tint on
  open is possible at values < 0.5 (not observed in captures, not verified frame-by-frame).
- Push animation to/from Settings not recorded (only static states verified).
