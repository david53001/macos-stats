# Open-panel cost pass: progress and next step (2026-11-16)

**Branch:** `perf/open-panel-cost`, cut from `main` at `84a42a0` (v1.3.0). Committed locally, **not pushed, not
released**. Built with `./Scripts/install.sh` and **installed** in `~/Applications/MacStats.app`. The version number
is still 1.3.0 / build 5, so Sparkle won't offer anything over it.

**Status (2026-11-17): done and released as v1.3.1 (build 6).** Fix B is built (section 4a). The owner checked it live
(4.7 % open, against 12.5 % on v1.3.0) and chose to leave the rest: the number fade costs about 3 % and the temperature
read about 0.7 %. `main` is at `9bc2894`, GitHub release `v1.3.1` is Latest, and it is installed in `~/Applications`.

## 1. Why

The owner reported that MacStats "uses a lot more than needed". A 7-agent audit on 2026-11-16 (three code readers,
each with a skeptic, plus a live measurement) found two things:

- **Panel closed (the normal state):** this is not the problem. The installed v1.3.0 used 55 s of CPU over 4 days
  (about 0.015 % of one core), had 0 new idle wakeups, and was the cheapest menu-bar app on the Mac.
- **Panel open:** this is where the CPU goes. In v1.3.0 the overview cost about 12 % of one core. The three graphs
  ("sparklines") ran a 0.5 s linear slide that restarted on every 0.5 s tick, so SwiftUI redrew at display rate the
  whole time the overview was on screen.

Smaller findings:

- The Trash size was read through Finder AppleScript on every open, one Apple Event per item.
- After the first open, memory stays at 42–47 MB, against 13 MB right after launch. This is malloc fragmentation
  plus the hidden panel's views, which `MenuBarExtra` keeps alive. It is not a leak.

## 2. What the branch changed (commits `acf75f8`, `e9dfe22`, `d9f492e`, and a comment fix)

1. **Graph slide.** `Sources/MacStatsApp/Sparkline.swift`:
   - A `TimelineView(.animation(minimumInterval: 1/12, paused: !live))` moves the graph from the clock, using
     `sparklineSlideLag` in `Sources/MacStatsCore/SparklineGeometry.swift`. The paths are built once per sample,
     outside the timeline.
   - `live` comes from `MetricsStore.isPublishing`, which is false while the panel is closed or covered. This is
     **required**: a `TimelineView` keeps firing in an ordered-out window. The probe in section 3 caught this.
2. **Cadence.** In `Sources/MacStatsCore/RefreshScheduler.swift`:
   - The open tick went from 0.5 s to **1 s** on the overview (`refreshInterval(for: .popoverOpen)`), with 0.1 s
     tolerance.
   - On a breakdown or in Settings the tick follows the 2 s scans (`AppModel.scheduleNextTick`).
   - Coming back to the overview samples at once (`AppModel.overviewShown`).
   - The history keeps 60 + 2 × tick seconds, so the left edge of the graph never shows a gap.
3. **Trash card.** By the owner's choice it is now "Trash" plus an **Empty** button, with no size shown.
   - MacStats never reads the Trash. Finder is only asked when emptying, so the permission prompt comes at the first
     Empty.
   - A refused access is explained in the error `NSAlert`, which has an **Open Settings** button.
   - Why: Finder never sizes some folders in the Trash. On the owner's Mac a folder stayed `missing value`, so
     v1.3.0 showed the size as unknown on every open after 2 s of polling.
   - Summing the folder's files with `entire contents` was tried and dropped: Finder skips hidden files (silently
     low) and can walk a big folder for minutes.
   - The welcome card's Finder line now says the prompt comes with the first Empty (`TourCatalog.finderPermission`).
4. **Close.** The screen reset on close runs without animation (a `Transaction` with `disablesAnimations`). A second
   `malloc_zone_pressure_relief` runs about 20 s after the first.

**Verification:**

- **Tests:** `./Scripts/test.sh` passes 419 tests. That is the 415 from v1.3.0, plus new tests for the slide, the
  pause flag and the cadence, minus the Trash-size tests removed with the feature.
- **Independent review:** a review subagent found no bugs in the cadence or the graph. Its Trash findings (folder
  summing, a race between Empty and a running read, non-thread-safe `NSAppleScript`) were fixed, and then removed
  entirely with the readout.
- **Owner checks still open:** whether the graphs look smooth to the owner's eye, and the new Trash card, including
  the first-Empty permission prompt on a Mac that hasn't granted it.

## 3. Measurements

**Off-screen probe.** `docs/research/2026-11-16-probes/open-cost/README.md` (`run.sh`). The probe window sits behind
the owner's windows, so display-rate animation frames are throttled. These numbers therefore under-count the old slide.

| Screen | v1.3.0 | branch |
|---|---|---|
| Overview | 4.16 % | 2.81 % |
| Breakdown | 2.05 % | 1.42 % |
| Panel closed | 0.32 % | 0.32 % |

**Live, real app, owner opening the panel on the overview.** Script: `live.py` in the same folder. Raw output:
`live-results.txt`. Values are % of one core.

| | v1.3.0 | branch |
|---|---|---|
| Panel open (~26 s each) | **12.5 %** | **8.0 %** |
| Panel closed | 0.05 % | 0.02 % |

**Profile of the branch build with the panel open.** `sample` over 12 s, taken with `sample-when-open.py` in the probe
folder. The main thread was busy about 790 of 10,290 ms (about 7.7 %):

- **About 6.5–7 %: Core Animation commits that re-layout and re-render the SwiftUI hosting view, about 5 ms per
  12 fps frame.**
  - The heavy part is `CALayer _display` → `CGDrawingLayer.draw` → RenderBox → glyph rendering with transparency
    layers on the CPU.
  - Each overview card is a `Button` (`StatCard`), so its label, number and graph are drawn together into one CPU
    drawing layer.
  - Moving the graph makes the whole card, text included, re-rasterize every frame. Cutting the frame rate only
    divided this cost.
- **About 0.5 %:** `CPUTemperatureReader.read()` (`Sources/MacStatsCore/AppleSensorReader.swift:66`). It takes about
  10 ms per call in `IOHIDEventSystemClientCopyEventForService`, every 2 s.
- **The rest:** the 1 s sampling (CPU ticks, memory, network), which is negligible.

## 4. Next step: Fix B, graphs as Core Animation layers (owner-approved 2026-11-16)

**Goal:** the open overview drops from 8 % to about 1–2 % of one core, with the graphs looking exactly as now.

**Idea:** take the graph out of SwiftUI's drawing. Each sparkline becomes an `NSViewRepresentable` whose `NSView`
hosts its own `CALayer`s. The slide is a `CABasicAnimation`, which the window server runs at display rate, so the app
does no work per frame. The card's text is then only redrawn when its value changes.

**This replaces a locked decision** in `CLAUDE.md` → "Locked technical decisions" ("Graphs are a custom SwiftUI
`Shape`"). Update that line to: graphs are Core Animation layers (`CAShapeLayer` + `CAGradientLayer`) in an
`NSViewRepresentable`, with the same geometry and look; owner-approved 2026-11-16 for CPU.

**Plan.** Files: `Sources/MacStatsApp/Sparkline.swift`, plus a pure path builder in `Sources/MacStatsCore/SparklineGeometry.swift`.

1. **Pure path builder (MacStatsCore, unit-tested).**
   - Move what `SparklineShape.path(in:)` does into a function returning a `CGPath`, for example
     `sparklinePath(samples:end:window:upper:in rect:area:) -> CGPath`.
   - It uses the existing `sparklineX`, `monotoneCubicSegments`, `edgeInset` 1.5, `plotWidth` = width − 1.5 − 1,
     `top` = minY + 2, and `bottom` = maxY − 1. The area is closed down to `maxY`.
   - **Tests:** the curve passes through each sample point, the area path closes at the bottom, and an empty sample
     list gives an empty path.
2. **Layer view.** In `SparklineLayerView: NSViewRepresentable`, the `NSView` is created with `wantsLayer = true`,
   `layerContentsRedrawPolicy = .never` and `layer.masksToBounds = true`. Its sublayers:
   - `slideLayer` (a plain `CALayer`, frame = bounds), which holds:
     - `fillLayer`: a `CAGradientLayer` from color × 0.45 at the top to color × 0 at the bottom, masked by a
       `CAShapeLayer` holding the area path;
     - `lineLayer`: a `CAShapeLayer`, `strokeColor` = color, `lineWidth` 1.6, `lineCap`/`lineJoin` `.round`,
       `fillColor` nil.
   - **Colors:** resolve the SwiftUI `Color` with `NSColor(color)` inside
     `effectiveAppearance.performAsCurrentDrawingAppearance`. Re-resolve them in `viewDidChangeEffectiveAppearance`,
     so light/dark switches follow.
   - **Scale:** set `contentsScale` from `window?.backingScaleFactor` in `viewDidChangeBackingProperties`.
   - The baseline hairline (0.5 pt, `Color.primary.opacity(0.1)`) can stay in SwiftUI as the view's `.background`.
3. **Update on a new sample** (`updateNSView`, when `points.last?.time` changed).
   - Inside a `CATransaction` with `setDisableActions(true)`, set both paths so the newest point sits at the right
     edge.
   - If the gap since the previous sample is at most 2 × `refreshInterval(for: .popoverOpen)`, add a
     `CABasicAnimation(keyPath: "transform.translation.x")` to `slideLayer`:
     - from `interval / window × plotWidth` to 0;
     - duration = `refreshInterval(for: .popoverOpen)`, linear timing;
     - model value 0, so a late sample just holds still.
   - Otherwise (the first sample after reopening) show it in place.
   - This is the same motion as `sparklineSlideLag`. Keep that function and its tests as the spec, or remove them if
     they become unused.
4. **Rescale** (a dynamic `upper` change; only the network graph, rare).
   - The current version eases over 0.4 s. With layers: if the old and new paths have the same element count, add a
     `CABasicAnimation(keyPath: "path")` of 0.4 s ease-in-out; otherwise set the paths without animation.
   - Check visually that a rescale doesn't look broken.
5. **Clean-up.** Remove the `TimelineView`, `Sparkline.live` and the three `live:` arguments in `OverviewView`.
   - `MetricsStore.isPublishing` and its test become unused; remove them. They were added on this branch.
   - Keep `historyWindow` = 60 + 2 × tick.
   - Keep `visibleSamples(... window: window + 2 × tick)`.

**Optional, same session:**

- Read the chip temperature every 5 s instead of 2 s (`temperatureInterval` in `RefreshScheduler.swift`, about 0.5 %
  → 0.2 %).
- Or find out why one read takes about 10 ms: how many `tdie` services it queries.

## 4a. Fix B as built (2026-11-17)

A 7-agent workflow did the work: one builder, three bug hunters (render equivalence, lifecycle/cost, code review), one
skeptical reproducer, one fixer and one final checker. Every window stayed off-screen, and every build ran under one lock.

- **Code:**
  - `Sources/MacStatsApp/Sparkline.swift`: `SparklineLayers` (`NSViewRepresentable`) wraps `SparklineLayerView`.
    - Its view is flipped and returns nil from `hitTest`, so clicks and hover still reach the card.
    - It redraws only when the graph data changes.
  - `sparklinePath` and `sparklinePlotWidth` are new in `Sources/MacStatsCore/SparklineGeometry.swift`.
  - `isPublishing`, `Sparkline.live` and the `TimelineView` are removed.
- **Differences from the plan:**
  - The slide starts at `sparklineSlideLag` and lasts that long, so it follows the clock as before.
  - The rescale eases from the new samples drawn at the old scale, so the element counts always match.
- **Bug found and fixed:** the graphs snapped about 2 pt left whenever the tour started, ended, paused or resumed.
  - Cause: `TourAnchorModifier`'s `if/else` rebuilds the card, so a new layer view came up at offset 0.
  - Fix: a new view starts its slide from the clock once layout gives it a width (`needsInitialSlide`).
  - Checked with an off-screen probe: before the fix the graph shifted 3-4 px in 7 of 8 toggles, after it 0 px in 8 of 8.
- **Finding rejected:** a blank strip at the left edge during the slide. It was an artifact of the probe, which used a
  60 s store. The app uses a 62 s store.
- **Render compare against HEAD:** checked off-screen in light and dark, with rising, flat and spiky series.
  - Graph regions: mean difference ≤ 0.23 and max 1-26 out of 255, all anti-aliasing.
  - At rest the two match exactly. Mid-slide they are within ±0.5 pt.
  - The tour dim, opacity, scale, offset and push transition all apply to the layer graph.
- **Known cosmetic difference:** a network rescale eases over 0.4 s instead of the old quick spring. The end state is
  identical.
- **Off-screen probe** (`run.sh`, 1 s / 2 s ticks, % of one core, 3 × 15 s):

  | Screen | HEAD `ceb9051` | Fix B |
  |---|---|---|
  | Overview | 5.27 | 2.56 |
  | Breakdown | 2.14 | 2.19 |
  | Closed | 0.61 | 0.63 |

  The probe window is occluded, so these numbers leave out the window server and display-rate cost. The live
  measurement in section 5 decides.
- **Live, real app, panel open on the overview for 19 s (2026-11-17, `live.py`):**
  - MacStats used **4.66 %** of one core (v1.3.0: 12.5 %, `d9f492e`: 8.0 %). Closed: 0.02 %.
  - WindowServer used 36.3 %, which is rough and includes everything else on screen.
  - That misses the 1–2 % target. A profile (`sample-when-open.py`, 12 s) found what is left of the main thread's ~4.5 %:
    - about 3 %: SwiftUI re-rendering each card on the CPU during the 0.25 s `.contentTransition(.interpolate)` fade
      of its number/meta (`StatCard.swift:41-52`), roughly once a second per card;
    - about 0.7 %: `CPUTemperatureReader.read()` (~10 ms every 2 s);
    - the rest: 1 s sampling.
  - Options if wanted later: temperature every 5 s (-0.4 %), a shorter fade (-1.5 %) or no fade (-2-3 %). The owner
    chose to leave all three as they are (2026-11-17).

## 5. How to verify Fix B

1. `swift build`, with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` exported (see `CLAUDE.md`
   → Build & test).
2. `./Scripts/test.sh`: all tests pass.
3. An independent review subagent, given the diff only (not your conclusions). It should check:
   - the graph matches the old geometry;
   - nothing animates or runs while the panel is closed;
   - colors follow light/dark;
   - there is no left-edge gap.
4. Off-screen render check. The method is `docs/superpowers/plans/2026-10-06-squircle-progress.md` and the
   tour-render probe `docs/research/2026-10-06-probes/tour-render/`: windows at desktop level + 1, ordered back,
   captured with `CGWindowListCreateImage`. Compare a capture of the overview before and after; the graphs should be
   pixel-close.
   - **Never put a window in front of the owner's windows.**
5. `./Scripts/install.sh`, then the **live measurement with the owner**:
   - Run `python3 docs/research/2026-11-16-probes/open-cost/live.py 15 1800` in the background.
   - Ask the owner to open MacStats on the overview for about 20 s, then close it. The script prints after every
     close.
   - Compare with the table in section 3: v1.3.0 12.5 %, this branch 8.0 %. The target is about 1–2 %.
   - If it's still high, run
     `python3 docs/research/2026-11-16-probes/open-cost/sample-when-open.py /tmp/sample.txt` and ask for one more
     open.
6. Owner looks at the graphs: same look, smooth slide.

## 6. After Fix B: shipping (only when the owner asks)

Merge `perf/open-panel-cost` into `main`. Bump `Resources/Info.plist` to 1.3.1 and `CFBundleVersion` 6, add a
`CHANGELOG.md` entry, then follow `CLAUDE.md` → "Publishing an update" and `docs/sparkle-updates/README.md`.

## 7. Other open items found on 2026-11-16 (not fixed)

- **Battery estimator, possible bug.** `batteryDrainTypicalSeconds` went up by 1 while the Mac was on AC, but the
  typical drain should only learn on battery. See `AppModel.refreshBattery` in
  `Sources/MacStatsApp/MacStatsApp.swift`; the suspect is an edge case near plug/unplug.
- **Memory after the first open.** It stays at 42–47 MB against 13 MB fresh: malloc fragmentation, and the hidden
  panel's views kept alive by `MenuBarExtra`. Not yet re-measured after the second relief.
- **Covered, then hidden without a notification.** If the panel is covered and then ordered out with no window
  notification, `panelShown` stays true, so the next open skips the real-open branch (tour open, reset). This edge
  case predates this branch and has not been seen live.
- **Stale line in `feat/stability-tour`'s `CLAUDE.md`.** It says "idle redraw cost after the popover has been opened
  not fixed". That was fixed in `74b7a52`, which shipped in v1.3.0.
