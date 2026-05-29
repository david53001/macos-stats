# MacStats

A lightweight **macOS menu-bar system monitor** (native Swift). Lives next to the
battery/clock. Click the menu-bar item → overview popover with one card per stat +
live sparkline; click a card → per-app breakdown with quick actions (Quit / Free Memory).

## Status (as of 2026-05-29)

- ✅ Design **approved**, visual mockup **approved**.
- ✅ Milestone 1 implementation plan **written** (not yet built).
- ⬜ No code written yet. Project is **not yet a git repo** (`git init` is Task 1 of the plan).

## Start here

| What | Where |
|------|-------|
| **Build plan (do this first)** | `docs/superpowers/plans/2026-05-29-macstats-milestone-1-foundation.md` |
| Design spec | `docs/superpowers/specs/2026-05-29-macstats-menubar-design.md` |
| Approved UI mockup | `docs/mockups/menubar-mockup.html` (open in a browser) |

## To resume building

Execute the Milestone 1 plan using the **superpowers:subagent-driven-development**
(recommended) or **superpowers:executing-plans** skill. It is a complete, test-first,
12-task plan that produces a runnable app.

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
- **Milestone 3:** per-app breakdown + drill-in + quick actions (Quit / Free Memory).
- **Milestone 4:** Settings, customizable menu-bar display, alerts; real memory-pressure source.
- **Deferred (v2+):** per-app network (no clean public API), Disk, GPU/fans/raw sensors, multiple menu-bar items, persisted history.

## Build & test commands (valid once Task 1 of the plan is done)

```bash
swift build          # compile
./Scripts/test.sh    # run the unit + smoke tests (Swift Testing; see note)
./Scripts/bundle.sh  # assemble MacStats.app (created in Task 12), then: open MacStats.app
```

> **Tests use Swift Testing, not XCTest.** This machine has Command Line Tools only
> (no full Xcode), so XCTest is unavailable. Tests use `import Testing` / `@Test` /
> `#expect`; `Scripts/test.sh` wraps `swift test` with the CLT framework search path.
> Do not use `swift test` directly (it can't find the test framework).
