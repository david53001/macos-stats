# MacStats — Per-App Breakdown (Drill-In) — Design Spec

- **Date:** 2026-05-29
- **Status:** Implemented (Milestone 3 core — CPU + Memory). Built & verified on-device 2026-05-29.
- **Mockup:** [`docs/mockups/per-app-breakdown-mockup.html`](../../mockups/per-app-breakdown-mockup.html) — open in a browser
- **Supersedes:** the per-app breakdown portion of Milestone 3 in
  [`2026-05-29-macstats-menubar-design.md`](2026-05-29-macstats-menubar-design.md).
  This spec **drops the "Free Memory" action** entirely (out of scope, removed from the
  project plan).

## Summary

From the overview popover, clicking the **CPU** or **Memory** card drills into a ranked
list of the apps using the most of that resource. The list lives in the same popover
window (the overview content is replaced, with a back arrow to return). Each app is one
row — icon, name, a usage bar, and the value. Right-clicking a row offers **Quit** and
**Force Quit**. The per-process scan only runs while a breakdown is open, preserving the
app's zero-idle-cost principle.

## Goals

- Let the user see, at a glance, which apps dominate **CPU** or **Memory** right now.
- Let the user **quit** (graceful) or **force quit** an app directly from that list.
- Keep it cheap: per-process enumeration runs **only** while a breakdown is visible.
- Match the existing native popover look (Swift Charts era cards, glass popover).

## Non-Goals

- **Network and Battery breakdowns.** Per-app network has no clean public macOS API
  (deferred to v2 in the base spec); per-app energy impact is only a private
  approximation. Their cards stay non-interactive (no chevron).
- **Free Memory action.** Removed from scope entirely.
- **A larger history chart inside the drill-in.** The drill-in is the list, not a chart
  view. (May revisit later.)
- **Expanding a row into its child processes.** Apps are shown grouped only.
- **System / root-owned processes.** Only the user's own (quittable) apps are listed.

## UX Design

See the mockup. Summary:

### Trigger & navigation
- The **CPU** and **Memory** overview cards gain a blue chevron (`›`) on the right edge
  and become clickable (whole card is the hit target). **Network** and **Battery** cards
  are unchanged and show no chevron.
- Clicking a tappable card **replaces the popover content** with that category's
  breakdown (same window, no second window).
- The breakdown header is: a blue back chevron (`‹`) + the category name on the left, and
  the current live total on the right (`37% used` for CPU, `9.2 / 16 GB` for Memory).
- The back chevron returns to the four-card overview.
- The footer (`⚙ Settings` · `Quit`) is unchanged on both views.

### The list
- **Grouped by app:** one row per app, aggregating all of that app's processes. Row =
  app icon (real macOS app icon) + app name + a thin usage bar + the value, right-aligned.
- **Sorted descending** by the category's usage.
- **Top ~8 shown**, the rest reachable by scrolling; a hint (`⌄ scroll for N more`)
  indicates more rows exist.
- **CPU value:** percentage; may exceed 100% across multiple cores (Activity-Monitor
  convention). **Memory value:** formatted (e.g. `3.8 GB`, `0.6 GB`).
- The usage bar fills proportionally to the top app's value (visual ranking aid),
  colored to match the category (CPU green, Memory blue).
- **Measuring state:** on first entry to the **CPU** breakdown, before two samples exist,
  the list area shows a brief centered spinner + "Measuring…". (Memory needs no delta, so
  it populates immediately.)

### Actions (right-click / control-click a row)
- **Quit** — sends `SIGTERM`. Well-behaved apps run their normal termination (including
  any unsaved-work prompt). Fires immediately; **no** extra confirmation dialog.
- **Force Quit** — sends `SIGKILL` (immediate, no save). Shows a confirmation alert first:
  > Force quit "<App>"? The app will quit immediately and you'll lose any unsaved changes.
  > [Cancel] [Force Quit]
- The menu shows a faint disabled header with the app name, then **Quit**, a separator,
  then **Force Quit** (red/destructive).
- Only apps the user owns are listed, so quit is always permitted.

## Architecture

Fits the existing collector/store/scheduler/UI split. New and changed units:

- **`ProcessSample` (value type):** `pid`, owning app identity (bundle id / name / icon
  source), `cpuPercent`, `memoryBytes`. Plain data, no UI.
- **`ProcessCollector` (new):** enumerates the current user's processes
  (`proc_listpids`) and reads per-process CPU time + memory
  (`proc_pid_rusage` / `proc_pidinfo`). CPU% is derived from the **delta** of CPU time
  between two samples over the elapsed interval (so it needs a previous sample). Returns
  `[ProcessSample]`. Pure logic over injectable raw inputs where possible (the delta math
  is unit-testable; the syscalls are isolated behind a thin reader).
- **`AppAggregator` (new, pure):** maps processes → apps and sums their usage. Resolves a
  pid to its owning app (bundle URL via `NSRunningApplication` / `proc_pidpath`), then
  groups. Filters to user-owned, quittable apps. Returns a sorted `[AppUsage]`
  (`appName`, `bundleURL`/icon source, `representativePIDs`, `value`). **This is the
  testable core** — given a list of `ProcessSample` + an identity map, it produces the
  grouped, sorted result.
- **`MetricsStore` (extended):** holds the latest `[AppUsage]` for the **active**
  breakdown category (CPU or Memory) plus a "measuring" flag. Only one category's
  breakdown is live at a time.
- **`RefreshScheduler` (extended):** gains a drill-in visibility state — "which category
  breakdown is open" (none / CPU / Memory). Only when a breakdown is open does it run the
  `ProcessCollector` (at the 1s open cadence). Closing the breakdown or the popover stops
  per-process scanning.
- **`ProcessActions` (new, tiny):** `quit(app)` → `SIGTERM` to the app's processes;
  `forceQuit(app)` → `SIGKILL`. Thin wrapper over `kill(2)` / `NSRunningApplication`.
- **UI:** a `DetailView` (or `BreakdownView`) shown in place of `OverviewView` when a
  category is drilled into; `OverviewView` gets the chevron + tap handling on the CPU and
  Memory cards and owns the navigation state (which category, or none). The Force Quit
  confirmation is a standard SwiftUI alert. The right-click menu is a SwiftUI
  `contextMenu` on each row.

**Data flow:** card tap → navigation state = category → `RefreshScheduler` starts
`ProcessCollector` at 1s → samples feed `AppAggregator` → grouped `[AppUsage]` written to
`MetricsStore` → `BreakdownView` renders. Right-click → `ProcessActions`; Force Quit goes
through the confirmation alert first.

## Data Sources & Feasibility

| Need | API / source | Notes |
|------|--------------|-------|
| Enumerate user processes | `proc_listpids(PROC_ALL_PIDS)` | filter to current uid |
| Per-process CPU | `proc_pid_rusage(RUSAGE_INFO_V*)` CPU time → delta / interval | needs prev sample |
| Per-process memory | `proc_pidinfo(PROC_PIDTASKINFO)` / `ri_phys_footprint` | instantaneous |
| pid → app identity + icon | `NSRunningApplication`, `proc_pidpath` → bundle URL → `NSWorkspace.icon(forFile:)` | group key |
| Quit | `kill(pid, SIGTERM)` (or `NSRunningApplication.terminate()`) | own procs only |
| Force Quit | `kill(pid, SIGKILL)` (or `forceTerminate()`) | confirmed first |

All are non-privileged for the user's own processes (the app is not sandboxed).

## Edge Cases

- **CPU first sample:** show "Measuring…" until a delta exists (~1s).
- **App with many processes:** summed into one row; quit targets all of the app's pids.
- **Process exits mid-view:** dropped on the next 1s refresh; quitting a gone pid is a
  no-op (ignore `ESRCH`).
- **Non-app / helper processes with no bundle:** if not attributable to a user app, they
  are excluded (user-apps-only rule). (Grouping fallback for un-bundled user processes:
  group by executable name — implementation detail for the plan.)
- **Empty list:** unlikely for CPU; if it happens, show a simple "No apps" message.

## Performance

- Per-process scan runs **only** while a breakdown is open, at the **1s** open cadence —
  consistent with the app's "don't hog the resources it monitors" principle.
- Leaving the breakdown (back) or closing the popover returns the scheduler to its idle /
  overview cadence and stops per-process enumeration.

## Testing Strategy (Swift Testing — see CLAUDE.md)

- **`AppAggregator`** (pure): given fixture `[ProcessSample]` + identity map → assert
  correct grouping, summing, descending sort, top-N, and user-apps-only filtering.
- **CPU delta math**: given two CPU-time samples + interval → assert percentage.
- **`RefreshScheduler`**: assert per-process scanning is enabled only in the drill-in
  state and disabled on return to overview / closed popover.
- **`ProcessActions`**: uses `NSRunningApplication.terminate()` / `forceTerminate()` for
  correct graceful-quit (⌘Q save-prompt) semantics — validated on-device, not unit-tested
  (AppKit termination has no clean test seam).
- Syscall readers (`readRawProcesses`), `NSWorkspace` app set, and icon lookup are
  validated manually on-device (`readRawProcesses` also gets a smoke test), guarded behind
  thin readers.
- UI validated visually against the mockup.

## Build Order (feeds the implementation plan)

1. `ProcessCollector` + `ProcessSample` (syscall reader + CPU delta math) with tests.
2. `AppAggregator` (grouping/sort/filter) with tests — the core.
3. `MetricsStore` + `RefreshScheduler` extensions (active-breakdown state, gated scan)
   with scheduler tests.
4. `BreakdownView` + overview chevrons/navigation (in-popover swap, measuring state).
5. `ProcessActions` + right-click menu + Force Quit confirmation.
6. Manual on-device verification against the mockup.
