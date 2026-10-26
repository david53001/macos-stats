# Review round 4 fixes: probes and results (2026-10-07)

MacStats is a native Swift macOS menu-bar system monitor (this repo). Terms:
- **breakdown**: the per-app list you get by clicking the CPU, Memory or Battery card.
- **scan**: one per-process read for it, every 2 s.
- **window**: the span a breakdown row's number is averaged over (CPU 8 s, Battery 16 s).
- **freeze**: the row order stops changing while the pointer (once it has moved) is over the list or a
  context menu is open.
- **inversion**: a row printed with a lower number directly above a row printed with a higher one.
- **reorder dwell**: since round 4, apart from a big jump a list (the apps, or one app's processes) reorders at
  most once per `breakdownReorderDwell` (5 s, so every third scan).
- **fast attack**: since round 4, the window restarts from the latest scan when an app used ¾ of a core more
  over it than over the rest of the window (`breakdownFastAttackCores`), so a new load shows at once.
- **child rows**: an expanded app's process rows.
- **CV**: coefficient of variation, standard deviation ÷ mean (how noisy each simulated reading is).

## Files

- `record.swift`: records 5 min of live **scan results** (`BreakdownScanner` output) to JSON for five variants
  (`cpuB8`, `energyB16` with fast attack; `cpuB8slow`, `energyB16slow` without; `memB`), with macOS's own agents
  folded into "Other processes" like the app (`NOFOLD=1` turns that off). At `BURST_AT` (default 100 s) it runs
  `/usr/bin/yes` for 16 s (one busy core) and records its pid.
- `replay.swift`: feeds a recording through the real `MetricsStore` + `BreakdownDisplay` of the sources it is
  compiled with and prints the steadiness measures, plus `BURST` lines (the `yes` row and header 0–20 s after it
  started). `replay <json> synthetic` instead runs reviewer B's round-4 synthetic contention test: 10 apps with
  close means (6.0 / 5.6 / 5.2 / 3.1 / 2.9 / 1.6 / 1.5 / 1.0 / 0.6 / 0.5 %), bursty per-scan readings (CV 0.6 and
  0.3) averaged over 4 scans, 20 simulated minutes, pointer away.
- `load.sh`: a bursty background load (two loops starting `yes` for 0.1–0.9 s, then sleeping 0.1–1.9 s; about
  0.7 of a core), so the expanded app (VS Code here, whose terminal runs it) has short-lived processes, as under
  a build.
- Results: `synthetic.txt`, `replay-rec2.txt` (recording made with `load.sh` running from 20 s),
  `stability-live.txt` (reviewer B's round-3 live probe, `../r3-fixes/run.sh stability 100`, on the round-4
  code), `cost.txt` (`../r3-fixes/run.sh cost`).
- `out/`: captures from the tour-render probe (`../tour-render/`) on the round-4 code: `step1-light.png`,
  `step4-dark.png` (callout hugs its content), `glide-step1to2-light.png` (frames 0.06 / 0.12 / 0.2 / 0.3 / 0.5 s
  into the step 1 → 2 change: the old callout is gone before the new one fades in), `breakdown-*.png` (real
  scans of this Mac: no macOS agents as app rows), `insets.txt` (spotlight centring, `failures=0`).

## Run

```bash
cd /Users/davidghermansteinberg/Desktop/Home/Projects/Code/Mac Apps/MacStats
P=docs/research/2026-10-06-probes/r4-fixes
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
CORE=$(ls Sources/MacStatsCore/*.swift | grep -v AppleSensorReader)
mkdir -p "$TMPDIR/r4/rec" "$TMPDIR/r4/rep"
cp $P/record.swift "$TMPDIR/r4/rec/main.swift"; cp $P/replay.swift "$TMPDIR/r4/rep/main.swift"
swiftc -sdk $SDK -O -o "$TMPDIR/r4/record" $CORE "$TMPDIR/r4/rec/main.swift"
swiftc -sdk $SDK -O -o "$TMPDIR/r4/replay" $CORE "$TMPDIR/r4/rep/main.swift"
echo '{}' > "$TMPDIR/r4/empty.json"; "$TMPDIR/r4/replay" "$TMPDIR/r4/empty.json" synthetic
# 5 min live recording with the bursty load from 20 s (stop the load afterwards):
(sleep 20; exec $P/load.sh) & L=$!; "$TMPDIR/r4/record" 300 "$TMPDIR/r4/rec.json"; kill $L; pkill -f r4-fixes/load.sh; pkill -x yes
"$TMPDIR/r4/replay" "$TMPDIR/r4/rec.json"
```
(Each file must be compiled as `main.swift`: top-level code is only allowed there.) To compare with older
display rules, compile `replay.swift` against an older `Sources/MacStatsCore` (`git archive <commit> Sources`).

## Results

Synthetic contention (`synthetic.txt`), pointer away:

| Noise | Before (5fd35d0): reorders/min, inversion scans, longest inversion | Round 4 |
|---|---|---|
| CV 0.6 | 23.7, 46 %, 1 scan | 14.3, 68 %, 3 scans |
| CV 0.3 | 14.2, 33 %, 1 scan | 9.4, 55 %, 3 scans |

The dwell trades motion for order: about 40 % fewer reorders, while a row may sit one or two scans (≤ 6 s)
above a higher one before passing it.

Live recording under `load.sh` (`replay-rec2.txt`), CPU, pointer away:

| Measure | Before (5fd35d0) | Round 4 |
|---|---|---|
| Expanded app (VS Code, ~28 processes): top-5 child rows changed, per min | 24.9 | 10.9 |
| First 14 rows (apps + expanded children): slot changes per min | 69.3 | 28.6 |
| One-core burst row at +2 / +4 / +6 / +8 s | 3.1 / 6.3 / 9.4 / 12 % | 12 / 12 / 12 / 12 % |
| Header at +2 s (from 13 %) | 16 % | 28 % |
| Battery burst row at +2 s | 0.48 W (16 s ramp to 3.9 W) | 3.9 W |
| Top-8 app order changes per min; inversion scans | 0.6; 2/149 | 0.6; 2/149 |
| Row text changes per min (flip-backs) | 17.2 (1.8) | 17.0 (2.0) |

Live probe (`stability-live.txt`, reviewer B's measures, light load): CPU top-8 order changes 2.5/min, 0/49
inversion scans; frozen: 0 rows moved, inserted or removed. Cost (`cost.txt`): CPU scan p50 17.1 ms (was 17.6),
open overview 11.9–12.1 % of a core with the tour off (was 12.0–12.2), 12.8 % on step 1 (was 12.4: noise).
