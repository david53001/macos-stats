# MacStats

A lightweight **macOS menu-bar system monitor** (native Swift). Lives next to the
battery/clock. Click the menu-bar item → overview popover with one card per stat +
live sparkline; click a card → per-app breakdown with quick actions (Quit / Force Quit).

## Status (as of 2026-05-30)

- ✅ Design **approved**, visual mockups **approved**.
- ✅ **Milestone 1 BUILT** — runnable menu-bar app: live CPU %, Memory, Network, Battery + Swift Charts sparklines + adaptive refresh (1s open). `swift build` green; `./Scripts/bundle.sh` produces a Dock-iconless `MacStats.app`.
- ✅ **Per-app breakdown BUILT** (Milestone 3 core) — clicking the **CPU** or **Memory** card opens an in-popover drill-in: processes grouped by app (one row per app, summed across its processes), ranked high→low, top ~8 with scroll; right-click a row → **Quit** (graceful) or **Force Quit** (confirms first). CPU shows a brief "Measuring…" state (needs two samples); Memory is instant. User-apps-only; the per-process scan runs **only** while a breakdown is open. Verified on-device.
- ✅ **CPU temperature, threshold alerts & Empty Trash BUILT (2026-05-30)** — (1) **CPU temp** in the CPU card via the private IOKit `IOHIDEventSystemClient` thermal API (isolated in a `CAppleSensors` C shim). On Apple Silicon there's no per-core CPU sensor; on this M3 we average the `PMU tdie*` **silicon die** sensors (~46°C idle). Degrades gracefully to "live" if no usable sensor (so it's safe on other chips). (2) **Threshold alerts** — notifications for sustained high CPU (>85% for ≥30s) and real kernel **memory pressure** (warning/critical), with a recover-then-cooldown anti-spam state machine (`AlertMonitor`). A lightweight background sampler (system CPU% + pressure only, **every 10s**) runs while the popover is closed so alerts fire when you're not looking. Notifications require the **bundled** `MacStats.app`. (3) **Empty Trash** — Trash-size readout + an Empty action that scripts Finder (one-time Automation permission prompt). Memory pressure now comes from the **real kernel level** (`kern.memorystatus_vm_pressure_level`), not a used-fraction heuristic.
- ✅ **65 tests pass** via `./Scripts/test.sh`.
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
`./Scripts/bundle.sh && open MacStats.app`.

## Locked technical decisions

- **Native Swift only**: SwiftUI `MenuBarExtra` + **Swift Charts** + IOKit/Mach/`getifaddrs`.
  (User briefly considered Swift+Tauri; settled on pure Swift — Swift Charts covers the "nice graphs" need.)
- **Build with Swift Package Manager**, NOT Xcode. This machine has **Command Line Tools only**
  (no `xcodebuild`); SwiftUI + Charts + MenuBarExtra were verified to compile under it.
  Toolchain: Swift 6.2, language mode v5, target macOS 14+.
- **Not sandboxed** (full sensor access); notarize later if sharing. NOT Mac App Store.
- **Adaptive refresh**: while the popover is closed, only a lightweight alert sampler runs
  (~10s: system CPU% + memory pressure, no per-app scan); 1s full collection only while the
  popover is open; per-process scan only when drilled into a card.

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
./Scripts/bundle.sh  # assemble MacStats.app, then: open MacStats.app
```

> **Tests use Swift Testing, not XCTest.** This machine has Command Line Tools only
> (no full Xcode), so XCTest is unavailable. Tests use `import Testing` / `@Test` /
> `#expect`; `Scripts/test.sh` wraps `swift test` with the CLT framework search path.
> Do not use `swift test` directly (it can't find the test framework).
