# MacStats

A lightweight **macOS menu-bar system monitor** (native Swift). Lives next to the
battery/clock. Click the menu-bar item → overview popover with one card per stat +
live sparkline; click a card → per-app breakdown with quick actions (Quit / Force Quit).

## Status (as of 2026-05-30)

- ✅ Design **approved**, visual mockups **approved**.
- ✅ **Milestone 1 BUILT** — runnable menu-bar app: live CPU %, Memory, Network, Battery + sparklines + adaptive refresh (1s open; now 0.5s, see polish pass). `swift build` green; `./Scripts/bundle.sh` produces a Dock-iconless `MacStats.app`.
- ✅ **Per-app breakdown BUILT** (Milestone 3 core) — clicking the **CPU** or **Memory** card opens an in-popover drill-in: processes grouped by app (one row per app, summed across its processes), ranked high→low, top ~8 with scroll; right-click a row → **Quit** (graceful) or **Force Quit** (confirms first). CPU shows a brief "Measuring…" state (needs two samples); Memory is instant. User-apps-only; the per-process scan runs **only** while a breakdown is open. Verified on-device.
- ✅ **CPU temperature, threshold alerts & Empty Trash BUILT (2026-05-30)** — (1) **CPU temp** in the CPU card via the private IOKit `IOHIDEventSystemClient` thermal API (isolated in a `CAppleSensors` C shim). On Apple Silicon there's no per-core CPU sensor; on this M3 we average the `PMU tdie*` **silicon die** sensors (~46°C idle). Degrades gracefully to "live" if no usable sensor (so it's safe on other chips). (2) **Threshold alerts** — notifications for sustained high CPU (>85% for ≥30s) and real kernel **memory pressure** (warning/critical), with a recover-then-cooldown anti-spam state machine (`AlertMonitor`). A lightweight background sampler (system CPU% + pressure only, **every 10s**) runs while the popover is closed so alerts fire when you're not looking. Notifications require the **bundled** `MacStats.app`. (3) **Empty Trash** — Trash-size readout + an Empty action that scripts Finder (one-time Automation permission prompt). Memory pressure now comes from the **real kernel level** (`kern.memorystatus_vm_pressure_level`), not a used-fraction heuristic.
- ✅ **Empty Trash dialog fix (2026-05-30)** — the confirm/error dialogs were SwiftUI `.confirmationDialog`/`.alert` presented from inside the `MenuBarExtra(.window)` panel; that panel is a transient non-activating `NSPanel` that auto-dismisses on focus loss, so interacting with either dialog button (Empty **or** Cancel) closed the whole popover before the action could run. Now driven through AppKit **`NSAlert`** (`AppModel.confirmAndEmptyTrash` / `presentTrashError`), which runs its own modal window independent of the menu panel. Removed the now-unused `MetricsStore.trashMessage`. (SwiftUI `.alert` in `BreakdownView` for Force Quit is left as-is — it behaves acceptably; `.confirmationDialog` was the broken one.)
- ✅ **Launch at login BUILT (2026-05-30)** — `LoginItem.registerOnce()` (called from `AppModel.init()`) enrolls the app via `SMAppService.mainApp` **once**, gated by a `didRegisterLoginItem` UserDefaults flag set only on success. So the first launch enables it; if the user later removes MacStats from System Settings → General → Login Items, it stays removed (we never re-add). No Settings UI by design. Needs the **bundled, signed** app (the API keys off the bundle); the bare `swift build` binary fails harmlessly. Failures are logged, never fatal.
- ✅ **Single-copy install (2026-06-04)** — `bundle.sh` now assembles **directly into `~/Applications/MacStats.app`** (quitting any running copy first) instead of leaving a second `MacStats.app` in the repo root. The old two-copy design (bundle in repo, `install.sh` copies it over) let the installed copy go stale — it predated launch-at-login, so the app never registered at startup and Spotlight showed two MacStats apps. `install.sh` is now a thin wrapper: release build + Launch Services/Spotlight registration. Stale copies removed; launch-at-login registration verified (`didRegisterLoginItem` set after first launch of the new build).
- ✅ **Polish + performance pass (2026-09-29, branch `feat/polish-perf`)** — details in `docs/superpowers/plans/2026-09-29-polish-perf-progress.md`. (1) **Instant open**: history persists across closes; the 10s idle sampler also records CPU/memory/network history; the first open tick runs synchronously against the idle baseline; battery + temp are read at launch and on hover — every value is real on frame one. (2) **Graphs without Swift Charts**: custom `Sparkline` (gradient area + 1.6pt line, no dot, per user), fixed 60s time axis, monotone curve (`SparklineGeometry.swift`), nice-rounded network scale, slow linear slide each 0.5s sample. (3) **0.5s cadence** while open (1s trailing rate average); temp every 2s via cached `CPUTemperatureReader`; battery every 10s. Number changes use a soft `.interpolate` fade (user found rolling digits too busy). (4) **Squircle UI**: continuous-corner inset cards (concentric radii, `Design.swift`), hover/press feedback, battery gauge, fixed 320×404 size for overview + breakdown with a push transition. (5) **Hover pre-warm**: `StatusItemHover` attaches a tracking area to MenuBarExtra's `NSStatusBarButton` and calls `AppModel.prewarm()`. (6) **RAM**: cached downsampled app icons, `malloc_zone_pressure_relief` 1.5s after close, timer tolerance — footprint 46→40 MB, peak 121→41 MB. Force Quit now confirms via `NSAlert` (`ProcessActions.confirmForceQuit`). Breakdown ties sort by pid (stable). **Kept `MenuBarExtra`**: its blur is drawn by the window server for the private `MenuBarExtraWindow`, and its position/instant appearance already match Apple's own Battery panel.
- ✅ **89 tests pass** via `./Scripts/test.sh`.
- ⬜ **Milestone 2** remainder (battery health/watts) and **Milestone 4** remainder (Settings UI, customizable menu-bar display, adjustable alert thresholds) not started. Per-app **Network/Battery** breakdowns remain deferred (no clean per-app network API; energy impact only approximate).

## Start here

| What | Where |
|------|-------|
| Overall design spec | `docs/superpowers/specs/2026-05-29-macstats-menubar-design.md` |
| Per-app breakdown spec | `docs/superpowers/specs/2026-05-29-macstats-per-app-breakdown-design.md` |
| Per-app breakdown plan | `docs/superpowers/plans/2026-05-29-macstats-per-app-breakdown.md` |
| Approved UI mockups | `docs/mockups/menubar-mockup.html`, `docs/mockups/per-app-breakdown-mockup.html` (open in a browser) |

## To resume building

Milestone 1, the per-app breakdown (Milestone 3 core), CPU temperature, threshold alerts, and
Empty Trash are built (see Status). Remaining unbuilt work: **battery health / live watts**
(rest of Milestone 2) and a **Settings UI** for customizable menu-bar display + adjustable alert
thresholds (rest of Milestone 4). Write a plan with **superpowers:writing-plans**, then execute
it with **superpowers:subagent-driven-development**. To run the current app:
`./Scripts/bundle.sh && open ~/Applications/MacStats.app`.

## Locked technical decisions

- **Native Swift only**: SwiftUI `MenuBarExtra` + IOKit/Mach/`getifaddrs`. Graphs are a custom SwiftUI
  `Shape` (Swift Charts was dropped 2026-09-29 with the user's OK: lighter, smoother animation) and must
  keep looking Apple-native (gradient area under a thin line, no end dot).
- **Build with Swift Package Manager**, NOT Xcode. This machine has **Command Line Tools only**
  (no `xcodebuild`); SwiftUI + Charts + MenuBarExtra were verified to compile under it.
  Toolchain: Swift 6.2, language mode v5, target macOS 14+.
- **Not sandboxed** (full sensor access); notarize later if sharing. NOT Mac App Store.
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
```

> **Tests use Swift Testing, not XCTest.** This machine has Command Line Tools only
> (no full Xcode), so XCTest is unavailable. Tests use `import Testing` / `@Test` /
> `#expect`; `Scripts/test.sh` wraps `swift test` with the CLT framework search path.
> Do not use `swift test` directly (it can't find the test framework).
