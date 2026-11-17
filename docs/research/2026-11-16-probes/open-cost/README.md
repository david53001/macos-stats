# Open-panel cost probe (2026-11-16, branch `perf/open-panel-cost`)

Measures how much CPU MacStats uses while its panel is open, before and after the
`perf/open-panel-cost` changes. Those changes:

- The graph slide is a 12 fps clock-driven `TimelineView`, paused while the panel is closed.
  Before, it was a display-rate animation restarted every tick.
- The open tick goes from 0.5 s to 1 s on the overview, and to 2 s on a breakdown or Settings.
- The Trash is no longer read at all: the card has only an Empty button (the owner's choice).
- The screen resets on close without animation.

Background, results and next step: `docs/superpowers/plans/2026-11-16-open-panel-cost-progress.md`.

## 1. Off-screen probe (`run.sh`, `main.swift`, `Package.swift`)

The probe renders the **real** `OverviewView` and `BreakdownView`, with a `MetricsStore` fed the way
`AppModel` feeds it, in a window at desktop level + 1. The window is ordered back and never
activated, so nothing appears in front of you. It prints the probe process's CPU (`getrusage`).

```bash
cd "/Users/davidghermansteinberg/Desktop/Home/Projects/Code/Mac Apps/MacStats"
docs/research/2026-11-16-probes/open-cost/run.sh main 0.5 0.5   # v1.3.0 code at its cadences
docs/research/2026-11-16-probes/open-cost/run.sh "" 1.0 2.0     # working tree at the new cadences
```

- **Arguments:** a git ref to build (empty = the working tree), then the overview tick and the
  breakdown tick in seconds. The breakdown also gets a scan result every 2 s.
- **Where it builds:** `$TMPDIR/macstats-open-cost-probe`, never inside the repo. The SDK is pinned to
  `MacOSX26.5.sdk`.
- **Run length:** 3 runs × 15 s per screen, then 8 s "closed" (store paused, window ordered out but
  kept, as `MenuBarExtra` keeps it), then 5 s with no window.

**Limit:** the window is behind your other windows (`occlusionState` not visible), so macOS throttles
display-rate animation frames. These numbers therefore cover the per-tick work and the 12 fps
timeline. They do **not** cover the old display-rate slide; section 2 measures that live.

Results (% of one core; mean of 3 runs):

| Screen | v1.3.0 (`main`, 0.5 s ticks) | new (1 s overview / 2 s breakdown) |
|---|---|---|
| Overview | 4.16 | 2.81 |
| CPU breakdown (scan results every 2 s) | 2.05 | 1.42 |
| Closed: store paused, window hidden but kept | 0.32 | 0.32 |
| No window (process floor) | 0.30 | 0.57 |

**Bug the probe caught during development:** SwiftUI's `TimelineView` keeps firing in an ordered-out
window. The first probe version kept the overview window alive and unpaused, and measured 1.86 %
with "no window". So pausing the timeline on close (`Sparkline.live` ← `MetricsStore.isPublishing`)
was required then, and the "Closed" row (0.32 %, the same as before) showed that it works. Fix B (2026-11-17) removed
the `TimelineView` and that flag: the graphs are now Core Animation layers. Fix B's probe numbers are in the progress
note, section 4a.

## 2. Live measurement of the real app (`live.py`)

`live.py` is passive. Every 0.5 s it checks whether MacStats' panel window is on screen
(`CGWindowListCopyWindowInfo`), and adds up MacStats' and WindowServer's CPU time (`ps`) only while
it is. You open the panel yourself and leave it on the overview.

```bash
python3 docs/research/2026-11-16-probes/open-cost/live.py 40 1800   # wait for 40 s open, give up after 30 min
```

WindowServer's number also includes everything else on screen (videos, other apps), so treat it as
rough.

Results, 2026-11-16 (raw output: `live-results.txt`; % of one core):

| | v1.3.0 | branch at `d9f492e` |
|---|---|---|
| Panel open on the overview (~26 s) | 12.53 | 7.98 |
| Panel closed | 0.05 | 0.02 |

To see where the open-panel CPU goes, `sample-when-open.py <out.txt>` waits for the panel and then runs
`sample` for 12 s. The branch profile, and the next fix it led to (graphs as Core Animation layers), are in
`docs/superpowers/plans/2026-11-16-open-panel-cost-progress.md`.
