# Review round 3 fixes: live probe and record/replay harness

MacStats is a native Swift macOS menu-bar system monitor (this repo). Terms:
- **breakdown**: the per-app list you get by clicking the CPU, Memory or Battery card.
- **scan**: one per-process read for it. Since round 3: at 0 s ("Measuring…"), then every 2 s.
- **freeze**: the row order stops changing while the pointer (once it has moved) is over the list or a
  context menu is open.
- **inversion**: a row printed with a lower number directly above a row printed with a higher one
  (reviewer B's measure: any printed difference counts).
- **window**: the span each row's number is averaged over (CPU 8 s, Battery 16 s since round 3; was 4 s).

## Files

- `main.swift`, `Package.swift`, `run.sh`: reviewer B's round-3 probe
  (`docs/reviews/2026-10-06-stability-tour/r3-B/probe-src/`), unchanged apart from the second scan's delay. It
  builds a checkout's real `MacStatsCore` + `MacStatsApp` views in `$TMPDIR/macstats-r3-probe` and runs headless:
  - `run.sh stability 100`: CPU / Memory / Battery breakdowns on this Mac's live processes, pointer away, on the
    list (frozen) and resting from the click; two `sleep`s at 25 s and a busy `yes` at 45–51.5 s.
  - `run.sh synthetic`: an expanded app gains a process while frozen (round 3's insert bug).
  - `run.sh cost`: the overview's render cost at the open cadence and the CPU scan's time.
  `SRC_ROOT=<checkout>` measures another checkout (e.g. `git archive b24ae7c Sources | tar -x -C <dir>`).
- `after-run1.txt` (energy over 8 s), `after-run2.txt` (final: energy over 16 s), `cost.txt`: results.
- `replay/record.swift` + `replay/replay.swift`: records live **scan results** (`BreakdownScanner` output) for
  several schedules/windows to JSON, then replays them offline through the real `MetricsStore` +
  `BreakdownDisplay`, so display rules can be compared on identical data. Results: `replay/head-rec1.txt`
  (HEAD before round 3 on recording 1), `replay/final-rec2.txt`, `replay/final-rec3.txt` (final code).

## Run

```bash
cd /Users/davidghermansteinberg/Desktop/Home/Projects/Code/Mac Apps/MacStats
P=docs/research/2026-10-06-probes/r3-fixes
$P/run.sh synthetic
$P/run.sh stability 100 > /tmp/r3.txt        # ~35 s build + 100 s
# Record 5 min of scan results (edit the `variants` list in record.swift to pick schedules/windows):
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
CORE=$(ls Sources/MacStatsCore/*.swift | grep -v AppleSensorReader)
swiftc -sdk $SDK -O -o "$TMPDIR/rec" $CORE $P/replay/record.swift && "$TMPDIR/rec" 300 "$TMPDIR/rec.json"
swiftc -sdk $SDK -O -o "$TMPDIR/replay" $CORE $P/replay/replay.swift && "$TMPDIR/replay" "$TMPDIR/rec.json"
```

## Results

Live, reviewer B's probe (same Mac, light load). Round 3 = B's `stability-run3.txt` at `b24ae7c`.

| Measure | Round 3 | After (`after-run2.txt`) |
|---|---|---|
| CPU list, pointer away: top-8 order changes/min | 6.1–14.7 | 3.1 |
| CPU list: scans with an inversion in the top 8 | 20/45 | 1/49 |
| Still pointer: top row changed at | 2.5 s (every run), then 6–7 more | 48 s, 60 s (the busy `yes`) |
| Battery list, away: order changes/min (flip-backs) | 4.9–15.0 (5.5–8.9) | 0.6 (3.1) |
| Battery list: inversion scans | — | 1/49 |
| Frozen (pointer moved onto the list): rows moved / inserted / removed / collapses | 0/0/0/0 | 0/0/0/0 in 60 scans |
| Synthetic: frozen expanded app gains a process | row inserted, rows below shift 36 pt | nothing moves |
| CPU card text changes/min | 22–45 | 16–21 |
| CPU card held vs exact, max | 2.0 pp | 3.0 pp |
| Overview render cost (probe, % of a core) | 11.6 | 12.0–12.4 (noise; no render change) |
| CPU scan, ms p50 | ~17 | 17.6 |

Replay (identical recorded scans, CPU, pointer away). `cpuB` = the old 4 s window without the inversion
timeout, `cpuB8` = final:

| Measure | 4 s, margins only | 8 s + inversion timeout |
|---|---|---|
| Top-8 order changes/min | 5.1 | 3.6 (1.2 on recording 3) |
| Inversion scans | 83/149 | 10/149 (5/149) |
| Seconds between a row's text changes | 15 | 35 (24) |
| Expanded app: row moves/min | 4.7 | 2.8 (0.6) |
| Expanded app: top-5 process order changes/min | 4.3 | 4.1 (9.7, a build was running in it) |

Battery replay (recording 3): 8 s window 6.7 order changes/min and 36/149 inversion scans; 16 s window 0 and 0.

Cost: the longer windows keep 4 (CPU) or 8 (Battery) intervals of ~500 per-process entries while that breakdown
is open (~100–200 KB, freed when it closes); the CPU scan's time is unchanged (17.6 ms p50).
