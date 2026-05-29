# MacStats — Instant popover graph (priming burst) — Design Spec

- **Date:** 2026-05-29
- **Status:** Design — awaiting user review
- **Scope:** One focused behavior change to the popover open-phase. No new metrics, no UI layout changes.

## Summary

When the popover opens it currently shows a ~1s blank/empty state and then builds its
sparklines at one point per second. This spec replaces that with a **priming burst**: on
open, MacStats collects real samples rapidly (~100ms apart for ~1 second ≈ 10 points),
then settles into the existing 1s cadence. The first real data appears almost immediately
(killing the blank window) and each sparkline visibly fills within ~1 second.

## Problem

Two related defects, both rooted in `AppModel`'s open-phase timing
(`Sources/MacStatsApp/MacStatsApp.swift`) and `store.reset()`
(`Sources/MacStatsCore/MetricsStore.swift`):

1. **Blank window (~1–2s).** On close, `setVisibility(.idle)` calls `store.reset()`
   (`cpuPercent = 0`, `memory/network/battery = nil`, all histories `[]`). On reopen,
   `scheduleTimer()` starts a `Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true)`,
   which does **not** fire immediately — the first `tick()` lands a full second later. For
   that ~1s the popover renders the reset state: "0%", "—", and empty charts.

2. **Slow graph build-up.** After the first tick, each sparkline gains only **1 point per
   second** (60-point buffer ⇒ 60s to fill). Early on it is a stub, not a graph.

The menu-bar glyph (`MenuBarLabel.swift`) is intentionally static and is **out of scope**.

## Goals

- No blank/"0%"/"—" flash when the popover opens — real values appear within ~100ms.
- Each sparkline visibly fills with **real** samples within ~1 second of opening.
- After the first second, behavior is unchanged: a real sample once per second.
- Keep the locked decisions intact: fresh sparkline per open session; near-zero cost while
  the popover is closed (no background collection).

## Non-Goals

- No pre-seeded/flat placeholder line (rejected: the user wants real samples).
- No background collection while idle, and no persisting history across opens.
- No new metrics, no view/layout changes, no menu-bar live value.

## Approach

Model the open phase as a **pure, testable rule** in `MacStatsCore`, and have `AppModel`
drive its timer from it. This matches the existing codebase split: refresh timing lives in
`RefreshScheduler.swift` (Core, unit-tested with Swift Testing); `AppModel` stays thin UI
glue.

### Core change — `Sources/MacStatsCore/RefreshScheduler.swift`

Add an open-phase rule plus its tuning constants. Shape (exact names may be refined in the
plan):

```swift
// Open-phase tuning — the single knob for burst feel.
public let burstInterval: TimeInterval = 0.1   // ~100ms between priming samples
public let burstSamples: Int = 10              // ~1s of burst ⇒ ~10 real points
public let steadyInterval: TimeInterval = 1.0  // settled cadence after the burst

/// Interval until the next sample while the popover is open, given how many
/// samples have already been taken since it opened.
public func openPhaseInterval(samplesSinceOpen: Int) -> TimeInterval {
    samplesSinceOpen < burstSamples ? burstInterval : steadyInterval
}
```

`Visibility` and the existing `refreshInterval(for:)` are left untouched (idle still maps to
"timer off"; `.popoverOpen` still maps to the 1.0s steady value), so existing tests stay
green.

### Driver change — `Sources/MacStatsApp/MacStatsApp.swift`

- Track `samplesSinceOpen: Int` on `AppModel`.
- On `.popoverOpen`: set `samplesSinceOpen = 0`, re-baseline `prevCPU/prevNet/prevTime`
  (as today), then start the loop.
- Replace the single repeating `Timer` with a **one-shot timer that reschedules itself**:
  each tick increments `samplesSinceOpen`, collects a sample, then schedules the next
  one-shot timer using `openPhaseInterval(samplesSinceOpen:)`. This naturally produces the
  burst→steady transition.
- On `.idle`: invalidate the timer and call `store.reset()` (unchanged).

### The first sample (why ~100ms, not t=0)

CPU% and network are **deltas** over elapsed time; a sample taken at exactly t=0 has zero
elapsed time and would yield a misleading 0% / 0 B/s (`cpuBusyPercent` guards
`totalDelta > 0`; `networkThroughput` guards `secondsElapsed > 0`). So the first sample
deliberately lands one burst-interval (~100ms) after open — perceptually instant, and a
valid delta. Memory and battery are instantaneous and also appear at ~100ms.

### Rendering

No view changes. Rapid `@Published` updates already drive Swift Charts to redraw; that
redraw *is* the fill animation. The header text "every 1s" describes steady state and stays
as-is.

## Accepted Tradeoff

Burst-phase CPU/network points are measured over ~100ms windows, so they are slightly
noisier than 1s points, and the (already hidden) x-axis mixes 100ms- and 1s-spaced points.
This reads as live activity, is bounded, and is acceptable. `burstInterval`/`burstSamples`
are the single knob if the burst should ever be calmer or faster. CPU resolution is fine at
100ms because `HOST_CPU_LOAD_INFO` ticks are summed across all cores.

## Verification

**Unit tests (Core, Swift Testing — `Tests/MacStatsCoreTests/RefreshSchedulerTests.swift`):**

- `openPhaseInterval(samplesSinceOpen:)` returns `burstInterval` for samples `0..<burstSamples`
  and `steadyInterval` at `>= burstSamples`.
- The burst spans ~1s: `Double(burstSamples) * burstInterval` ≈ `1.0`.
- Existing `idleIsSlow` / `openIsOneSecond` and all `MetricsStoreTests` stay green.

Run via `./Scripts/test.sh` (CLT-only Swift Testing wrapper — not `swift test` directly).

**Manual (human acceptance — `./Scripts/bundle.sh && open MacStats.app`):**

- Open the popover → no blank / "0%" / "—" flash; values appear effectively instantly.
- Each sparkline fills with real points within ~1 second.
- After ~1s, values update once per second as before.
- Close and reopen → fresh sparkline that fills again the same way.
