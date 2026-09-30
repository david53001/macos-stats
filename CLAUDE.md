# MacStats

A lightweight **macOS menu-bar system monitor** (native Swift). Lives next to the
battery/clock. Click the menu-bar item → overview popover with one card per stat +
live sparkline; click a card → per-app breakdown with quick actions (Quit / Force Quit).

## Status (as of 2026-09-30)

- ✅ Design **approved**, visual mockups **approved**.
- ✅ **Milestone 1 BUILT** — runnable menu-bar app: live CPU %, Memory, Network, Battery + sparklines + adaptive refresh (1s open; now 0.5s, see polish pass). `swift build` green; `./Scripts/bundle.sh` produces a Dock-iconless `MacStats.app`.
- ✅ **Per-app breakdown BUILT** (Milestone 3 core) — clicking the **CPU** or **Memory** card opens an in-popover drill-in: processes grouped by app (one row per app, summed across its processes), ranked high→low, top ~8 with scroll; right-click a row → **Quit** (graceful) or **Force Quit** (confirms first). CPU shows a brief "Measuring…" state (needs two samples); Memory is instant. User-apps-only; the per-process scan runs **only** while a breakdown is open. Verified on-device.
- ✅ **CPU temperature, threshold alerts & Empty Trash BUILT (2026-05-30)** — (1) **CPU temp** in the CPU card via the private IOKit `IOHIDEventSystemClient` thermal API (isolated in a `CAppleSensors` C shim). On Apple Silicon there's no per-core CPU sensor; on this M3 we average the `PMU tdie*` **silicon die** sensors (~46°C idle). Degrades gracefully to "live" if no usable sensor (so it's safe on other chips). (2) **Threshold alerts** — notifications for sustained high CPU (>85% for ≥30s) and real kernel **memory pressure** (warning/critical), with a recover-then-cooldown anti-spam state machine (`AlertMonitor`). A lightweight background sampler (system CPU% + pressure only, **every 10s**) runs while the popover is closed so alerts fire when you're not looking. Notifications require the **bundled** `MacStats.app`. (3) **Empty Trash** — Trash-size readout + an Empty action that scripts Finder (one-time Automation permission prompt). Memory pressure now comes from the **real kernel level** (`kern.memorystatus_vm_pressure_level`), not a used-fraction heuristic.
- ✅ **Empty Trash dialog fix (2026-05-30)** — the confirm/error dialogs were SwiftUI `.confirmationDialog`/`.alert` presented from inside the `MenuBarExtra(.window)` panel; that panel is a transient non-activating `NSPanel` that auto-dismisses on focus loss, so interacting with either dialog button (Empty **or** Cancel) closed the whole popover before the action could run. Now driven through AppKit **`NSAlert`** (`AppModel.confirmAndEmptyTrash` / `presentTrashError`), which runs its own modal window independent of the menu panel. Removed the now-unused `MetricsStore.trashMessage`. (Force Quit moved to `NSAlert` too in the 2026-09-29 polish pass.)
- ✅ **Launch at login BUILT (2026-05-30)** — `LoginItem.registerOnce()` (called from `AppModel.init()`) enrolls the app via `SMAppService.mainApp` **once**, gated by a `didRegisterLoginItem` UserDefaults flag set only on success. So the first launch enables it; if the user later removes MacStats from System Settings → General → Login Items, it stays removed (we never re-add). No Settings UI by design. Needs the **bundled, signed** app (the API keys off the bundle); the bare `swift build` binary fails harmlessly. Failures are logged, never fatal.
- ✅ **Single-copy install (2026-06-04)** — `bundle.sh` now assembles **directly into `~/Applications/MacStats.app`** (quitting any running copy first) instead of leaving a second `MacStats.app` in the repo root. The old two-copy design (bundle in repo, `install.sh` copies it over) let the installed copy go stale — it predated launch-at-login, so the app never registered at startup and Spotlight showed two MacStats apps. `install.sh` is now a thin wrapper: release build + Launch Services/Spotlight registration. Stale copies removed; launch-at-login registration verified (`didRegisterLoginItem` set after first launch of the new build).
- ✅ **Polish + performance pass (2026-09-29, branch `feat/polish-perf`)** — details in `docs/superpowers/plans/2026-09-29-polish-perf-progress.md`. (1) **Instant open**: history persists across closes; the 10s idle sampler also records CPU/memory/network history; the first open tick runs synchronously against the idle baseline; battery + temp are read at launch and on hover — every value is real on frame one. (2) **Graphs without Swift Charts**: custom `Sparkline` (gradient area + 1.6pt line, no dot, per user), fixed 60s time axis, monotone curve (`SparklineGeometry.swift`), nice-rounded network scale, slow linear slide each 0.5s sample. (3) **0.5s cadence** while open (1s trailing rate average); temp every 2s via cached `CPUTemperatureReader`; battery every 10s. Number changes use a soft `.interpolate` fade (user found rolling digits too busy). (4) **Squircle UI**: continuous-corner inset cards (concentric radii, `Design.swift`), hover/press feedback, battery gauge, fixed 320×404 size for overview + breakdown with a push transition. (5) **Hover pre-warm**: `StatusItemHover` attaches a tracking area to MenuBarExtra's `NSStatusBarButton` and calls `AppModel.prewarm()`. (6) **RAM**: cached downsampled app icons, `malloc_zone_pressure_relief` 1.5s after close, timer tolerance — footprint 46→40 MB, peak 121→41 MB. Force Quit now confirms via `NSAlert` (`ProcessActions.confirmForceQuit`). Breakdown ties sort by pid (stable). **Kept `MenuBarExtra`**: its blur is drawn by the window server for the private `MenuBarExtraWindow`, and its position/instant appearance already match Apple's own Battery panel.
- ✅ **Opacity setting (2026-09-30, branch `feat/opacity-setting`)** — footer gear → in-popover **Settings** screen (`SettingsView.swift`) → Appearance → **Opacity** slider (Transparent…Opaque, **Default** = 0.5 = the unchanged look), stored as `uiOpacity` in the standard defaults, applied live; shared spec `docs/design-language/opacity-setting.md` §2. Mapping (pure, tested): `Sources/MacStatsCore/UIOpacity.swift`; surfaces: `Sources/MacStatsApp/Appearance.swift`. Toward 1 a window-background layer fades in behind the cards (solid at 1); toward 0 the panel's glass tint is thinned (clamped at 25 % for ≥ 3:1 text contrast) and card fill goes 0.05 → 0.04. Finding: on macOS 26 the popover background is SwiftUI Liquid Glass (a `CABackdropLayer` with a `glassBackground` filter in our own layer tree), not replaceable publicly (`containerBackground(for: .window)` is ignored), so the transparent side adjusts that filter's fill alpha — private, fails safe to the default look. Notes: `docs/superpowers/plans/2026-09-30-opacity-progress.md`.
- ✅ **Battery status + estimate + drill-in (2026-09-30, branch `feat/battery-status`)** — charging / fully charged / not charging states, time to full, and a **smoothed time-left** that replaces macOS's jumpy one-minute figure: whole-Mac power from the `AppleSmartBattery` gauge telemetry, blended from this session's 10-min average and a persisted 3-h "typical use" average (`BatteryEstimator`). Battery card now drills into a Battery screen: details (status, time, power now/avg, adapter, health, cycles, temperature) + apps ranked by CPU power (`ri_energy_nj`). Plug/unplug is picked up instantly (IOPS notification). Notes: `docs/superpowers/plans/2026-09-30-battery-progress.md`.
- ✅ **Public release (2026-09-30)** — repo `david53001/macos-stats` made **public**, license **PolyForm Strict 1.0.0** (`LICENSE`: view and use only; no redistribution, changes or selling — same license now used by JVoice and BetterScreenshot). README rewritten short and emoji-free with install/update at the top. **Install/update one-liner** (root `install.sh`): `curl -fsSL https://raw.githubusercontent.com/david53001/macos-stats/main/install.sh | bash` downloads `MacStats.app.zip` from the latest GitHub release into `~/Applications`, clears quarantine and launches. Releases are built with `./Scripts/package-release.sh` (→ `dist/MacStats.app.zip`, ad-hoc signed, arm64) and published with `gh release create`. First release: **v1.0.0**. Ad-hoc signing means macOS may re-ask for Finder (Automation) permission after an update.
- ✅ **114 tests pass** via `./Scripts/test.sh`.
- ⬜ **Milestone 4** remainder (Settings UI, customizable menu-bar display, adjustable alert thresholds) not started. Per-app **Network** breakdown remains deferred (no clean per-app network API).

## Start here

| What | Where |
|------|-------|
| Overall design spec | `docs/superpowers/specs/2026-05-29-macstats-menubar-design.md` |
| Per-app breakdown spec | `docs/superpowers/specs/2026-05-29-macstats-per-app-breakdown-design.md` |
| Per-app breakdown plan | `docs/superpowers/plans/2026-05-29-macstats-per-app-breakdown.md` |
| Design language (reusable in other apps) + JVoice / BetterScreenshot redesign specs | `docs/design-language/` |
| Approved UI mockups | `docs/mockups/menubar-mockup.html`, `docs/mockups/per-app-breakdown-mockup.html` (open in a browser) |

## To resume building

Milestones 1–3 (incl. battery status, health and watts), CPU temperature, threshold alerts, Empty
Trash and the Opacity setting are built (see Status). Remaining unbuilt work: the rest of the
**Settings UI** — customizable menu-bar display + adjustable alert thresholds (Milestone 4). Write a plan with **superpowers:writing-plans**, then execute
it with **superpowers:subagent-driven-development**. To run the current app:
`./Scripts/bundle.sh && open ~/Applications/MacStats.app`.

## Locked technical decisions

- **Native Swift only**: SwiftUI `MenuBarExtra` + IOKit/Mach/`getifaddrs`. Graphs are a custom SwiftUI
  `Shape` (Swift Charts was dropped 2026-09-29 with the user's OK: lighter, smoother animation) and must
  keep looking Apple-native (gradient area under a thin line, no end dot).
- **Build with Swift Package Manager**, NOT Xcode. This machine has **Command Line Tools only**
  (no `xcodebuild`); SwiftUI + Charts + MenuBarExtra were verified to compile under it.
  Toolchain: Swift 6.2, language mode v5, target macOS 14+.
- **Not sandboxed** (full sensor access). Distributed via GitHub releases + `install.sh` (not notarized; the installer clears quarantine). NOT Mac App Store.
- **Adaptive refresh**: while the popover is closed, only a lightweight alert sampler runs
  (~10s: CPU% + memory + network, feeding alerts and the graph history; no per-app scan); 0.5s full
  collection only while the popover is open; per-process scan only when drilled into a card.

## Scope

- **Milestone 1 (planned):** runnable menu-bar app — live CPU %, Memory, Network, Battery + sparklines + adaptive refresh.
- **Milestone 2:** CPU temp (IOKit `IOHIDEventSystemClient` — semi-private, sensor keys vary by chip; isolate it), battery health/watts.
- **Milestone 3:** per-app breakdown + drill-in + quick actions (Quit / Force Quit). ✅ **Built for CPU + Memory** (Network/Battery per-app deferred to v2+).
- **Milestone 4:** Settings, customizable menu-bar display, alerts; real memory-pressure source.
- **Deferred (v2+):** per-app network (no clean public API), Disk, GPU/fans/raw sensors, multiple menu-bar items, persisted history.

## Build & test commands

```bash
swift build          # compile
./Scripts/test.sh    # run the unit + smoke tests (Swift Testing; see note)
./Scripts/bundle.sh  # build + install ~/Applications/MacStats.app, then: open ~/Applications/MacStats.app
./Scripts/install.sh # same, but release build + Launch Services/Spotlight registration
./Scripts/package-release.sh  # release build → dist/MacStats.app.zip (the GitHub release asset)
```

**Publishing an update:** bump `CFBundleShortVersionString` in `Resources/Info.plist`, run
`./Scripts/package-release.sh`, push to `main`, then
`gh release create vX.Y.Z dist/MacStats.app.zip --title "MacStats X.Y.Z" --notes "..."`.
Users update by re-running the curl one-liner (it always fetches `releases/latest`).

> **Tests use Swift Testing, not XCTest.** This machine has Command Line Tools only
> (no full Xcode), so XCTest is unavailable. Tests use `import Testing` / `@Test` /
> `#expect`; `Scripts/test.sh` wraps `swift test` with the CLT framework search path.
> Do not use `swift test` directly (it can't find the test framework).
