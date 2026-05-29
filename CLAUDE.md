# MacStats

A lightweight **macOS menu-bar system monitor** (native Swift). Lives next to the
battery/clock. Click the menu-bar item → overview popover with one card per stat +
live sparkline; click a card → per-app breakdown with quick actions (Quit / Force Quit).

## Status (as of 2026-05-29)

- ✅ Design **approved**, visual mockups **approved**.
- ✅ **Milestone 1 BUILT** — runnable menu-bar app: live CPU %, Memory, Network, Battery + Swift Charts sparklines + adaptive refresh (3s idle / 1s open). `swift build` green; `./Scripts/bundle.sh` produces a Dock-iconless `MacStats.app`.
- ✅ **Per-app breakdown BUILT** (Milestone 3 core) — clicking the **CPU** or **Memory** card opens an in-popover drill-in: processes grouped by app (one row per app, summed across its processes), ranked high→low, top ~8 with scroll; right-click a row → **Quit** (graceful) or **Force Quit** (confirms first). CPU shows a brief "Measuring…" state (needs two samples); Memory is instant. User-apps-only; the per-process scan runs **only** while a breakdown is open. Verified on-device.
- ✅ **49 tests pass** via `./Scripts/test.sh`.
- ⬜ **Milestone 2** (CPU temp, battery health/watts) and **Milestone 4** (Settings, customizable display, alerts) not started. Per-app **Network/Battery** breakdowns remain deferred (no clean per-app network API; energy impact only approximate).

## Start here

| What | Where |
|------|-------|
| Overall design spec | `docs/superpowers/specs/2026-05-29-macstats-menubar-design.md` |
| Per-app breakdown spec | `docs/superpowers/specs/2026-05-29-macstats-per-app-breakdown-design.md` |
| Per-app breakdown plan | `docs/superpowers/plans/2026-05-29-macstats-per-app-breakdown.md` |
| Approved UI mockups | `docs/mockups/menubar-mockup.html`, `docs/mockups/per-app-breakdown-mockup.html` (open in a browser) |

## To resume building

Milestone 1 and the per-app breakdown (Milestone 3 core) are built (see Status). The next
unbuilt milestone is **Milestone 2** (CPU temp via IOKit `IOHIDEventSystemClient`, battery
health/watts): write a plan with **superpowers:writing-plans**, then execute it with
**superpowers:subagent-driven-development**. To run the current app:
`./Scripts/bundle.sh && open MacStats.app`.

## Locked technical decisions

- **Native Swift only**: SwiftUI `MenuBarExtra` + **Swift Charts** + IOKit/Mach/`getifaddrs`.
  (User briefly considered Swift+Tauri; settled on pure Swift — Swift Charts covers the "nice graphs" need.)
- **Build with Swift Package Manager**, NOT Xcode. This machine has **Command Line Tools only**
  (no `xcodebuild`); SwiftUI + Charts + MenuBarExtra were verified to compile under it.
  Toolchain: Swift 6.2, language mode v5, target macOS 14+.
- **Not sandboxed** (full sensor access); notarize later if sharing. NOT Mac App Store.
- **Adaptive refresh**: near-zero cost when popover closed (~3s, menu-bar values only);
  1s full collection only while popover open; per-process scan only when drilled into a card.

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
