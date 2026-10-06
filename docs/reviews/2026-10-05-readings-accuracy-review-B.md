# MacStats readings accuracy review — 2026-10-05
**Overall: 7/10** — A great app with one real bug. CPU, memory and network match Apple's own numbers to within measurement noise. Work started in VS Code's built-in terminal (including Claude Code, `yes` loads and a build-like burst of short-lived processes) lands on the right app. The battery time left on battery came within 3 % of a forecast from the measured drain, which is closer than macOS's own figure (10 h 45 m against 8 h 51 m measured). Health, cycle count and temperature are exact, and the app costs almost nothing while closed. What stops it at 7 is **time to full while charging**. The formula has a cliff at 80 %: at 79 % it predicts 60 min to full, and one percent later it predicts 26 min. Above 80 % it treats the shrinking charge current as constant, so it likely reads about half the real time. This is a High issue in a primary battery reading (shown deterministically with the shipped function; not verified on a live charge). Smaller issues: when processes exit without a surviving parent to reap them, their last second of work is shown as "System"; "Power now" can be a minute stale; and the cost of an *open* popover could not be measured here. Fixing the time-to-full model and relabelling the System row would put this at 8.

**Standard:** Activity Monitor / System Settings / battery gauge parity · **Method:** code analysis + live measurement · **Reviewer:** independent subagent (reviewer B)

## Calibration
- **Type & platform:** native macOS 14+ menu-bar app (SwiftUI `MenuBarExtra`, IOKit / Mach / libproc), Apple Silicon first. It has to degrade gracefully on Intel Macs, on other M-chips and on desktops without a battery.
- **Audience:** the owner (daily) and public GitHub users who compare its numbers with Activity Monitor and System Settings, and who use it to find what is eating their CPU, RAM and battery.
- **Reference for a 10:** every number equals Apple's own readout within noise, attribution matches Activity Monitor / iStat Menus, units can't be misread, estimates are honest against measured drain or charge, edge states behave, and overhead is negligible.
- **Anchors:** 3 = a primary reading badly wrong · 6 = roughly right with noticeable gaps (for example, time to full unreliable) · 9 = within noise everywhere, only nitpicks.
- **Scale:** 8–10 basically perfect · 4–7 great, with noticeable issues · 1–3 not to standard. An area with a High issue can't score 8+.

**Terms used below**
- **Physical footprint:** the memory the kernel charges to a process (its own dirty and compressed pages). This is Activity Monitor's "Memory" column; `footprint -p <pid>` prints it.
- **Memory Used** (Activity Monitor) = App Memory (anonymous pages minus purgeable pages) + Wired + Compressed.
- **Responsible process:** the app macOS holds accountable for a process (Terminal for a tab's shell, an app for its XPC helpers). Read with `responsibility_get_pid_responsible_for_pid`.
- **Reaped:** when a process exits, its parent "reaps" it, and the kernel then adds the child's CPU time to the parent's "child time". If the parent died first, launchd reaps the orphan.
- **Gauge:** the battery's fuel-gauge chip, read through `ioreg -rn AppleSmartBattery`. It reports values in **mAh** (milliamp-hours, charge) and mV / mA. Watts = volts × amps.
- **SystemLoad:** the gauge's whole-Mac power telemetry, in mW. `AccumulatedSystemLoad` / `SystemLoadAccumulatorCount` is a running sum that gives the exact average power between two readings.
- **CC / CV charging:** a charger first holds a constant current (CC). Near full it holds a constant voltage (CV) while the current decays toward a cut-off.

## Scoreboard
| Area | Score | Verdict (one line) |
|---|---|---|
| Battery | **7/10** | All gauge readings and the on-battery time left are excellent; time to full has a 2× cliff at 80 % and likely reads short above it (High, not live-verified). |
| CPU | **8/10** | Header, per-process values and terminal / IDE / helper attribution match `top` exactly; exited orphan work briefly shows as "System". |
| Memory | **9/10** | Card equals the Activity Monitor formula to 0.01 GB; per-process footprints match `footprint` to the MB. |
| Overhead | **7/10** | Closed: 0.03 % of one core and 13 MB (excellent). The open-popover cost and the idle cost after a first open could not be measured; the project's own notes report 12–17 % and ~1 % of a core. |
| Network | **9/10** | 64-bit counters match `netstat -ib` byte for byte. |

Weighting: Battery, CPU and Memory dominate; Network is minor. The battery High issue caps the overall score at 7.

---

## Battery — 7/10
**Measured** (on battery, 20:38–20:53; raw logs in `docs/reviews/2026-10-05-readings-accuracy/B/battery-*.txt`):

| Reading | MacStats (harness replicating `AppModel.refreshBattery`) | Ground truth | Diff |
|---|---|---|---|
| Percent | 64 % → 63 % | `pmset -g batt` 64 % → 63 % | 0 |
| Power now | 1.59–3.23 W (SystemLoad) | Voltage × Amperage: 11.828 V × 0.152 A = 1.80 W against SystemLoad 1.797 W at the same moment | ≤ 0.01 W |
| Power avg (session) | 3.32 W | Accumulators over the same 569 s: (261 872 494 − 259 984 747) / (264 772 − 264 203) = **3.318 W** | 0 |
| Time left (fresh launch, no prior) | **9 h 8 m** (expected draw 3.22 W, 29.41 Wh left) | 29.41 Wh ÷ 3.32 W measured = **8 h 51 m**; macOS said **10 h 45 m** (pmset) / 8 h 19 m (`TimeRemaining`) | +3 % (macOS +21 %) |
| Time left, app's real persisted prior (3.79–4.15 W) | 8 h 51 m (replay, `battery-prior-replay.txt`) | 8 h 51 m | 0 |
| Time left, stale 3-h prior of 5.5 W / 2.0 W | 7 h 51 m / 10 h 12 m | 8 h 51 m | −11 % / +15 % |
| Health | 99 % (nominal peak 4542 / design 4563) | System Settings / `system_profiler`: Maximum Capacity **99 %** | 0 |
| Cycle count | 128 | `system_profiler`: 128 | 0 |
| Battery temperature | 30.1 °C → shown "30 °C" | ioreg `Temperature` 3013 (centi-°C) | 0 |
| Status label | "On battery" | pmset "discharging" | ok |
| Time to full | **not live-verified** (on battery). Shipped function: 79 % → **60 min**, 80 % → **26 min** (`time-to-full-cliff.txt`) | n/a | see B1 |

**Works well**
- **Power.** It uses the gauge's whole-Mac SystemLoad, and the average comes from the gauge's running sums, so it is exact rather than sampled. Unit handling is right: signed Amperage from a UInt64 bit pattern, centi-°C, mV × mA / 10⁶ (`BatteryTelemetry.swift:117-136`).
- **Time left.** It tracks real drain far better than macOS's one-minute figure. Over 10 minutes it moved between 7 h 15 m and 9 h 50 m, following short bursts (some were my CPU tests). It ended 3 % from the measured-average forecast. Intervals that span sleep are rejected (`gaugeInterval`). The estimator never lost an interval: the running app had stored 1310 s of awake on-battery data after about 22 minutes up, so App Nap and timer slack drop nothing.
- **Health.** It is truncated like System Settings and smoothed over the peak of the last 10 readings. That matters because NominalChargeCapacity swung between 4497 and 4542 mAh within 10 minutes (`battery-gauge-log.txt`), which would otherwise flicker the figure between 98 % and 99 %.
- **Edge states.** No battery shows "No battery" and the card can't be tapped. First launch with no history falls back to macOS's figure for 2 minutes. Plug and unplug start a new session through an IOPS notification. The charge limit comes from powerd's file or is learned only from a charging → held transition. 35 + 15 unit tests cover the pure logic.

**Issues**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| B1 | **High** | `Sources/MacStatsCore/BatteryCharging.swift:52` (`let taperRate = current >= kneeMAh ? chargeMA : chargeMA * taper`) | Below the 80 % knee, the 80→100 % stretch is costed at 0.45 × current. At or above the knee, the remaining charge is divided by the measured current as if it stayed constant. **Result: a cliff.** At 2000 mA the estimate is 60 min at 79 % and 26 min at 80 %. Above the knee the CV current keeps decaying, so the estimate keeps reading short. In a simple exponential CV model (80→100 % in 60 min), the formula reads 0.42–0.72 × the true time, and the 5-minute EMA lag adds to that. The project's own progress notes flag this as unverified. | "Time to full" is the main charging number. It halves in one step and then counts down faster than the clock. It also affects "Time to 85 %" at 80–84 %: 16 min at 79 %, then 7 min at 80 %. | Make the model continuous across the knee. Above the knee, model the CV decay (for example, minutes = τ · ln(I_now / I_cutoff) with a cut-off near 0.05 C), or keep applying a taper factor to the remainder that shrinks smoothly with charge. Add a unit test that the estimate never drops more than about 2 min per percent across 79→80 %. Then log one real charge (the progress doc gives the procedure). |
| B2 | Low | `BatteryDetailsCard.swift:44-47`; gauge cadence | "Power … now" is the gauge's last update, up to ~60–85 s old. It read **13.6 W "now" for a full minute** after a short burst, while `top` showed the Mac idle. | Users read "now" as instantaneous. | Label it "last min", or show only the average while on battery. |
| B3 | Low | `BatteryTelemetry.swift:44-51` | Remaining energy assumes the average voltage is midway to 3.5 V per cell. That is plausible, but not checked against a real run to shutdown. The mAh-based equivalent is about 6 % longer (2638 mAh ÷ 281 mA = 9.4 h against 8.85 h). Raw charge also jitters: AppleRawCurrentCapacity *rose* 2653 → 2672 → 2688 while discharging, as the gauge recomputed full capacity. | The estimate can be off by a few percent systematically; the jitter is harmless after smoothing. | Validate once against a logged discharge to "0 %". Keep the model if it holds. |
| B4 | Low | `MacStatsApp.swift:184-190, 233` | "avg" is the mean since unplugging **or since MacStats launched** (the first read always counts as a state change). It isn't labelled. | Two users comparing "avg" numbers mean different windows. | Label it "avg since unplugged", and seed it from the gauge sums across a relaunch, or say "since launch". |
| B5 | Low | `MacStatsApp.swift:190, 259-261` | At launch `saveEstimator()` runs with no typical value, but still stamps `lastEstimatorSave`. So the first real save happens only 10 min later, and nothing is saved on quit. Verified: defaults had no typical value 12 min after launch. | Restarting the app (updates) within 10 minutes loses the learned typical drain. | Set `lastEstimatorSave` only when something was written, and save in `applicationWillTerminate`. |
| B6 | Low | `BatteryEstimator.swift:88-93` (design) | The persisted 3-h "typical" counts as 20 minutes of evidence. A stale typical moves a fresh session's estimate by −11 % / +15 % (replay). | By design, and the error fades within about 30 minutes. Noted for transparency. | None needed; optionally shorten `priorSeconds`. |
| B7 | Low | `BatteryCharging.swift:20-24` | `ChargeCurrent` seeds at full weight with the first reading after plug-in. Unlike `BatteryEstimator.blend`, it has no bias correction. | A plug-in transient sets time to full for the first few minutes. | Reuse the bias-corrected blend. |
| B8 | Low | `MacStatsApp.swift:176-234` | The glue that decides what is shown (state switch, limit handling, peak health) has no tests. Health is hidden on Intel batteries without `NominalChargeCapacity` (no fallback to `MaxCapacity` / `DesignCapacity`). | Regressions in the glue go unnoticed; old Intel Macs lose the health row. | Extract the glue into a pure function and test it; add the Intel fallback. |

**Why 7:** every on-battery reading I could measure is exact or within 3 %, which is a 9 on its own. But B1 is a deterministic High bug in the main charging estimate, so the area can't be 8+. It lands at 7 rather than 6 because everything else in the area is excellent.

---

## CPU — 8/10
**Measured** (my harness compiles the real `MacStatsCore` sources and replicates `AppModel.procScanTick` and `BreakdownView`'s formatting; `top` ran at the same time; logs in `docs/reviews/2026-10-05-readings-accuracy/B/cpu-*.txt`):

| Reading | MacStats (harness) | Ground truth | Diff |
|---|---|---|---|
| Header, idle | 2.6–3.0 % | `top`: 3.2 % (100 − idle) | ≤ 0.6 pt |
| Header, 4 × `yes` | 51.9–54.5 % (57.4 % in one scan) | `top`: 52.0–53.6 % (56.6 % in one sample); 4 × 99.9 % of a core = 50 % of 8 cores, plus background load | ≤ 1.5 pt |
| Per process, `yes` | 12 % of the Mac (context menu: 100 % of one core) | `top`: 99.9 % of a core | 0 |
| Attribution of `yes` started from Claude Code in VS Code's terminal | **Code** row, 403–414 % of a core; children `yes` ×4 + `claude` | Started from VS Code's integrated terminal (chain zsh → claude → zsh → Code Helper → Code) | correct |
| Build-like burst (4 workers spawning 0.3 s `perl` children for 8 s) | Code 50–53 % (the `bash` workers carry their reaped children: 11–12 % each); rows = header every scan | `/usr/bin/time`: 30.0 s CPU over 8.04 s = 3.73 cores = 47 % | within noise |
| Final interval of a job whose shell reaps it | `zsh` under Code, 11 % (`cpu-h_reap.txt`, scan 7) | 2 × `yes` killed and reaped mid-interval | correct |
| Final interval of orphaned work (parent subshell exited without waiting) | **System 21 % (170 % of a core)** for one scan (`cpu-h_yes.txt`, scan 11) | That work was the user's `yes` processes in VS Code | **misattributed** |
| XPC / helper attribution | MTLCompilerService, VTDecoder/EncoderXPCService and SafariPlatformSupport.Helper under Chrome / Spotify / Claude; Chrome renderers under Chrome; `SourceKitService`, `sourcekit-lsp` and `codex` under Code | Responsible app | correct |
| Claude Code row name | "claude" (not the version-number binary name "2.1.289") | `ps` comm `2.1.289` | correct |

**Works well**
- The header uses host CPU ticks over exactly the interval the rows cover. Every scan's rows sum to the header to 0.01 pt.
- Per-process CPU converts Mach ticks to nanoseconds correctly (`ProcessReader.swift:158-178`).
- Attribution follows the responsible process first, so terminals, IDEs and XPC helpers are handled. It falls back to the parent chain through root `login` using the full process table.
- Reaped children are credited to the surviving parent, with a cap and expiring debt, so a build's short-lived compilers aren't lost.
- New processes count from zero; pid reuse is detected through the start time.
- The scale is labelled: the footer reads "Share of the whole Mac (all 8 cores)", and a process row's context menu shows "% of one core" for comparison with Activity Monitor.
- There are 28 attribution and sampler tests.

**Issues**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| C1 | Medium | `ProcessScan.swift:159-174` (debt only on a *surviving* ancestor), `ProcessBreakdown.swift:154-158` (System = remainder), tooltip at `BreakdownView.swift:425` | If a process exits and no surviving ancestor reaps it, its CPU since the last scan can't be read. Examples: an orphan reaped by launchd, a launchd-spawned agent or XPC service that exits. That work falls into the "System" row, whose tooltip says "kernel, WindowServer, other users' processes and commands run with sudo". Measured: 170 % of a core of the user's `yes` work showed as System for one scan. | A user stopping a job can see a big "System" spike and blame macOS. This is the one place the rows stop telling the truth about who did the work. | Cheapest fix: reword the tooltip to say it includes "…and work by processes that exited since the last scan". Better fix: remember each vanished process's owner and last-interval rate, and credit the unexplained remainder to those owners, capped by the remainder. |
| C2 | Low | `addingSystemRow` | Rows "add up to the header" by construction: System is the plug, so it silently absorbs every error, including C1 and clock skew. | Not a bug, but the add-up isn't evidence of accuracy. | Optionally show System in a different style (for example, italic "System & unattributed"). |
| C3 | Low | — | The Terminal.app tab path (shell under a root `login`) was **not live-verified**: Terminal had no tab open, and UI events were off-limits. It is covered by `childUnderRootLoginMapsToApp` plus the responsible-pid path, which works live for VS Code. | Residual risk only. | Do the manual check in the progress doc (open a Terminal tab, run `yes` for 5 s, expect Terminal at about 12.5 %). |
| C4 | Low | `AppInfoCache.info` | Claude Desktop's MCP server registers as a running app and gets its own row, "npm exec @modelcontextprot…", instead of sitting under Claude. | Cosmetic. | Fold runningApplications without a bundle into their responsible or parent app. |
| C5 | Low | `BreakdownView.swift:173-177` | The Activity Monitor scale ("% of one core") is available only on *process* rows, not on app rows. | A user comparing "Code 12 %" with Activity Monitor's "100 %" has to expand the row first. | Add the same line to the app-row context menu, or a tooltip. |

**Why 8:** every reading I could check matches `top` and `/usr/bin/time` within noise, and the hard attribution cases (IDE terminal, Claude Code, helpers, XPC, short-lived build children) are right. The one Medium issue (C1) is transient and only for unreaped exits. That is a noticeable but narrow gap, so 8, not 9.

---

## Memory — 9/10
**Measured** (`memory-card-vs-vmstat.txt`, `memory-breakdown.txt`):

| Reading | MacStats (harness) | Ground truth | Diff |
|---|---|---|---|
| Memory Used (card) | 10.48 / 16.00 GB (shown "10.5 / 16.0 GB") | `vm_stat`: App (anonymous 394 420 − purgeable 17 030 pages) 5.76 + wired 1.61 + compressed 3.11 = **10.48 GiB** (16 KiB pages) | 0.00 |
| Pressure | normal | `kern.memorystatus_vm_pressure_level` = 1; `memory_pressure` 69 % free | match |
| Chrome main process | 761 MB | `footprint -p 52473`: 761 MB | 0 |
| Code Helper (Plugin) | 359 MB | `footprint`: 359 MB | 0 |
| Claude Helper (Renderer) | 420 MB | `footprint`: 420 MB | 0 |
| SourceKitService (under Code) | 442 MB | `footprint`: 442 MB | 0 |
| mediaanalysisd (Other processes) | 99 MB | `footprint`: 99 MB | 0 |

**Works well:** the card uses the Activity Monitor formula with the real page size (16 KiB, not 4 KiB). Rows use physical footprint (Activity Monitor's column), not RSS (resident size). Memory needs no "Measuring…" state. Expanded children show each process's own footprint, ranked. Pressure is the kernel's real level.

**Issues**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| M1 | Low | `BreakdownView.swift:106` | The footnote "Total also counts macOS and the kernel" implies the rows sum to less than the header. Here the user processes' footprints summed to 10.5 GB against a 10.48 GB header. Footprint counts compressed pages at their uncompressed size, so the rows can meet or exceed the total. | A careful user sees rows ≥ total and doubts both. | Footnote: "Per-app memory includes compressed memory at full size, so rows can exceed the total". |
| M2 | Low | — | "Memory Used" was compared with the Activity Monitor *formula*, not with Activity Monitor's window (I couldn't open it). | Residual risk only; it is the formula Activity Monitor, iStat and Stats use. | One manual side-by-side check. |
| M3 | Low | `sortedRows` | "Other processes" (2.6 GB of macOS agents) tops the list. | It pushes real apps down. | Pin group rows last for memory. |

**Why 9:** every value I checked is exact; only labelling nitpicks remain.

---

## Overhead — 7/10
**Measured**

| Reading | Value | Method |
|---|---|---|
| MacStats CPU, popover closed | 0.35 s of CPU over 21 min 24 s = **0.027 % of one core** (and 0.01 s over a separate 60 s window) | `ps -o time,etime -p 89124` |
| MacStats memory, closed | **13 MB footprint** (peak 13 MB); RSS 66 MB, which mostly counts shared framework pages | `footprint -p 89124` |
| One breakdown scan (~500–530 processes) | **4–15 ms** (first scan 5–8 ms), once per second, so about 0.5–1.5 % of one core while a breakdown is open | harness timer around the same calls as `procScanTick` |
| Per-process scan only while a breakdown is open | Confirmed in code: `procTimer` is created only in `enterBreakdown` (`MacStatsApp.swift:279-290`) and torn down in `exitBreakdown`, which runs on close (`:104`) | code |
| Open popover / idle after first open | **Not measured** (needs clicks, which were off-limits) | — |

**Issues**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| O1 | Medium (unverified by me) | `MacStatsApp.swift:347-353` → `MetricsStore.record` (`MetricsStore.swift:50-58`) | While closed, the 10 s sampler publishes to `@Published` properties. After the popover has been opened once, MenuBarExtra keeps the view tree alive, so SwiftUI redraws it every 10 s. The project's own notes measured ~0.7–1.3 % of one core, about 40× the fresh-launch idle cost, and the code path supports that. | A monitor that sits at ~1 % forever after one click is not "lightweight". | Buffer samples while idle and publish once on open, as the progress doc proposes; then re-measure. |
| O2 | Low (unverified by me) | 0.5 s tick + sparkline redraws | The project's notes report 12–17 % of one core while the popover is open. | Visible in Activity Monitor while someone uses the app. | Profile the sparkline redraws; consider 1 s ticks when the CPU breakdown isn't open. |

**Why 7:** everything I could measure is excellent (a 9 on its own). The two costs I couldn't measure are reported by the project itself, and the code supports them, so I can't award 8+ without seeing them fixed.

---

## Network — 9/10
| Reading | MacStats (`readNetCounters`) | `netstat -ib` | Diff |
|---|---|---|---|
| Received bytes over 5 s | +8 537 B | +8 537 B | 0 |
| Sent bytes over 5 s | +3 058 B | +3 058 B | 0 |

**Works well:** 64-bit `IFMIB_IFALLDATA` counters (no 4 GiB wrap), loopback excluded, a 1 s trailing average.

**Issues:** (Low) VPN `utun*` traffic may be counted twice (once on the tunnel, once on Wi-Fi); untestable here because no VPN carried traffic (utun0–5 held ≤ 106 B). (Low) "KB/s" and "MB/s" are binary units (1024 / 1 048 576), a nitpick.

**Why 9:** byte-exact; only an untested VPN edge remains.

---

## Cross-cutting issues
- **App-layer glue is untested.** `AppModel.refreshBattery`, `procScanTick` and `BreakdownList.rows` hold real decisions (what shows when charging, the limit, peak health) but are only exercised by hand. Extracting them as pure functions would make B1/B4/B5-type regressions catchable.
- **Remainder rows hide errors.** "System" (CPU) is defined as the remainder, so it absorbs every attribution error, which makes "rows add up" a property of the code, not a check. Consider exposing how much of System is "recently exited" (C1).
- **Staleness isn't shown.** Gauge-derived values ("Power now", health, temperature) update about once a minute. Nothing tells the user how old they are.

## Top fixes (ranked by impact ÷ effort)
1. **Make time to full continuous across 80 % and model the CV decay** (`BatteryCharging.swift:48-55`). Add a unit test for the 79→80 % step, then verify against one logged charge. Fixes the only High issue.
2. **Reword the System row's tooltip** to include "work by processes that exited since the last scan" (`BreakdownView.swift:425`). Five minutes of work, and it removes the misleading "it's macOS" reading. Later, credit the remainder to vanished processes' owners (C1).
3. **Stop idle redraws after the first open:** buffer samples while closed and publish on open (`MacStatsApp.swift:347-353`). Then measure open and idle-after-open cost with `ps` (O1/O2).
4. **Label the battery power row honestly:** "last min" instead of "now", and "avg since unplugged" (`BatteryDetailsCard.swift:44-47`) (B2/B4).
5. **Persist the typical drain correctly:** don't stamp `lastEstimatorSave` when nothing was written, and save on quit (`MacStatsApp.swift:190, 259-261`) (B5).
6. Smaller items: the bias-corrected `ChargeCurrent` (B7), the "% of one core" line on app rows (C5), the memory footnote (M1), and pinning group rows last (M3).

## Method & limits
- **Harnesses.** Each one compiled all of `Sources/MacStatsCore/*.swift` except `AppleSensorReader` / `CPUTemperature` (sensor shim) with the 26.5 SDK, plus a `main.swift` that replicates the app glue line for line:
  - `procScanTick` + `BreakdownView` formatting → `B/harness-breakdown.swift`
  - `refreshBattery` from a fresh launch at the idle sampler's 10 s cadence → `B/harness-battery.swift`
  - an estimator replay with different priors
  - the shipped `minutesToTarget` table
  - `memorySample`
  - `readNetCounters`

  Ground truth was taken at the same moments with `top`, `/usr/bin/time`, `footprint`, `vm_stat` / `sysctl`, `ioreg -rn AppleSmartBattery` (every 15 s for 12 min), `pmset`, `system_profiler SPPowerDataType` and `netstat -ib`.
- **Controlled loads.** At most 4 × `yes` for ≤ 8 s, plus one 8 s `perl` burst, all from Claude Code in VS Code's terminal. All were killed and reaped; no leftover processes. The other reviewer's loads may have overlapped (one 13 W gauge reading at 20:46 wasn't mine), which only affects the drain *level*, not the comparisons, because harness and truth read the same accumulators.
- **Unit tests.** `./Scripts/test.sh`: **184 tests in 28 suites pass**.
- **Not verified live:**
  - charging (the Mac was on battery), so time to full is judged from code, model simulation and the shipped function's output;
  - Terminal.app tabs (none open, and no UI events allowed);
  - the open-popover and idle-after-open overhead (needs clicks);
  - Activity Monitor's own window (compared with its formula instead);
  - VPN double counting;
  - a full discharge, so "time left" is checked against a forecast from the measured average drain, not against an actual shutdown time.
- **Not reviewed:** CPU temperature (out of the listed scope).
- **Files cited:** `/Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats/docs/reviews/2026-10-05-readings-accuracy/B/` (about 120 KB of text logs and the two harness sources).
