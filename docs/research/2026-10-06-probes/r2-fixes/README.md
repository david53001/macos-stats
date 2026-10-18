# Review round 2 fixes: stability probe and row-hold replay

MacStats is a native Swift macOS menu-bar system monitor (this repo). Terms:
- **breakdown**: the per-app list you get by clicking the CPU, Memory or Battery card.
- **scan**: one per-process read for it, at 0 s, 0.5 s, then every 2 s.
- **freeze**: the row order stops changing while the pointer is over the list or a context menu is open.
- **held value**: the number a row or card prints. It changes only when the reading moves clearly.
- **pp**: percentage points of the whole Mac.
- **mis-sorted pair**: the round-2 reviewers' measure. A row printed more than 25 % *and* more than 2 printed
  steps above the row directly above it.

## Files

- `main.swift` + `run.sh`: a headless stability probe adapted from reviewer B's round-2 probe
  (`docs/reviews/2026-10-06-stability-tour/r2-B/probe-src/stability-main.swift`), plus reviewer A's "still
  pointer" case. It compiles a checkout's `Sources/MacStatsCore` (minus `AppleSensorReader.swift`) into
  `$TMPDIR/macstats-r2-probe` and runs four breakdowns on this Mac's live processes at the app's cadence:
  - `cpu`, `memory`, `energy`: the pointer is outside, then *moved onto* the list for 20 s, then outside again.
    The app with the most processes is expanded early and stays expanded.
  - `still`: CPU, with the pointer resting on the list from the moment it opens and never moving.
  It also runs the overview cards at 0.5 s ticks. There is no window and no UI.
- `before-66141b1.txt`: the code before the fixes (`R2BASE=1`, a source snapshot of `66141b1`).
- `after-run1.txt`: an intermediate version that still ranked on exact values. `after-run2.txt` and
  `after-run3.txt`: the committed version. Run 3 had a busier Mac (28 % mean CPU vs 11 %).
- `row-hold-replay.swift` + `.txt`: the same synthetic noisy series (100 min of 2 s scans, a real level change
  every 10 min) through the old row hold (`heldValue`) and the new one (`HeldReading`, two-scan confirmation).

## Run

```bash
cd /Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats
docs/research/2026-10-06-probes/r2-fixes/run.sh 150 > /tmp/r2.txt     # ~15 s compile + 150 s
# The code before the fixes, from a source snapshot:
mkdir -p "$TMPDIR/r2base" && git archive 66141b1 Sources | tar -x -C "$TMPDIR/r2base"
SRC_ROOT="$TMPDIR/r2base" R2BASE=1 docs/research/2026-10-06-probes/r2-fixes/run.sh 150
# Row-hold replay:
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -O -o "$TMPDIR/replay" \
  $(ls Sources/MacStatsCore/*.swift | grep -v AppleSensorReader) docs/research/2026-10-06-probes/r2-fixes/row-hold-replay.swift
"$TMPDIR/replay"
```

## Results

| Measure | Before (`66141b1`) | After, run 2 | After, run 3 (busier) |
|---|---|---|---|
| Still pointer: mis-sorted scans | **44/75** (order frozen at the 0.5 s scan) | **4/75** | **0/75** |
| CPU: mis-sorted scans (pointer outside) | 31/65 (30 next to the pinned row) | 4/65 | 0/65 |
| Energy: mis-sorted scans | 16/65 | 8/65 | 0/65 |
| Memory: mis-sorted scans | 0/66 | 0/66 | 0/66 |
| Row moves while pointing (moved onto the list) | 0 | 0 | 0 |
| Expanded app auto-collapses | 0 | 0 | 0 |
| CPU card text changes/min (flip-backs) | 34.8 (4.8) | 26.8 (2.8) | 31.6 (3.2) |
| CPU card: shown vs exact, max pp | 1.23 | 1.84 | 1.97 |
| Network ↓ / ↑ card changes/min | 20.8 / 21.6 | 6.8 / 8.4 | 16.0 / 15.6 |
| Network ↓ / ↑ flip-backs/min | 6.8 / 2.8 | 1.2 / 1.6 | 1.6 / 3.2 |
| CPU top-8 order changes/min (pointer outside) | 1.9 (pin + 25 % margin) | 10.6 | 9.2 |
| Probe process CPU, % of one core (4 breakdowns + overview) | 1.01 | 0.93 | 1.00 |

Run 2's 4 + 8 remaining pairs were all exactly 2 printed steps apart (0.1 % vs 0.3 %, 0.03 W vs 0.05 W). That is
what made `abs` 1.5 steps instead of 2. Run 3 is that version: 0 pairs.

Row text: the live counts move with machine load (CPU rows: 3.9 flip-backs/min before, 6.8 and 11.6 after,
on a 2.5× busier Mac). So the effect of the two-scan confirmation is measured on a fixed series instead
(`row-hold-replay.txt`):

| Series (CPU row) | Changes/min old → new | Flip-backs/min old → new | Max shown-vs-exact, pp old → new |
|---|---|---|---|
| 1 % ± 20 % | 21.5 → 15.6 | 3.36 → 3.12 | 0.14 → 0.31 |
| 3 % ± 15 % | 18.9 → 11.4 | 1.54 → 1.22 | 0.43 → 0.89 |
| 6 % ± 10 % | 14.8 → 6.5 | 1.04 → 0.36 | 0.81 → 1.77 |
| 15 % ± 10 % | 14.4 → 6.5 | 3.66 → 1.51 | 2.00 → 3.98 |

The cost is that a row's text can trail by up to twice its hold for one 2 s scan. The stored readings, bars and
alerts stay exact.

The more frequent order changes (≈ 10 a minute vs 2) are the point of the fix. Before, the pinned row and the
25 % margin kept the list visibly out of order. Now the order follows the printed numbers, the reorders slide
(`.snappy` animation), and nothing moves under a pointer that has moved onto the list.
