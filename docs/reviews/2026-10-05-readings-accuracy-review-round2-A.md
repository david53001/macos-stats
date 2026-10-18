# MacStats readings accuracy review — 2026-10-05
**Overall: 8/10** — Every number I could check against ground truth landed within measurement noise: CPU header vs `top` (38–40 % vs 39.8 %), per-process CPU (`yes` at 100 % of one core vs `top`'s 99.9 %), per-process memory vs `footprint` (7 of 7 to the MB), the memory card vs the Activity Monitor formula, network counters vs `netstat -ib` to the byte, battery power vs the battery's own coulomb counter (within 1 % in three windows), and time left vs the drain measured over the same window (548 vs 560 min). Attribution held in every case I could run: VS Code's integrated terminal, Claude Code, a `swift build`, short-lived `dd` children, an orphaned `yes`, XPC services and Chrome/Claude/Spotify helpers. Overhead with the popover closed is negligible (0.03 % of one core, 13 MB). Nothing scored High. What keeps the overall score at 8 rather than 9: (1) time to full is a curve fitted to four charges of this one Mac on a ~30 W adapter, with no data above 85 % and no check on other adapters or Macs; (2) the kernel's rate limit on `host_statistics` sometimes gives the breakdown header stale CPU ticks; (3) after a process exits, its leftover CPU time is credited to the app's main-process row; (4) health can read 98 % for about the first minute after launch. On the owner's scale that is "basically perfect" with a few real but small issues.
**Standard:** Activity Monitor / System Settings / battery gauge parity · **Method:** code analysis + live measurement · **Reviewer:** independent subagent (round 2, reviewer A)

Reviewed: branch `fix/readings-accuracy` at commit `164ce01` (v1.1.0), M3 MacBook (8 cores, 16 GB, 16 KiB pages), macOS 26.7.1, on battery. Every file cited as `round2-A/<name>` is in `docs/reviews/2026-10-05-readings-accuracy/round2-A/`. Code references are `file:line` under `Sources/MacStatsCore/` or `Sources/MacStatsApp/` (`MacStats.swift` = `Sources/MacStatsApp/MacStatsApp.swift`).

## Calibration
- **Target:** native macOS 14+ menu-bar monitor (SwiftUI `MenuBarExtra` + IOKit/Mach/libproc), Apple Silicon first. Public users compare it with Activity Monitor and System Settings.
- **A 10:** every reading matches Apple's own figure within noise. Work is attributed to the responsible app the way Activity Monitor / iStat Menus do it, units are unmistakable, estimates are honest against measured drain/charge, edge states behave and overhead is negligible.
- **Anchors used:** 3 = a primary number badly wrong or major work invisible. 6 = roughly right with noticeable gaps. 9 = within noise everywhere I could test, with only nitpicks left.
- **Terms.**
  - *Footprint*: a process's physical footprint (`ri_phys_footprint`). This is Activity Monitor's "Memory" column, and it counts compressed memory at its uncompressed size.
  - *Responsible process*: the app macOS charges for a process's work (Terminal for its tabs' shells, an app for its XPC helpers). Read with `responsibility_get_pid_responsible_for_pid`.
  - *Gauge*: the battery fuel-gauge chip, exposed as `AppleSmartBattery` in the IORegistry (`ioreg -rn AppleSmartBattery`). It refreshes about every 60 s.
  - *mAh*: charge (milliamp-hours). *Wh*: energy (watt-hours ≈ mAh × volts / 1000).
  - *Raw charge*: `AppleRawCurrentCapacity / AppleRawMaxCapacity`. It runs about 2–3 points below the percent macOS shows.
  - *`SystemLoad`*: the gauge's whole-Mac power telemetry (mW). It also keeps a running sum (`AccumulatedSystemLoad`) and a count (`SystemLoadAccumulatorCount`, about 1 per second), so an exact average can be computed between two reads.
  - *Mach ticks*: Apple Silicon's 24 MHz time unit (1 tick = 41.67 ns).

## Scoreboard
| Area | Score | Verdict (one line) |
|---|---|---|
| Battery | 7/10 | Power, health, cycles and temperature match the gauge and System Settings. Time left uses real drain and is far steadier than macOS's figure. Time to full is a model fitted to one Mac and was not live-verified. |
| CPU | 8/10 | Header = `top` within 1 point, rows add up to the header, and every terminal/IDE/helper/orphan case I ran went to the right app. Small issues: stale ticks from the rate limit, and exit credit shown on the app's main-process row. |
| Memory | 8/10 | Footprints are exact, the card uses Activity Monitor's formula from the same counters, and pressure comes from the kernel. The "System & other" remainder can't be checked and makes the rows add up to more than the header. |
| Overhead | 9/10 | Idle: 0.24 s of CPU in 13.5 min, 13 MB footprint, `top` POWER 0.0. A breakdown scan costs 1–6 ms. |
| Network | 9/10 | 64-bit counters match `netstat -ib` to the byte. VPN tunnels and bridges are excluded. Units are 1000-based, like macOS. |

## Battery — 7/10
**Measured** (harness `bsim_main.swift` replays `AppModel.refreshBattery` exactly: the 10 s poll, `gaugeInterval`, `averageWatts` into `BatteryEstimator` seeded with the app's persisted typical drain 3.55 W / 3935 s, and `remainingWh`. Logs: `round2-A/bsim.log`, `round2-A/batt.log`, `round2-A/coul.log`):

| Reading | MacStats (harness) | Ground truth | Diff |
|---|---|---|---|
| Power, last min (21:52:17→21:53:17 gauge minute) | 3.49 W (`intervalWatts`) | ΔAccumulatedSystemLoad/Δcount = 202 167 / 58 = 3.49 W | 0 (same source, by construction) |
| Is `SystemLoad` the battery drain? (21:52:17→21:55:20) | 2.92 W (Δ`AccumulatedSystemLoad`) | Coulomb counter ΔPackCurrentAccumulator/Δcount = 255 mA × 11.62 V = 2.96 W | −1 % |
| Same check, 21:40:29→21:52:17 | 3.88 W | 333.6 mA × 11.6 V = 3.87 W | 0 % |
| Same check, 21:55:20→21:59:20 | 2.07 W | 178 mA × 11.62 V = 2.07 W | 0 % |
| Health | 99 % (peak of recent `NominalChargeCapacity` 4550 / 4563) | System Settings / `system_profiler`: 99 % | 0. The first reading after launch can be 4509 → 98 % (see B2) |
| Cycle count | 128 | `system_profiler`: 128 | 0 |
| Battery temperature | 29.98 → "30 °C" (centi-°C ÷ 100) | `ioreg` `Temperature` = 2999 | 0 |
| Time left (on battery, 55–56 %), 9 gauge updates 21:50→21:58 | 443 → 438 → 494 → 466 → 477 → 511 → 536 → **548 min** as the load fell from ~3.5 W to ~2 W | At the end: 25.88 Wh ÷ the drain measured over the same 7.8 min (Δ`AccumulatedSystemLoad` = 2.77 W) = **560 min**. The last 3 h awake on battery (`pmset -g log`: 74 % → 57 % in 3 h 04 m, ≈ 5.5 %/h) give ≈ 10 h | −2 % vs the measured window; −9 % vs the 3-h trend. Honest |
| macOS's own time left (for comparison) | IOPS `TimeToEmpty` 579–609 min; `AvgTimeToEmpty` jumped 214 → 748 → 268 → 626 min within 6 minutes | — | macOS's figure is the jumpy one MacStats replaces |
| Time to full / to the limit | not live-verified (Mac on battery) | Unit tests replay 4 real charges of this Mac (`ChargeCalibrationTests`) | see B1 |
| Charging-state labels | "On battery" (`parseBattery`: `IsCharging` / `ExternalConnected` / `IsCharged`) | `pmset -g batt`: "discharging" | match. Charging, charged and not-charging checked in code only |

**Works well:**
- Power is the gauge's exact per-minute average (`intervalWatts`, BatteryTelemetry.swift:153). I confirmed it equals the battery's coulomb-counted drain within 1 %, so "Power, last min" and the estimator's input are honest. The labels say what the averages cover ("Power, last min", "Avg since unplugged" / "Avg since MacStats started").
- Intervals that span sleep are rejected (`gaugeInterval`, BatteryTelemetry.swift:127), so time left can't promise 13 h after opening the lid. Plug/unplug resets the session (MacStats.swift:201–210) and is picked up instantly through the IOPS notification (MacStats.swift:314).
- Time left is anchored on real drain and ended within 2 % of the drain measured over the same window (548 vs 560 min). It moves smoothly (438 → 548 min over 8 min as the load fell), while macOS's `AvgTimeToEmpty` jumped 214 ↔ 748 min between consecutive minutes. `remainingWh` (BatteryTelemetry.swift:43) allows for voltage sag (11.62 V now, 10.5 V at 3.5 V/cell) instead of using the present voltage, and gives a sensible 26.0 Wh at 53 % raw.
- Health is truncated like System Settings and smoothed over the gauge's ±1 % swings (4509 ↔ 4550 mAh seen in 15 min). Temperature units are right (centi-°C).
- No battery → `readBattery()` returns nil → the card says "no battery", the gauge is hidden and the drill-in is disabled (OverviewView.swift:34). Intel without `PowerTelemetryData` falls back to V × I while discharging (BatteryTelemetry.swift:62).
- The pure logic is well covered: 221 tests pass (`round2-A/tests_tail.txt`), including the estimator's sleep/spike/plug cases and a replay of 4 real charges.

**Issues:**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| B1 | Medium | BatteryCharging.swift:69–100 (`knee: 0.8, decline: 0.4`), MacStats.swift:241–249 | Time to full is a curve fitted to the same 4 charges it is tested on (in-sample), all on this M3 with a ~30 W adapter and an 85 % limit. There is no data above raw 85 %: the stretch to 100 % is pure model, and the one full charge happened while asleep. Fast chargers (70–140 W) and 2-cell or 100 Wh packs taper differently. | Public users charging to 100 % or on bigger adapters get an estimate nobody has validated. A wrong shape biases "Time to full" for the whole charge, not just the end. | Hold out sessions (fit on 2, test on 2) and record a 85→100 % charge before claiming parity. Until then, learn `decline` per Mac from the first ~10 min of each charge (measured current vs raw level), or fall back to macOS's `AvgTimeToFull` above 85 % raw. |
| B2 | Low | MacStats.swift:62–63 + :214 (`RecentMax(capacity: 10)` starts empty every launch), BatteryTelemetry.swift:54 | Health is the peak of the last ≤ 10 gauge readings, but the window starts empty at launch. At 21:40 the gauge read 4509 mAh (98.8 % → **98 %**); 10 minutes later it read 4550 (99 %). System Settings said 99 % throughout. | For about the first minute after launch or login, health can read one point below System Settings. | Persist the peak (or the last 10 values) in UserDefaults alongside the drain average. |
| B3 | Low | BatteryEstimator.swift:25, :111–116 | The 5-min average gets 60 % of the weight, and early in a session it is close to a running mean. In the replay a single quiet minute (2.08 W) moved the estimate 438 → 494 min (+13 %) four minutes into the session, and the run as a whole went 438 → 548 min (+25 %) in 8 minutes. That follows the real drop in load and ended accurate, but it is a big swing. | Time left can move by an hour within minutes, mostly right after launch or unplug. Users may read that as noise. | Ramp `shortWeight` in from 0 over the first ~10 min of a session, or require ≥ 3 gauge minutes before the short term counts. |
| B4 | Low | BatteryTelemetry.swift:43–50 | `remainingWh` assumes the Mac runs until raw charge reaches 0 and that voltage falls linearly to 3.5 V/cell. Neither was checked (a full drain wasn't possible). macOS shows ~2.5 points more than raw while discharging (56 % shown at 53.5 % raw). | If the Mac shuts down at a raw reserve above 0, time left is a few percent long near empty. | Check against one logged full drain, e.g. powerlog: raw mAh at the 0 % shutdown. |

**Why 7:** every live battery number (power, health, cycles, temperature, state) matches the gauge or System Settings. Time left is grounded in measured drain and is clearly better than macOS's own figure. But B1 is a Medium on a primary reading (time to full) that I couldn't verify live and that rests on a single-Mac, in-sample fit. Combined with the small launch-time wobbles (B2, B3), the list supports a 7 rather than an 8.

## CPU — 8/10
**Measured** (harness `main.swift` runs the real `BreakdownScanner` / `ProcessAttributor` / `attributionAnchors` with `NSWorkspace` anchors, exactly as `procScanTick` does. `sim_main.swift` also replays the app's 0.5 s tick + 1 s scan timers):

| Reading | MacStats (harness) | Ground truth | Diff |
|---|---|---|---|
| Header, 2 × `yes` + another reviewer's build running (`load2.txt`) | 38.2 / 39.0 / 39.4 % | `top` CPU usage 39.75 % / 39.12 % (`load2_top.txt`) | ≤ 1 point |
| `yes` (one process) | 12 % of the Mac = 100 % of one core (context-menu line) | `top`: 99.9 % | 0 |
| Rows vs header | rows + System = header in every scan (`load2.txt`, `short.txt`) | — | 0 by construction (System = remainder, clamped ≥ 0) |
| Work in VS Code's integrated terminal (`yes`, a `swift build` by another session, `claude`) | all under **Code** (`yes` 100 % each, `swift-driver` 81 %, `claude`) | process tree: zsh ← Code Helper ← Code; responsible pid = Code (`owner.txt`) | correct |
| Short-lived children (2 loops of ~50 ms `dd`, `short.txt`) | `bash` 95–99 % of one core each (reaped-child credit), Code 201–214 %, System 0.4–1.1 % | 2 cores busy | correct |
| Orphaned `yes` (parent exited, ppid = 1) | Code, 100 % of one core; after `kill`, its last interval went to Code (85 %), not to System (`orphan_cpu.txt`) | responsible pid = Code | correct app; wrong child row (C2) |
| Helpers / XPC | Claude Helper, Chrome Helper, MTLCompilerService, QuickLookUIService, MCP `node` servers → their apps (`owner.txt`, `mem.txt`) | responsible pids | correct |
| Energy rows (Battery drill-in), 2 × `yes` | 3.2–3.7 W per `yes` (`energy_load.txt`) | plausible for one M3 P-core; labelled "App power counts CPU only" | n/a (no per-process ground truth without root `powermetrics`) |

**Works well:**
- One scale everywhere: card, header and rows are shares of the whole Mac. The footnote says "Share of the whole Mac (all 8 cores)", and each row's context menu gives Activity Monitor's "% of one core". The Mach-tick → ns conversion is correct (ProcessReader.swift:158–178).
- Attribution looks at the responsible pid first at every step up the parent chain (ProcessScan.swift:14–30). That fixes the old Terminal/root-`login` gap. Real apps are kept apart from background-only "apps" such as MCP servers (`attributionAnchors`, ProcessScan.swift:48). Results are cached per pid + start time, so pid reuse is handled.
- Reaped-child credit, debt expiry and the exit-work estimate (ProcessScan.swift:156–316, :433–450) work live: a build's short-lived compilers and killed jobs show under the right app, not as System. The credit is capped at what the machine actually did unseen (ProcessScan.swift:364–386), so rows can't exceed the header.
- First scan = baseline ("Measuring…" for 0.5 s). Processes started between scans count from zero, and a missed process gets no lifetime spike. Each case is unit-tested (ProcessScanTests).
- Terminal.app tabs (shell under a root `login`): not live-tested, because Terminal had no tabs open and opening one would mean driving the owner's apps. Covered by code (the responsible pid is checked before the parent) and by `childUnderRootLoginMapsToApp`.

**Issues:**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| C1 | Low | MacStats.swift:449 (`readCPUTicks()` in `procScanTick`) + MacStats.swift:154 (the 0.5 s tick); SystemReaders.swift:6 | With a CPU breakdown open the app calls `host_statistics(HOST_CPU_LOAD_INFO)` 3×/s. macOS rate-limits that call for non-platform binaries (a 1 s window with a random 2–10 call budget) and silently returns cached ticks past the budget. Measured: 8 of 40 reads at 3/s came back unchanged in one run and 1 of 40 in another; 0 of 40 at 2/s (`ratelimit.txt`). In the app's own timer pattern, 1–2 of 13 scans read stale ticks (e.g. a 0.32 s tick window for a 0.5 s scan: header 1.2 % under rows of 1.7 %, `sim_idle_1.txt`). One tight burst (3 reads within ~10 ms, like hover → open → click) showed **header 0.0 % against 25.3 % of rows**, plus a single 100.0 % card tick (`sim_load.txt`). | The header and System row are occasionally computed over the wrong interval. The reaped-child budget (`creditScale`, ProcessScan.swift:372–375) collapses when the header reads 0. It's rare and lasts one tick, but it is a primary number. | Read the ticks once per tick and hand the latest snapshot to the scan (or have the scan feed the tick), so there's one reader at ≤ 2/s. Alternatively use `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` (per-CPU, not rate-limited) for both. |
| C2 | Low | ProcessScan.swift:437–439 (`exitWorkCredit` puts orphan work on `previousOwners[pid]`, the app's main pid) | Unexplained exit work is credited to the app's **main process**. After the orphan `yes` was killed, the expanded Code row listed **"Code 14106 — 79 % of one core"** although VS Code's main process was idle (`orphan_cpu.txt`, scan 4). | The app total is right, but the child row tells the user the app's main process burned a core. That is exactly the row someone would Force Quit. | Keep the credit in the app's total but show it as a synthetic child ("Exited processes"), or put it on the nearest surviving ancestor in the same app rather than the main pid. |
| C3 | Low | MacStats.swift:459 (`appHasBundleID` keyed by pid only) | The bundle-id flag is cached per pid for the breakdown's life. If an app quits and its pid is reused by another app during one open breakdown, the flag is stale. | Theoretical; it only changes which "app" anchors a walk. | Key by pid + launch date, or drop entries for pids that left `runningApplications`. |
| C4 | Low | ProcessReader.swift:110 | The responsible pid is recorded when a process is spawned. If that app quits, a surviving child keeps pointing at a pid that may later belong to another app. | Rare misattribution of long-lived orphans after their app quits. | When the responsible pid's start time is later than the child's start time, ignore it. |

**Why 8:** the header, rows and per-process values matched `top` within noise in every state I could create, and attribution was right in every terminal, IDE, helper, orphan and short-lived case I ran. The remaining issues are rare one-tick glitches (C1) or a misleading child label (C2). No Medium or High.

## Memory — 8/10
**Measured** (`mem.txt`, `fp_compare.txt`, `vmstat.txt`, `sysctl_mem.txt`):

| Reading | MacStats (harness) | Ground truth | Diff |
|---|---|---|---|
| Card "used" | 10.29 GiB → "10.3 / 16.0 GB" | Activity Monitor's formula (App Memory + Wired + Compressed) from `vm_stat` taken a second later: (388 815 anon − 4 917 purgeable + 105 832 wired + 184 557 compressor) × 16 KiB = 10.29 GiB | 0.00 GiB (`internal_page_count` vs `vm.page_pageable_internal_count` differ by 404 pages = 6 MB) |
| Pressure | normal (`kern.memorystatus_vm_pressure_level` = 1) | `memory_pressure`: 71 % free, normal | match |
| Per-process footprint (7 pids: Code Helper, claude, Chrome, Claude renderer, Spotify, Dock, MacStats) | 352.0 / 333.6 / 711.8 / 406.7 / 261.5 / 47.6 / 12.5 MB | `footprint -p`: 352 / 334 / 712 / 407 / 261 / 48 / 13 MB | ≤ 0.5 MB (rounding) |
| Rows total vs header | rows incl. "System & other" = 14.50 GB; header 10.3 GB | by design: rows count compressed memory at full size (7.03 GiB stored in a 2.82 GiB compressor) | explained in the footnote |
| "System & other" | 5.2 GB (remainder) | wired 1.62 GiB + other users' and root processes (non-user RSS 2.36 GiB) + … | not verifiable without root (M1) |

**Works well:**
- The card uses Activity Monitor's "Memory Used" definition (MemoryStats.swift:54–59) with 16 KiB pages taken from `host_page_size`, not hard-coded. Pressure is the kernel's own level, not a heuristic.
- Rows are physical footprints, exactly what Activity Monitor shows (ProcessReader.swift:43). RSS is only a fallback.
- Group rows ("Other processes" 2.6 GB of 322 agents, "System & other") sort below the apps. Expanded children show each process's own footprint.

**Issues:**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| M1 | Low | MemoryStats.swift:66–69, ProcessBreakdown.swift:165–170, BreakdownView.swift:113 | Two bases are mixed. The header shows Memory Used (10.3 GB, compressed at its compressed size), while the rows add up to 14.5 GB because "System & other" is a computed remainder (5.2 GB, the single largest row). That remainder can't be checked and plausibly includes ~1–2 GB that isn't really "system" (anonymous memory charged to no footprint, double-counted IOKit memory). | A user summing the rows gets 4 GB more than the header. The footnote ("Rows count compressed memory at full size") explains it, but only an expert will follow. | Show the remainder's parts separately where they are known ("Wired 1.6 GB"), label the rest "Other (estimated)", or put a second total ("14.5 GB at full size") next to the header. |
| M2 | Low | — | Activity Monitor's own window wasn't compared (no UI interaction allowed). Parity rests on the formula plus counters read a second apart. | Small residual uncertainty about AM's exact App Memory term. | One screenshot comparison by the owner. |

**Why 8:** every per-process number is exact and the card reproduces Activity Monitor's formula from the same kernel counters. The only gap is a presentation one (M1).

## Overhead — 9/10
**Measured** (`cost.txt`; `ps`/`top` on the running app, popover closed):

| Reading | MacStats | Ground truth / budget | Diff |
|---|---|---|---|
| Idle CPU | 0.24 s CPU in 13 min 31 s (0.03 % of one core); `top` 10 s: 0.0 %, IDLEW 0, POWER 0.0 | negligible | — |
| Idle memory | footprint 13 MB (RSS 70 MB is mostly shared frameworks) | — | — |
| One breakdown scan (harness, ~485 processes) | median 1.1–1.3 ms at the 1 s cadence; 5.0–5.6 ms when scanning every 0.2 s; 29 scans used 0.13–0.16 s CPU in total; harness max RSS 11.5 MB | at 1/s ≤ 0.6 % of one core while a breakdown is open | — |
| Scan only while a breakdown is open | `procTimer` exists only between `enterBreakdown`/`exitBreakdown`, and `setVisibility(.idle)` calls `exitBreakdown` (MacStats.swift:115–118, 325–344) | — | — |

**Works well:** the idle sampler (10 s, 2 s tolerance) does a few microseconds of counter reads plus ~0.1 ms of battery reads. Publishing is paused while closed (`MetricsStore.pausePublishing`), so hidden SwiftUI views don't re-render. The full parent table is only fetched when a chain leaves the user's processes.
**Issues:** none found. Limit: the open-popover rendering cost (0.5 s SwiftUI redraws) was not measured because I couldn't click the menu-bar item.
**Why 9:** the closed-popover cost is unmeasurable by `top` and a scan is a few ms. Not a 10 only because the open-popover path wasn't measured.

## Network — 9/10
**Measured** (`net_compare.txt`): `readNetCounters()` rx = 7 814 017 534 B vs `netstat -ib` en0 + awdl0 = 7 807 808 880 + 6 208 654 = 7 814 017 534 B (exact); tx is exact too. `utun*` (VPN) and `lo0` are excluded.
**Works well:** 64-bit `IFMIB_IFALLDATA` counters (no 4 GiB wrap), VPN/bridge double counting avoided, 1000-based "KB/s / MB/s" like Activity Monitor, a 1 s trailing window, and a backwards counter clamps to 0.
**Issues:**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| N1 | Low | SystemReaders.swift:98–101 | `awdl*` / `llw*` (AirDrop / peer-to-peer Wi-Fi) are counted as network speed. | An AirDrop transfer shows as download speed. Arguably correct, but not what "internet speed" users expect. | Optional: exclude `awdl`/`llw`, or keep them and say so. |

**Why 9:** exact against `netstat`; only a nitpick.

## Cross-cutting issues
- **One reader per kernel counter.** `host_statistics` / `host_statistics64` are rate-limited per process. The open tick, the hover prewarm and the breakdown scan each call them on their own timers (C1). The same applies to `readVMRaw()`: 5 of 40 VM reads came back unchanged at 3/s (`ratelimit.txt`), although nothing currently diffs two VM reads, so there it's harmless.
- **Calibrated to one Mac.** The charge model (B1) and parts of the time-left tuning are justified with this M3's powerlog. That's good evidence for the owner's Mac and none for the public's other Macs.
- **Launch-time state isn't persisted** for health (B2), while the drain average is. Small, but it's the first thing a new user sees.
- **Tests:** 221 tests pass (`./Scripts/test.sh`). Pure logic (attribution, sampler, credit caps, estimator, charge model, memory formula, interface filter) is covered well. Not covered: a test that would catch C1 (the scan and tick reading ticks independently) or C2 (which child row carries exit credit).

## Top fixes (ranked by impact ÷ effort)
1. **C1: share one CPU-tick read between the tick and the scan** (MacStats.swift:449 → reuse the tick's latest `CPUTicks`, or switch `readCPUTicks` to `host_processor_info`). A few lines; removes the 0 %-header / stale-window glitches and stabilises the child-credit budget.
2. **B2: persist the health peak** (MacStats.swift:62, :214) next to the drain average. A few lines; health matches System Settings from the first frame.
3. **C2: show exit credit as an "Exited processes" child** instead of on the app's main pid (ProcessScan.swift:437–439 + BreakdownView child rows). Small; stops the expanded row from pointing at the wrong process.
4. **B3: ramp the short-term weight in over the first ~10 min of a session** (BatteryEstimator.swift:25, :84–88). Small; removes the ±13 % early wobble.
5. **B1: validate time to full out-of-sample and above 85 %** (BatteryCharging.swift:69–100). Fit on 2 sessions, test on 2, log one 85→100 % charge, and consider per-Mac learning of `decline`, or macOS's figure above 85 % raw. Medium effort; it's the only Medium in the review.

## Method & limits
- **Harnesses** (sources in `round2-A/`): `main.swift` (CPU / energy / memory breakdown, attribution, scan cost), `sim_main.swift` (the app's 0.5 s tick + breakdown timers, used to observe the rate limit; `sim_load.txt` came from its first version, which made the 3 opening reads within ~10 ms), and `bsim_main.swift` (battery: replays `refreshBattery`'s estimator feed on live gauge updates). All are compiled from the real `Sources/MacStatsCore/*.swift` (minus the two sensor files) with the 26.5 SDK. Each harness mirrors the matching glue in `MacStatsApp.swift` (`procScanTick`, `sample`, `refreshBattery`); I re-read those functions to check the mirror.
- **Ground truth:** `top -l 4 -s 2`, `ps`, `footprint -p`, `vm_stat`, `sysctl vm.*`, `memory_pressure`, `netstat -ib`, `ioreg -rn AppleSmartBattery` (including the coulomb counter `BatteryData.PackCurrentAccumulator`), `pmset -g batt` / `pmset -g log`, `system_profiler SPPowerDataType`.
- **Load:** at most 2 × `yes` for ≤ 8 s per test, plus two 8 s loops of short `dd` processes. Everything was killed afterwards and no foreign `yes` was running. Another session's `swift build` was running in VS Code during part of the CPU tests; it appears, correctly attributed, in `load2.txt`.
- **Not possible here:**
  - Charging (the Mac was on battery the whole time), so time to full, charge-limit learning and the charging labels were judged from code and tests and are not live-verified.
  - A Terminal.app tab (none open; opening one would drive the owner's apps).
  - Activity Monitor / System Settings windows (no UI interaction). Their numbers were taken from the same kernel/gauge sources (`system_profiler` for Maximum Capacity).
  - The open-popover CPU cost of MacStats itself.
- **Battery time-left honesty** was judged over a 14-minute window plus the 3-hour `pmset` trend. A full-discharge comparison would be the real test.
- **Not read:** the progress notes' "Review fixes" / "Results" sections and other reviewers' reports. I formed this view from code and my own measurements.
