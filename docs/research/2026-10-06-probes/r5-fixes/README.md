# Review round 5 fixes: probes and results (2026-10-07)

MacStats is a native Swift macOS menu-bar system monitor (this repo). Terms:
- **breakdown**: the per-app list you get by clicking the CPU, Memory or Battery card; an app with several
  processes **expands** into its **process rows** (the first 5 show, then an "N more…" row).
- **scan**: one per-process read for an open breakdown, every 2 s. **window**: the span a row is averaged over
  (CPU 8 s, Battery 16 s).
- **fast attack / release**: the window restarts when one app used ≥ ¾ of a core more (attack) or, since round
  5, less (release) over the latest scan than over the rest of the window.
- **freeze**: the row order isn't changed by a scan while the pointer (once moved) is over the list or a menu is
  open. **Partial freeze** (round 5): with the pointer on a known app's rows, only the apps down to that one keep
  their places; the apps below still re-sort.
- **inversion**: a row printed with a lower number directly above a higher one.
- **pp**: percentage points of the whole Mac (one busy core = 12.5 pp on this 8-core Mac).

All rules, constants and tests: `docs/design/breakdown-stability.md`.

## Files

- `record.swift`: records 5 min of live **scan results** to JSON, attributed exactly like the app's
  `BreakdownScanSession` (`isMacOSAgent` anchors read every scan). Variants: `cpuB8` (fast attack + release),
  `cpuB8slow` (neither), `energyB16`, `memB`. At `BURST_AT` (default 100 s) it runs one `/usr/bin/yes` (one busy
  core) for 16 s and records its pid, start and stop.
- `replay.swift`: feeds a recording through the real `MetricsStore` + `BreakdownDisplay` + `BreakdownList` and
  prints: pointer away (top-8 order changes, inversion scans, slot changes of the first 14 flattened rows, the
  expanded app's visible top-5 process order and set changes, "Finished processes" in the top 2 or printing 0);
  `BURST` lines (the burst app's row, its Finished row and the header, from 2 s before the start to 14 s after the
  stop); and a pointer resting on the 2nd app (moved, so frozen) with the row known (partial freeze) or unknown
  (full freeze): rows at or above the pointer that moved (must be 0).
- `replay-r5.txt`: `replay.swift` on a recording made with `../r4-fixes/load.sh` running from 20 s (a bursty load
  of short-lived `yes` processes, ~0.7 core, inside the expanded app, as under a build).
- `replay-before-after.txt`: the round-4 replay (`../r4-fixes/replay.swift`) on the same recording, compiled
  against the display code before round 5 (`0e59183`) and against round 5.
- `out/`: captures from the tour-render probe (`../tour-render/run.sh`, with `OUT` set to this folder) on the
  round-5 code: tour steps, welcome, chip, footnote fit (`insets.txt`: all `fit … OK`, `failures=0`), and real-scan
  breakdowns (`r2-breakdown-*.png`), plus `r5-breakdown-cpu-expanded-app-ended-*.png` (the expanded app quit while
  frozen: rows below stay put, "N more…" kept disabled) and `r5-breakdown-cpu-hint-*.png` (the new hint).

## Run

```bash
cd /Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats
P=docs/research/2026-10-06-probes/r5-fixes
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
mkdir -p "$TMPDIR/r5/rec" "$TMPDIR/r5/rep"
cp $P/record.swift "$TMPDIR/r5/rec/main.swift"; cp $P/replay.swift "$TMPDIR/r5/rep/main.swift"
# bash, so the file list splits into words (zsh doesn't split an unquoted variable):
bash -c 'CORE=$(ls Sources/MacStatsCore/*.swift | grep -v AppleSensorReader)
  swiftc -sdk '"$SDK"' -O -o "$TMPDIR/r5/record" $CORE "$TMPDIR/r5/rec/main.swift"
  swiftc -sdk '"$SDK"' -O -o "$TMPDIR/r5/replay" $CORE "$TMPDIR/r5/rep/main.swift"'
(sleep 20; exec docs/research/2026-10-06-probes/r4-fixes/load.sh) & L=$!
"$TMPDIR/r5/record" 300 "$TMPDIR/r5/rec.json"; kill $L; pkill -f r4-fixes/load.sh; pkill -x yes
"$TMPDIR/r5/replay" "$TMPDIR/r5/rec.json"
OUT=$PWD/$P/out docs/research/2026-10-06-probes/tour-render/run.sh               # tour + fit
OUT=$PWD/$P/out docs/research/2026-10-06-probes/tour-render/run.sh --breakdowns  # real-scan breakdowns
```

## Results (this Mac, 8 cores, the owner working; recording with `load.sh`)

| Measure | Before round 5 (0e59183 display; reviewers' live runs) | Round 5 |
|---|---|---|
| Header after a one-core load stops (+0 / +2 / +4 s) | 30 / 25 / 23 % (`cpuB8slow`: falls were averaged before round 5; reviewer A live: 18 / 15 / 13 / 10 / 9 over 8 s) | 30 / **12** / 13 % (card: 32 / 17 / 15 %) |
| Burst app's row after the stop (+2 / +4 / +6 / +8 s) | 20 / 15 / 15 / 8.6 % (`cpuB8slow`) | **4.3** / 7.9 / 7.9 / 7.9 % |
| Burst app's row after the start (+2 / +4 s) | 14 / 24 % (fast attack, unchanged) | 14 / 24 % |
| Expanded app (VS Code, ~28 processes), visible top-5 process order changes /min, pointer away | 10.1 (reviewers live: 8–15) | **5.1** |
| Same, visible set changes /min | — | 0.8 |
| Same, scans with a visible process row printed above a higher one (CPU; Battery) | 67/149; 35/149 | 79/149; 25/149 (the trade-off of a 10 s dwell and no inversion timeout under 0.5 %: fewer moves, a held-back order a little more often) |
| "Finished processes" in the top 2 of the expanded app | 13 of 149 scans with round 5's other fixes but ranked like any row (reviewers: often second, at 0.0 %) | **0** (always last) |
| First 14 flattened rows, slot changes /min | 33.0 | **17.2** |
| Top-8 app order changes /min; inversion scans | 1.6; 2/149 | 1.6; 2/149 |
| Pointer resting on the 2nd app (135 frozen scans): rows at or above it moved | 0 | **0** (partial and full freeze) |
| Battery breakdown: expanded app's process order changes /min | 7.5 | 3.6 |
| Memory breakdown footnote scale | 0.88 | **1.00** (all footnotes and the hint 1.00) |

The remaining process-row reorders in this recording are `load.sh`'s two shell loops (1–6 % each, real bursty
work) trading the top two places at most once per 10 s, plus big jumps (a new one-core process moves at once by
design). In this recording the apps below the hovered row didn't need to re-sort, so the partial freeze's benefit
is shown by the unit tests (`aPointerOnAnAppFreezesOnlyDownToIt`, the property test
`frozenKeepsTheShownRowsAsAPrefix` with random partial freezes) rather than by these numbers.

Not measured here (needs the real panel, which the probes never open): hover events and scrolling in a live
`MenuBarExtra` window, and the installed app's closed-panel CPU.
