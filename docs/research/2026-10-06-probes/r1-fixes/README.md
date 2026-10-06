# Review round 1 fixes: off-screen checks (2026-10-06)

Checks three fixes from review round 1 (`docs/reviews/2026-10-06-stability-tour-review-r1-A.md`, `…-r1-B.md`)
with MacStats's **real** SwiftUI views, in windows at `CGWindowLevelForKey(.desktopWindow) + 1`, ordered back,
never activated, closed right after. Clicks are synthetic mouse-down/up events delivered to the hit view (no
real pointer is moved). Tour state uses a throwaway `UserDefaults` suite, deleted at the end.

```bash
cd /Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats
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
cd /Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats
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
