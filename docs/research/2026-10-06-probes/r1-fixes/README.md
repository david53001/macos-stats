# Review round 1 fixes: off-screen checks (2026-10-06)

Checks three fixes from review round 1 (`docs/reviews/2026-10-06-stability-tour-review-r1-A.md`, `…-r1-B.md`)
with MacStats's **real** SwiftUI views, in windows at `CGWindowLevelForKey(.desktopWindow) + 1`, ordered back,
never activated, closed right after. Clicks are synthetic mouse-down/up events delivered to the hit view (no
real pointer is moved). Tour state uses a throwaway `UserDefaults` suite, deleted at the end.

```bash
cd /Users/davidghermansteinberg/Desktop/Home/Projects/Code/Mac Apps/MacStats
docs/research/2026-10-06-probes/r1-fixes/run.sh     # ~40 s build + ~10 s run; writes out/report.txt + PNGs
pgrep -fl Probe                                      # should print nothing afterwards
```

| Check | What it does | Result |
|---|---|---|
| Ended child keeps its place | Expands the first app (synthetic click on its row Button), freezes the list (`setBreakdownPointerInside(true)`), then removes one child from the next scan | PASS light + dark: order unchanged, the row reads "Ended", dimmed (`out/breakdown-ended-child-*.png`) |
| Tour click-through | Tour on step 1: click the Battery card (under the dim), then the CPU card (in the cutout) | PASS: the dim click does nothing, the cutout click reaches the CPU card's `onSelect` |
| Why `.onHover` comes first | A plain even-odd dim over the overview with the CPU card's hole, 4 modifier orders | `.onHover` **after** `contentShape(_, eoFill: true)` blocks the hole (variant 1); before it, clicks pass (variant 3, what `TourOverlay` does) |
| Pointer probe | Places a breakdown window so the list is under the real (resting) pointer, then far from it, and reads `store.breakdownPointerProbe` | PASS: inside = true, away = false |

The first run of the tour check **failed** (the click in the cutout did nothing) because `TourOverlay` had
`.onHover` after the content shape; the variant table above found why, and the fix moved it.

## CPU card hold band (`card-band.swift`)

Headless: records one live CPU series (0.5 s ticks, the app's 2 s trailing window) and replays it through
`heldValue` with several bands, so every option sees the same data.

```bash
cd /Users/davidghermansteinberg/Desktop/Home/Projects/Code/Mac Apps/MacStats
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -O -o "$TMPDIR/card-band" \
  $(ls Sources/MacStatsCore/*.swift | grep -v AppleSensorReader) docs/research/2026-10-06-probes/r1-fixes/card-band.swift
("$TMPDIR/card-band" 90 & PID=$!; (sleep 130; kill $PID) & wait $PID)
```

Result (177 ticks, whole Mac 13.6 % mean):

| Hold | Changes / min | Flip-backs (A→B→A) | Max error |
|---|---|---|---|
| band 0.75 (round 1) | 56.9 | 9 | 0.73 pp |
| band 1.00 | 48.1 | 5 | 0.95 pp |
| **band 1.25 (now)** | **41.4** | **4** | **1.24 pp** |
| band 1.50 | 38.6 | 6 | 1.46 pp |
| band 1.0 + at most one change a second | 37.3 | 6 | 8.71 pp |

Wider bands give little more: most remaining changes are the CPU really moving by more than a point. A
minimum gap between changes lags real jumps by up to 8.7 pp, so it was rejected; 1.25 stays within the
reviewers' "≤ about 1.25 pp" bound.

## Re-running reviewer B's stability probe on the fixes

Reviewer B's probe (`docs/reviews/2026-10-06-stability-tour/r1-B/probe-src/reviewB-main.swift`) built unchanged
against the current sources (copy `Sources/MacStatsCore`, `CAppleSensors` and `Sources/MacStatsApp/*.swift`
minus `MacStatsMain.swift` into a scratch package with its `Package.swift`, as in its README), then
`ReviewBProbe out inv 60` (nothing expanded) and `ReviewBProbe out stability 70` (an app expanded, the pointer
resting in the list for 20 s). Raw output: `reviewB-probe-unpinned.txt`, `reviewB-probe-pinned.txt`.

| Measure | Round 1 (B) | Now |
|---|---|---|
| CPU scans with a visibly mis-sorted top 8 | 8 / 18 (worst 4.3 % under 0.4 %) | 2 / 18 and 2 / 23 (worst gap 0.64 pp) |
| Battery scans mis-sorted | 16 / 19 (0.17 W under 0.00 W) | 2 / 19 and 2 / 19 (worst gap 0.049 W) |
| Memory scans mis-sorted | 0 / 19 | 0 / 19 |
| Row under a resting pointer changed (20 s) | CPU 1 + 1, Battery 1 | 0, 0, 0 |
| "Exited processes" row toggles | 4–9 in ~35 s | 0–1 (its first appearance) |
| CPU top-8 order changes / min | 9.4–12.2 | 2.7–5.2 |
| CPU card changes / min | 37–74 | 27–50 (load varies; same-series comparison above) |
| Card CPU vs raw | ≤ 0.75 pp | ≤ 1.23 pp, 0 ticks ≥ 2 pp |

The repo's own probe (`docs/research/2026-10-06-probes/stability/run.sh 90 Code`): top-8 order changes 7.3 / min,
target child-set changes 0, frozen slot changes 0, scan 7.45 ms/s, probe process 0.67 % of a core.

> **Note (review round 2):** `main.swift` here targets the round-1 API (`breakdownPointerProbe` returning a
> `Bool`). Since round 2 it returns a `BreakdownPointer` (`inside`, `moved`), so this probe no longer builds
> against HEAD; it is kept as the record of round 1. Round 2's probes: `../r2-fixes/`.
