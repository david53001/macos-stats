# Stability probe (headless)

> **Superseded for breakdown measures (2026-10-07).** This probe predates the macOS-agent grouping, the
> pointer probe and expanded-app order measures: its scan copy omits `isMacOSAgent`, it never sets
> `breakdownPointerProbe`, it counts the expanded app's processes as a set (so it can't see them reorder),
> and it doesn't count inversions. Use `../r5-fixes/` (record/replay through the real display code and
> `BreakdownList`) for the breakdown; this one is kept for the card measures and the earlier rounds' numbers.

**What it is:** a small command-line program that runs MacStats's **real** `MacStatsCore` code with no window
and counts how often what a user would *read* changes: the order of the CPU breakdown's rows, the row numbers,
the expanded app's processes, and the overview cards' numbers. It measures the "jumpiness" fixed in Part A of
`docs/superpowers/plans/2026-10-06-stability-tour-plan.md` (diagnosis: `docs/research/2026-10-06-stability-diagnosis.md`).

MacStats is a native Swift macOS menu-bar system monitor (this repo). Terms: a **breakdown** is the per-app list
you get by clicking the CPU card; a **scan** is one per-process read for it; **pp** = percentage points of the
whole Mac (100 % = all cores).

## How it works

`main.swift` is compiled together with `Sources/MacStatsCore/*.swift` (minus `AppleSensorReader.swift`, which
needs a C shim) into `$TMPDIR/macstats-stability-probe/probe` (never into the repo). It:

- copies the app's `BreakdownScanSession.scan` (`Sources/MacStatsApp/MacStatsApp.swift`): `NSWorkspace`
  running apps → `attributionAnchors`, then `readRawProcesses`, then `BreakdownScanner.scan`;
- feeds a real `MetricsStore` (`beginBreakdown(.cpu)`, then `setBreakdown`) at the app's cadence: a scan at
  start, one after `breakdownFirstRescanDelay` (0.5 s), then every `breakdownScanInterval`;
- runs the overview path every 0.5 s (counter snapshots + `rateBaselineIndex(window: rateWindowSeconds)` +
  `store.record`);
- pins the target app the whole run (as if the user had expanded it), and between 35 s and 55 s of a 90 s run
  calls `setBreakdownPointerInside(true)` (as if the pointer were over the list).

`-D BASELINE` builds the same file against a checkout from **before** the stability work (`1ed61cf`): shown
values are the raw ones, and there is no freeze, pin or hold. That is how the "before" numbers below were made.

## Run it

From anywhere (it `cd`s to the repo root; takes ~10–20 s to compile, then the run):

```bash
docs/research/2026-10-06-probes/stability/run.sh 90 Code        # 90 s, target app "Code" (VS Code)
# Before the stability work, from a throwaway worktree:
git worktree add --detach "$TMPDIR/macstats-baseline" 1ed61cf
SRC_ROOT="$TMPDIR/macstats-baseline" BASELINE=1 docs/research/2026-10-06-probes/stability/run.sh 90 Code
git worktree remove "$TMPDIR/macstats-baseline"
```

The second argument names the target app (its `localizedName`); if it isn't running, the app with the most
processes is used. The probe runs under a kill timeout (seconds + 40). It opens no window.

## What each number means

All "per minute" figures cover the breakdown scans **outside** the 20 s pointer window (and the scan right
after it), normalised to one minute. Card figures cover the whole run.

| Key | Meaning |
|---|---|
| `top8_order_changes` | Scans whose top-8 app order differs from the previous scan. |
| `slot_changes` | Σ over the 8 visible slots of "a different app than last scan". |
| `row_text_changes` | Σ over the top-8 apps of their printed value (`breakdownValueText` of the shown value) changing. |
| `target_moves` | Times the target app's row index changed (it is pinned, so this should be 0). |
| `target_child_set_changes` | Times the *set* of the target's first 5 process rows changed. |
| `frozen_slot_changes` | Total slot changes during the 20 s pointer window, not counting apps that quit. Must be 0. In the baseline nothing freezes, so this is just its normal churn in the same 20 s. |
| `card_cpu_changes` / `card_net_down_changes` / `card_mem_changes` | Changes of the CPU card text ("12%"), the network card's ↓ text, and the memory card's used GB. |
| `scan_ms_mean` / `scan_ms_max` / `scans_per_s` / `scan_ms_per_s` | Wall time of one whole scan, and scan time per second. |
| `scan_parts_ms_mean` | One scan split into: the running-apps list (`NSWorkspace`, LaunchServices), the process read, `BreakdownScanner.scan`, and `MetricsStore.setBreakdown` (the new stable ranking + holds run here, on the main thread in the app). |
| `process_cpu_pct` | The probe's own CPU (user + system) ÷ wall time, % of one core. |
| `max_sum_gap_pp` | Largest \|Σ shown rows (incl. System) − shown header\|, in pp. Exact sums are unchanged; this is the display holds' rounding. |
| `whole_mac_cpu_mean` | Mean whole-Mac CPU % during the run, so a reader can judge how busy the Mac was. |
| `sample t=… row_pct_mac=… one_core_pct=…` | Every ~10 s: the target's (windowed) row, as % of the Mac and × cores (Activity Monitor's "% of one core"). |

## Results (2026-10-06, M3 MacBook, 8 cores; the owner was working, other agent sessions ran)

Raw output of every run: `results-2026-10-06.txt`. "Before" = `1ed61cf`; "after" = `feat/stability-tour` at
`e95b290` (Part A tasks A1–A5).

| Per minute | Before (2 runs) | After (4 runs) | Must be |
|---|---|---|---|
| `top8_order_changes` | 60.0, 59.1 | 10.9, 10.0, 14.5, 10.0 | ≤ 15 |
| `slot_changes` | 311.6, 275.8 | 22.7, 30.9, **41.8**, 30.0 | ≤ 40 |
| `row_text_changes` | 360.9, 391.4 | 66.4, 68.2, 121.8, 80.0 | ≤ 130 |
| `target_moves` | 28.7, 40.3 | 0, 0, 0, 0 | — |
| `target_child_set_changes` | 26.0, 26.0 | 0, 1.8, 1.8, 0 | ≤ 2 |
| `frozen_slot_changes` (20 s total) | 98, 94 (nothing freezes) | 0, 0, 0, 0 | 0 |
| `card_cpu_changes` | 87.3, 90.7 | 38.7, 44.7, 65.3, 62.7 | ≤ 75 |
| `card_net_down_changes` | 45.3, 48.7 | 10.7, 14.0, 22.7, 14.7 | ≤ 30 |
| `card_mem_changes` | 19.3, 24.7 | 4.7, 4.7, **20.0**, 10.7 | ≤ 16 |
| `max_sum_gap_pp` | 0.00 | 1.00, 1.00, 1.10, 0.80 | ≤ 2 |
| Scan time per second, whole scan (ms/s) | 14.5, 14.9 | 7.0, 6.4, 7.1, 7.7 | ≤ before |
| …without the running-apps list: process read + scanner + store (ms/s) | 4.2, 4.2 | —, 2.1, 2.4, 2.6 | ≤ ~3 |
| `process_cpu_pct` (whole probe, % of one core) | 1.11, 1.09 | 0.63, 0.56, 0.64, 0.69 | ≤ before |
| `whole_mac_cpu_mean` (how busy the Mac was) | 12.1, 15.4 | 8.8, 9.2, 16.8, 12.5 | — |

Notes:

- **Run 3 was the busiest** (whole Mac 16.8 % mean, header up to 24 %; `top` ran inside it for the spot-check
  below, and the agent's own processes are attributed to VS Code because the agent runs in its terminal). Its
  slot changes (41.8) and memory-card changes (20.0) are just over the limits; the other three runs meet every
  limit. These are real load and memory changes (memory moved by ≥ 0.1 GB that often), not noise, so the holds
  were left at the plan's values rather than widened at the cost of accuracy.
- **Scan cost:** the plan's "≤ ~3 ms/s" came from the diagnosis's 4.2–5.5 ms per scan, which did not include the
  running-apps list (`NSWorkspace.runningApplications`, ~9–10 ms per scan here because LaunchServices is asked
  again after each run-loop turn). Same-probe comparison: the whole scan costs about half what it did per second
  (2 s scans instead of 1 s), and the comparable part is 2.1–2.6 ms/s against 4.2 ms/s before. The new
  `setBreakdown` work (stable ranking of ~60 apps and their processes, holds) is ~0.4–0.5 ms per scan, i.e.
  ~0.2 ms/s on the main thread, and only while a breakdown is open.
- Nothing here runs while the popover is closed: the scan, the ranking and the holds exist only while a
  breakdown is open (`AppModel.enterBreakdown` / `exitBreakdown`).

### Accuracy spot-check (Activity Monitor scale, % of one core)

During runs 1 and 3, `top -l 3 -s 2 -o cpu -stats pid,command,cpu` (samples 2–3, 2 s each; listed at the end of
`results-2026-10-06.txt`) showed for the VS Code family: Code + Code Helpers 0.7–1.4, the agent CLI `2.1.291`
(a VS Code terminal process, so MacStats attributes it to Code) 1.2–2.6, the probe 0.2–0.6, and `top` itself
3.5–4.0 (also started from that terminal). Family total: 2.8–4.0 without `top`, 6.3–8.0 with it. The probe's
windowed Code row in the `sample` lines nearest those seconds read 4.6 (run 1, t = 41 s) and 6.3 (run 3,
t = 51 s) % of one core, i.e. inside that range; run 3's t = 41 s line read 14 %, a burst that the 4 s window
caught and top's 2 s samples did not. The alignment is approximate (the probe prints every ~10 s, top sampled
~4 s, and processes under 0.05 % print as 0.0 in top), so this is a sanity check only: the rows are in the same
range as `top`'s figures. The window arithmetic itself is exact and unit-tested
(`Tests/MacStatsCoreTests/ProcessScanTests.swift`, suite `BreakdownWindowTests`), and attribution is unchanged
from `1ed61cf`.
