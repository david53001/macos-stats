# Codebase Scan Report

**Scanned:** /Users/davidghermansteinberg/Desktop/Home/Code/MacStats
**Date:** 2026-05-30
**Project profile:** Native macOS menu-bar app (SwiftUI `MenuBarExtra` + Swift Charts). ~830 LOC source across two SPM targets — `MacStatsCore` (pure logic + syscall readers) and `MacStatsApp` (views + orchestrator) — plus ~430 LOC of tests. No third-party dependencies.
**Method:** Full inline read of every source, test, and script file (the codebase is small enough that one context reviews it more accurately than fan-out agents). Build + tests run to verify claims.

---

## Executive Summary

MacStats is a **healthy, well-engineered small codebase** — easily in the top tier for a project this size. The architecture is genuinely good: a clean split between a dependency-free, pure-function `MacStatsCore` (all the math is testable and tested) and a thin SwiftUI `MacStatsApp` orchestrator. There are **no critical or high-severity bugs**, **zero third-party dependencies**, **49 passing tests**, and unusually thoughtful inline comments that explain *why* (the rate-window averaging, the priming-burst ramp, the nested-`ObservableObject` observation trap). `swift build` is green and `./Scripts/test.sh` reports 49/49.

The three things most worth attention are all **accuracy/clarity**, not correctness: (1) the **memory-pressure indicator is a used-fraction heuristic**, which on macOS — where RAM is deliberately kept near-full — will likely show 🟡/🔴 even on a healthy machine; (2) the **CPU breakdown uses a different scale** than the overview card (per-app rows can each exceed 100% and sum past the header total — matches Activity Monitor, but can confuse); and (3) some **doc/code drift** ("3s idle" refresh is described but not actually run while closed). All are low-effort to address and several are already noted in code comments or the Milestone 4 plan.

## Health Scorecard

| Dimension      | Score | Top Finding |
|----------------|-------|-------------|
| Architecture   | 🟢 | Clean Core/App split; pure, testable logic isolated from UI and syscalls. |
| Code Quality   | 🟢 | Idiomatic, well-commented; comments explain *why*, not just *what*. |
| Correctness    | 🟡 | Memory "pressure" is a used-fraction proxy; CPU breakdown scale differs from the overview card. |
| Test Coverage  | 🟢 | 49 tests, strong pure-function coverage; gap: `AppModel` timer/visibility orchestration untested. |
| Dependencies   | 🟢 | Zero third-party deps — system frameworks only. No supply-chain or version risk. |
| Documentation  | 🟢 | CLAUDE.md, README, specs, plans, mockups all present; minor "3s idle" drift. |
| Security       | 🟢 | Tiny surface: read-only sensors, uid-filtered scan, can only quit *your own* GUI apps; force-quit confirms. |

---

## Critical Issues (Fix Now)

**None.** No 🔴/🟠 findings. The items below are 🟡/🔵 accuracy and clarity notes.

## Architecture & Structure 🟢

- **Two-target split is the standout strength.** `MacStatsCore` holds the pure logic (`cpuBusyPercent`, `memorySample`, `networkThroughput`, `processCPUPercent`, `owningAppPID`, `aggregate`, `rateBaselineIndex`, `openPhaseInterval`) with no SwiftUI/AppKit dependency, so all the math is unit-tested. `MacStatsApp` is a thin orchestrator (`AppModel`) + SwiftUI views.
- **Single source of truth:** `MetricsStore` (`@MainActor ObservableObject`) is the only state the UI binds to; `AppModel` owns the syscall pipeline and the adaptive timers and pushes into it.
- **The expensive work is correctly gated:** the per-process scan runs *only* while a breakdown is open (`enterBreakdown`/`exitBreakdown`), on a dedicated timer separate from the sparkline tick. This is the whole "lightweight" thesis, and the code honors it.
- **A subtle SwiftUI trap is handled and documented:** `RootView` observes `store` directly (not just `model`) because SwiftUI won't observe a nested `ObservableObject` reached through `model.store` — `RootView.swift:8-11`.

## Code Quality & Patterns 🟢

- Clean, consistent, idiomatic Swift 6 (language mode v5). Naming is clear; functions are small and single-purpose.
- Comments are a genuine asset — they capture rationale (`RefreshScheduler.swift` burst/ramp, `MacStatsApp.swift` snapshot windowing).
- Defensive numerics throughout: clamping to 0 on counter resets, guarding divide-by-zero, cycle/gap guards in the parent-pid walk (`owningAppPID`).

Minor:
- 🔵 **"scroll for N more" hardcodes `8`** (`BreakdownView.swift:68-69`) while the visible row count is implied by `.frame(maxHeight: 300)`. If row height changes, the "8" and the actual visible count drift. Derive one from the other or pin row height.
- 🔵 **Disabled-button-as-header** for the context-menu app name (`BreakdownView.swift:57`) works but is a slightly hacky way to render a non-interactive label.
- 💡 `appName(nil)` → "this app" branch (`BreakdownView.swift:105-108`) is currently unreachable (the alert only shows when a target exists). Harmless.

## Correctness & Edge Cases 🟡

- 🟡 **Memory pressure is a used-fraction heuristic, not real pressure** (`MemoryStats.swift:35-39`): `frac > 0.90 → critical`, `> 0.75 → warning`. macOS intentionally keeps RAM near-full (caches, compressor), so used-fraction stays high even when the system reports *green* pressure. This will likely show 🟡/🔴 misleadingly often. **Already acknowledged** in the code comment and slated for Milestone 4. The real source is the memory-pressure level (e.g. `kern.memorystatus_vm_pressure_level` sysctl or a `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` source).
- 🟡 **CPU breakdown scale differs from the overview** (`ProcessBreakdown.swift:56-60`, `BreakdownView.swift:16-27`): the overview/header shows system-wide `cpuBusyPercent` (0–100, already core-normalized), but per-app rows use `processCPUPercent`, which can exceed 100% per app (multi-core, Activity-Monitor convention). So the **sum of rows can exceed the "X% used" shown in the header**, and bars scale to the top app rather than the header total. This *matches Activity Monitor*, but the two numbers sitting next to each other can confuse. Consider a one-line clarifier or scaling bars to a per-core-aware total.
- 🔵 **Network sums all non-`lo` link-layer interfaces** (`SystemReaders.swift:49-68`), including `utun`/VPN, `bridge`, `awdl`. VPN tunnels can double-count traffic that also traverses the physical NIC. Acceptable for a glanceable number; note it if accuracy ever matters.
- 🔵 **`mach_host_self()` send right is not deallocated** in the `host_statistics*` readers. This is the well-known special-host-port case that's effectively harmless and commonly ignored; flagging only for completeness.

## Test Coverage & Quality 🟢

- **49 tests, all passing** (verified via `./Scripts/test.sh`). Swift Testing (`import Testing`/`@Test`/`#expect`), not XCTest — correct choice given the Command-Line-Tools-only toolchain, and the wrapper script documents why.
- Strong coverage of the pure functions: CPU%, memory sample, network throughput, per-process CPU%, `owningAppPID` (cycles, orphans, broken chains), `aggregate` (group/sum/sort by both metrics), ring buffer, rate window, battery parse, the refresh ramp (monotonic + clamps), and the full `MetricsStore` lifecycle.
- Sensible **smoke tests** for the non-deterministic syscall readers (sane-range / monotonicity checks rather than exact values).
- **Gap:** `AppModel` orchestration is untested — visibility transitions, snapshot pruning against the rate window, and timer lifecycle. It's `@MainActor` with `Timer`s so it's harder to test, but the snapshot-pruning logic in `tick()` is real logic that could be extracted and unit-tested.

## Dependencies & Package Health 🟢

- **Zero third-party dependencies.** Only system frameworks (SwiftUI, AppKit, Charts, IOKit, Darwin/Mach, Combine, Foundation). No supply-chain exposure, no version churn, nothing to audit.
- `Package.swift` is minimal and correct: `tools-version 6.0`, `macOS .v14`, `swiftLanguageModes: [.v5]`.

## Documentation & Developer Experience 🟢

- Excellent for the size: `CLAUDE.md` (current, with a status table and "resume here" guidance), `README.md`, design specs, plans, and HTML mockups under `docs/`.
- `Scripts/` are clean and documented (`bundle.sh`, `test.sh` with the CLT framework-path rationale, `install.sh` for Spotlight registration).
- 🔵 **Doc/code drift on the idle cadence:** `refreshInterval(for: .idle)` returns 3.0s and CLAUDE.md/README describe "3s idle / 1s open," but at runtime `setVisibility(.idle)` invalidates the timer and the menu-bar item is a *static glyph* with no live value — so nothing is actually collected on a 3s cadence while closed. The reality ("nothing runs while closed") is arguably *better* than the docs suggest; the `.idle` interval is only exercised by a unit test. Reconcile the docs (or wire a genuine idle menu-bar refresh if live menu-bar numbers are ever wanted).
- 🔵 The README ASCII mock shows menu-bar `🟢 58° 23%` and `BATTERY 84% · 12W` — i.e. temp/watts as if present. The surrounding prose correctly lists those as *planned*; just the diagram is aspirational.

## Security 🟢

- **Minimal attack surface.** No network calls, no file writes (beyond assembling the app bundle), no IPC, no privilege escalation. All sensors are read-only.
- **Process actions are safe by construction:** the scan is `uid`-filtered (`ProcessReader.swift:9,31`) and grouping anchors come from `NSWorkspace.runningApplications`, so the breakdown only ever lists — and can only quit — *the current user's own GUI apps*. Can't touch other users' or system processes.
- **Force Quit confirms first** (`BreakdownView.swift:83-93`) with a destructive-role alert; graceful Quit intentionally doesn't (mirrors ⌘Q).
- **Not sandboxed** — intentional and documented (needs direct sensor access; not destined for the App Store). Worth revisiting *if* file-mutating features (cache/trash cleanup) are ever added, since that materially changes the risk profile (see Recommended Improvements).

---

## Recommended Improvements (Non-Blocking)

Grouped by effort. These are 💡 ideas, not defects.

### Small (S)
- 💡 **Launch at login** via `SMAppService.mainApp.register()` (macOS 13+). Standard menu-bar-app convenience; a few lines + a Settings toggle.
- 💡 **Reconcile the "3s idle" docs** with the (better) reality that nothing runs while closed.
- 💡 **Accessibility labels** on the stat cards, app rows, and the menu-bar glyph. The custom-drawn glyph and the `GeometryReader` usage bars won't get useful VoiceOver labels for free — e.g. `accessibilityLabel("CPU 23 percent")`. Also honor **Reduce Motion** for the sparkline and **Dynamic Type** for the card text. Low effort, real accessibility payoff.
- 💡 **Clarify the CPU breakdown scale** (a "% of total CPU, can exceed 100% across cores" hint) to defuse the header-vs-rows confusion.

### Medium (M)
- 💡 **Disk stat card** — a natural 5th card (free/used space) reusing the existing `StatCard` + `Sparkline` pattern; read-only, low risk. Pairs naturally with any "reclaim space" feature by *showing* what's reclaimable.
- 💡 **Empty Trash** action with a size readout — the safest of the user's requested "cleanup" features (user-initiated, native behavior, confirmable).
- 💡 **Threshold alerts** (Milestone 4) via `UserNotifications` — e.g. low battery, runaway CPU. An "ambient" accessibility win: you don't have to keep the popover open.
- 💡 **Settings window** (Milestone 4) — toggle which cards show, refresh cadence, launch-at-login, alert thresholds.
- 💡 **Extract `AppModel`'s snapshot-pruning** into a pure function so the rate-window logic gets unit-tested like the rest of Core.

### Large (L)
- 💡 **Milestone 2** — CPU temperature (IOKit `IOHIDEventSystemClient`, sensor keys vary by chip — isolate it), battery health/cycle count, live watts. Already planned and specced.
- 💡 **"Cleanup" features (cache/temp files) — proceed with caution.** See the note below; recommend *reporting* reclaimable space + Empty Trash first, rather than auto-deleting caches.

### ⚠️ Note on cache / temp-file cleaning
The headline request — "clear cache, empty bin, delete temp files" — splits sharply by risk:
- **Empty Trash:** safe, user-initiated, native — fine to add.
- **Clearing `~/Library/Caches` / "temp files":** **risky.** Blanket cache deletion is what gives "Mac cleaner" apps their bad reputation — it can sign users out, corrupt app state, and the space usually returns immediately. macOS already purges caches automatically under disk pressure. Recommend **showing** reclaimable/purgeable space (and offering Empty Trash) rather than auto-nuking caches. Any file-*mutating* feature also reopens the **sandbox/permissions** question (full-disk access, the risk profile shift noted in Security).

---

## Consolidated Recommendations

### Immediate (this sprint)
- No bug fixes required. If touching anything: add **VoiceOver/accessibility labels** (S) and **reconcile the "3s idle" docs** (S) — both trivial and aligned with the "a few accessibility features" goal.

### Short-term (1–2 months)
- **Launch at login** + a small **Settings** window (toggles, thresholds).
- **Disk stat card** and **Empty Trash** (the safe slice of the cleanup idea).
- Replace the **memory-pressure heuristic** with a real pressure source; **clarify the CPU breakdown scale**.

### Long-term (roadmap)
- **Milestone 2** (temp / battery health / watts) and **Milestone 4** (alerts, customizable menu-bar display) as already planned.
- Revisit **sandboxing** only if file-mutating cleanup features land.
