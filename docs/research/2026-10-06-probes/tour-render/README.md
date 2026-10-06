# Tour render probe (off-screen)

Renders MacStats's **real** SwiftUI views (overview, tour overlay, callout, welcome card, offer chip,
Settings, breakdowns) with a fake `MetricsStore`, captures them as 2× PNGs, and **measures that the tour's
spotlight is centred** on every step. Nothing appears in front of you: every window sits at
`CGWindowLevelForKey(.desktopWindow) + 1`, is ordered back, never activated, and closed right after its
capture. Tour state lives in throwaway `UserDefaults(suiteName: "MacStatsTourProbe-<uuid>")` suites that are
deleted at the end; the real `com.macstats.MacStats` defaults are never read or written.

## Run

```bash
cd /Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats
docs/research/2026-10-06-probes/tour-render/run.sh            # captures + out/insets.txt (~60 s)
docs/research/2026-10-06-probes/tour-render/run.sh --cost     # CPU: 20 s tour off, then 20 s on step 1
docs/research/2026-10-06-probes/tour-render/run.sh --no-tour  # CPU: 20 s with .tourHost left out
pgrep -fl Probe                                               # should print nothing afterwards
```

`run.sh` copies the **current** `Sources/MacStatsCore`, `Sources/CAppleSensors` and
`Sources/MacStatsApp/*.swift` (minus `MacStatsMain.swift`, the `@main`) plus `main.swift` into
`$TMPDIR/macstats-tour-probe`, builds it there (release, SDK pinned to `MacOSX26.5.sdk`), and runs it under
a 150 s kill timeout. Nothing is built inside the repo.

## What it checks

- **Centring** (`out/insets.txt`, one `step=` line per step, light and dark): the probe captures the overview
  once without the tour and once per step with it, in the same window with static data. Along the row through
  the target's vertical centre and the column through its horizontal centre it walks outward from the target's
  edge (the anchor rect the overlay itself resolves, × the capture scale):
  - `inner` = pixels identical to the capture without the tour = the clear gap between card and ring;
  - `outer` = `inner` + the accent-coloured run = the ring's outer edge = the cutout's edge.
  Pass: |L − R| ≤ 1 px and |T − B| ≤ 1 px for both, outer = 3 pt ± 1 px, and the callout (frame computed by
  `TourLayout.callout` from the callout's measured height) doesn't overlap the cutout. Expected at 2×:
  `inner 2 2 2 2` (1 pt gap) and `outer 6 6 6 6` (3 pt).
- **Fit**: each step body in the callout's font at 280 pt takes ≤ 2 lines; each breakdown footnote fits one
  line beside "Quit MacStats" at a scale ≥ 0.8 (its `minimumScaleFactor`).
- **Cost**: process CPU (`getrusage`) while the overview records a sample every 0.5 s.

## Results (2026-10-06, commit after `a8be945`)

All 12 step measurements pass, light and dark, including the footer on a Mac without a battery ("4 of 4"):
`inner L=R=T=B=2 px`, `outer L=R=T=B=6 px`; cutout = card + 3 pt on every side, radius 11 (card 8, panel 16,
concentric); callout 304 × 108 pt, 6 pt from the cutout, below for CPU / Memory / Network and above for Battery
and the footer. Bodies: 2 lines each. Footnotes: scale 1.00 / 0.88 / 0.91 / 1.00 (CPU, Memory, Battery, hint).

First run found one real defect, fixed before commit: in light mode the callout's shadow (radius 12, y 4)
darkened the gap above a card when the callout sat above it (T = 0 px on Battery and the footer). The callout
is now masked by the same even-odd shape as the dim, so its shadow never falls into the hole.

Cost (% of one core, the probe process rendering the overview off-screen at the open cadence; the absolute
level is the probe's own rendering, the comparison is what matters):

| Run | tour off | tour on (step 1) | `.tourHost` left out |
|---|---|---|---|
| 1 | 14.13 | 16.30 | 15.15 |
| 2 | 15.01 | 15.22 | 15.08 |

Tour off matches the build without the tour host within noise; the overlay costs only while it is shown.

## Captures (`out/`)

`overview-*`, `step1..5-*`, `step1-opacity0-*`, `step1-opacity1-*` (Opacity setting 0 and 1),
`nobattery-step4-*` (footer as "4 of 4"), `welcome-*`, `chip-*` (existing user's offer), `settings-help-*`,
`breakdown-hint-cpu-light` (quit hint footnote, one number per row), `breakdown-memory-light` (one-line
footnote), `trash-permission-light` ("Needs permission" + "Allow…"). Light and dark where named `-*`.

Limits: windows of a process that can't become active render as inactive (system controls such as the
slider look inactive; the tour's own buttons are custom and unaffected). The `MenuBarExtra` Liquid Glass and
its Opacity hook aren't present off-screen (an `NSVisualEffectView(.popover)` stands in), and hover/keyboard
can't be driven without activating the window: those are the owner's manual checks in
`docs/superpowers/plans/2026-10-06-stability-tour-progress.md`.
