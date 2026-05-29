# MacStats — Spotlight searchability + menu-bar glyph

**Date:** 2026-05-29
**Status:** Design — awaiting user review
**Scope:** Two small, independent changes. No rename (app stays `MacStats`).

## Goals

1. Make the app findable by typing **"MacStats"** in Spotlight.
2. Replace the static menu-bar SF Symbol with a custom **Sparkline** glyph (Concept 1
   from `docs/mockups/menubar-glyph-concepts.html`).

---

## Task 1 — Spotlight searchability

### Problem
The bundle is already named `MacStats` (`CFBundleName`/`CFBundleDisplayName`), so the name
is correct. It doesn't appear in Spotlight only because `Scripts/bundle.sh` leaves
`MacStats.app` inside the code folder, which Spotlight does not index as an installed app.

### Approach
Add `Scripts/install.sh` that:
1. Builds + bundles via the existing `bundle.sh` (release config).
2. Copies `MacStats.app` into `~/Applications` (created if missing — no admin password,
   no `/Applications` write needed).
3. Registers it with Launch Services (`lsregister -f`) and runs `mdimport` so Spotlight
   indexes it immediately rather than waiting for the next scan.

`~/Applications` is chosen over `/Applications` to avoid requiring sudo; both are
Spotlight-indexed application locations.

### Verification
After running `install.sh`, confirm indexing without manual Spotlight clicks:
```
mdfind "kMDItemContentType == 'com.apple.application-bundle' && kMDItemFSName == 'MacStats.app'"
```
Expect the `~/Applications/MacStats.app` path in the output. Final "type MacStats in
Spotlight and see it" is a human acceptance step.

---

## Task 2 — Menu-bar glyph (Sparkline)

### Chosen design
The Sparkline: a single rounded-stroke graph line with a dot at the leading peak,
matching the approved mockup. Geometry (24×24 viewBox, stroke ≈2.2, round caps/joins):
polyline `(2,16) (6,11) (10,14) (14,6) (18,10) (22,5)` + filled dot at `(22,5)`.

### Rendering approach
Draw the glyph **programmatically as a template `NSImage`** (via `NSImage(size:flipped:)`
with an `NSBezierPath`), `isTemplate = true`, and render it with `Image(nsImage:)` in
`MenuBarLabel`. Rationale:
- No asset catalog / `.icns` / resource bundling — fits the **Command-Line-Tools-only +
  SPM** constraint and the "native Swift only" decision (see CLAUDE.md).
- Template + vector drawing → auto-adapts to light/dark menu bars and stays crisp on
  retina at any size, exactly like the SF Symbol it replaces.

### Files touched
- `Sources/MacStatsApp/MenuBarLabel.swift` — replace `Image(systemName: …)` with the
  drawn template image. The view stays a tiny, single-purpose struct (no behavior change:
  still a static icon; data is still only collected while the popover is open).

### Verification
- `swift build` green; `./Scripts/test.sh` still passes (no logic change, so existing
  21 tests should be unaffected).
- `./Scripts/bundle.sh` produces the app; launch and confirm the sparkline shows in the
  menu bar and renders in both light and dark menu bars (human acceptance step).

---

## Out of scope
- No app rename, no bundle-ID change.
- No full-color app icon / `.icns` (user chose the menu-bar glyph only).
- No live values in the menu bar (item stays static by design).
```
