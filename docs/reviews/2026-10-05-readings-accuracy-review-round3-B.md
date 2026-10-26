# MacStats readings accuracy review — 2026-10-05
**Overall: 8/10** — On the owner's scale this is "basically perfect" with a few small, real gaps. Every reading I could check live matched ground truth within noise. The CPU card and breakdown header match `top`, a 4-core `yes` load read 100 % of one core per process, and the rows add up to the header. Work run from VS Code's terminal and Claude Code, orphaned processes, processes killed mid-scan and short-lived child processes all landed in the right app. Memory Used matched Activity Monitor's formula to 0.01 GB, and per-process memory matched `footprint` to the MB. Battery health, cycles, temperature and adapter were exact, and network matched `netstat` to the byte. Idle overhead is 0.03 % of one core and a 12.5 MB footprint. Two things keep it from a 9. First, time to full **to 100 %** rests on a model that has never been checked above 85 % charge; that is the path most public users without a charge limit will see. Second, the battery's time estimates could not be checked live today, because the Mac is held at 80 % on AC. A replay of 5 days of this Mac's battery history says the time-left estimator is close to the best a predictor can do, but its spread is wide, which is unavoidable. A few label nits remain, mostly in the Battery drill-in.

**Standard:** Activity Monitor / System Settings / battery gauge parity · **Method:** code analysis + live measurement · **Reviewer:** independent subagent (round 3, reviewer B)

Evidence files cited as `round3-B/…` are in `/Users/davidghermansteinberg/Desktop/Home/Projects/Code/Mac Apps/MacStats/docs/reviews/2026-10-05-readings-accuracy/round3-B/`. Source paths are relative to the repo root `/Users/davidghermansteinberg/Desktop/Home/Projects/Code/Mac Apps/MacStats` (branch `fix/readings-accuracy`, commit `0afd11c`, v1.1.0).

## Calibration
- **Target:** native macOS 14+ menu-bar monitor on Apple Silicon first (tested on an M3 with 8 cores = 4 performance + 4 efficiency, 16 GB RAM, 16 KiB pages, macOS 26). It should degrade cleanly on Intel Macs and Macs without a battery. Users compare its numbers with Activity Monitor and System Settings, and use it to find what is eating CPU, RAM and battery.
- **What a 10 means here:** every number equals Apple's readout within measurement noise, all work is attributed to the responsible app the way Activity Monitor or iStat Menus do it, units can't be misread, estimates are honest against measured drain or charge, edge states behave, and overhead is negligible.
- **Anchors:** 3 = a primary reading badly wrong. 6 = roughly right with noticeable gaps. 9 = within noise everywhere testable, with only nitpicks left.
- **Terms used below:**
  - **Footprint** (`phys_footprint`): the memory the kernel charges to a process, and what Activity Monitor's Memory column shows.
  - **Responsible process:** the app macOS holds accountable for a process (Terminal for a tab's shell, an app for its XPC helpers).
  - **Gauge:** the battery's fuel-gauge chip, read through the IORegistry entry `AppleSmartBattery`.
  - **mAh:** charge (milliamp-hours). **Wh:** energy, which is mAh × volts ÷ 1000.
  - **Raw charge:** `AppleRawCurrentCapacity ÷ AppleRawMaxCapacity`, which runs about 1 point below the percent macOS shows.
  - **Hold:** Optimized Battery Charging pausing the charge (here at 80 %).
  - **Limit:** the manual charge limit (here 85 %).
  - **"AM %":** Activity Monitor's scale, where 100 % = one fully busy core. MacStats' own rows use a share of the whole Mac (100 % = all 8 cores).

## Scoreboard
| Area | Score | Verdict (one line) |
|---|---|---|
| Battery | 8/10 | Gauge figures exact. Time left is sound and near the practical limit on replayed history (not live). Time to full is validated up to the 85 % limit and the 80 % hold, but not toward 100 %. Small label issues. |
| CPU | 9/10 | Card and header match `top`, rows add up to the header, AM scale exact per process, and attribution right in every case I could create. The System row and app-row scale are labelled but are the only friction. |
| Memory | 9/10 | Memory Used = Activity Monitor's formula (8.82 vs 8.81 GB) and footprints match `footprint` exactly. Rows quietly leave out other users' processes. |
| Overhead | 9/10 | 0.03 % of one core and 12.5 MB with the popover closed; a breakdown scan costs ~5 ms of CPU per second. The popover's render cost while open wasn't measurable without clicking. |
| Network | 9/10 | Byte-exact against `netstat -ib` on the counted interfaces, VPN double counting avoided, macOS units. |

## Battery — 8/10
**Measured** (live 22:49–23:00; the Mac is plugged in and held at 80 % "AC attached; not charging". The harness replicates `AppModel.refreshBattery` and `chargeTarget` using the app's persisted state; logs are in `round3-B/battery-live-snapshot-and-gauge.log`):

| Reading | MacStats (harness) | Ground truth | Diff |
|---|---|---|---|
| Percent | 80 % | `pmset -g batt` 80 % | 0 |
| Status | "Plugged in, not charging" | `pmset`: "AC attached; not charging" | label match |
| Health | 99 % (4534 / 4563 mAh, truncated) | System Settings / `system_profiler`: Maximum Capacity 99 % | 0 |
| Cycle count | 128 | `system_profiler` 128 | 0 |
| Battery temperature | 30 °C (2999 centi-°C) | `ioreg` Temperature 2999 | 0 |
| Adapter | 30 W | `ioreg` AdapterDetails Watts 30 ("30W USB-C Power Adapter") | 0 |
| Power, last min (4 gauge minutes) | 3.74 / 7.25 / 7.98 / 4.02 W | gauge `AccumulatedSystemLoad` sums over the same minute (same values by construction). The instant `SystemLoad` at those updates was 2.9 / 19.6 / 12.4 / 2.3 W | the minute average is right. One instant reading was 2.7× off its minute. |
| Charge row | "Charge limit 80 %" | powerd: manual limit 85 % (end of charge), Optimized Charging hold 80 % | the number is where it is held now, **not** the user's limit (B2) |
| Remaining energy at 80 % | 40.0 Wh | not directly measurable; see the replay check below | — |
| Time left if unplugged now (first 2 min) | 699 min (persisted typical drain 3.43 W) | 5-day awake mean on battery 4.38 W → ~548 min | +28 % for 2 minutes only, then within +4 % (sim: `time-left-after-unplug-sim.txt`) |

**Replay against real history (not live; `round3-B/time-left-replay-powerlog.txt`).** This is the app's estimator fed 2,675 on-battery gauge rows from 14 sessions (Sep 28 – Oct 5) of `/private/var/db/powerlog`. The drain per awake interval comes from the coulomb counter (`PassedCharge`) × voltage, and intervals right after a sleep are dropped, as `gaugeInterval` does. These are the same days the constants were tuned on, so treat it as in-sample.

| Time left vs. what really happened | Median | Mean | Mean abs. error | 10th / 90th pct |
|---|---|---|---|---|
| vs. drain over the next 60 min | 0 % | +10 % | 32 % | −34 % / +74 % |
| vs. drain over the next 120 min | +8 % | +20 % | 32 % | −24 % / +77 % |
| vs. the rest of the session | +3 % | +8 % | 26 % | −26 % / +50 % |
| Baseline: a constant 4.38 W (the 5-day mean, only knowable afterwards) | −3 % | +5 % | 26 % | −28 % / +56 % |
| Baseline: last 10 minutes of drain (roughly how macOS behaves) | +39 % | +83 % | 96 % | −28 % / +134 % |

So the estimator is nearly as good as knowing the long-run mean in advance, and three times better than a short trailing average. The remaining spread is future load changes no estimator can see.

**Remaining-energy model** (`round3-B/remaining-energy-model-check.txt`). Across the 6 long discharges in the powerlog (85→21 % at most), the drop in `remainingWh` against the energy the battery actually delivered gives a model/measured ratio of 1.015–1.038. In other words, it is 1.5–4 % optimistic, which is small.

**Time to full / to the limit: not live-verified** (the Mac is held, not charging). I checked the model with a sweep of currents for a 4407 mAh pack (`time-to-full-model-sweep.txt`): from raw 20 % at 2.1 A it gives 154 min to 100 %, 95 min to 85 % and 86 min to 80 %. From raw 79 % at 1.9 A it gives 62 min to 100 %. These are plausible for a 30 W charger on an M3 Air. The repo's tests replay 4 real charges to the 85 % limit (mean error < 2 min) and one out-of-sample live charge to the 80 % hold (mean 1.1 min) (`Tests/MacStatsCoreTests/ChargeCalibrationTests.swift`).

**Works well:**
- Health, cycles, temperature and adapter come straight from the gauge with the right units: centi-°C (`BatteryTelemetry.swift:120`) and truncation like System Settings (`:54-57`). Health flicker is damped by taking the recent maximum (`:74-94`).
- "Power, last min" is the gauge's exact minute average (`intervalWatts`, `BatteryTelemetry.swift:163-166`) instead of one instant reading, and live it avoided a 2.7× error.
- Time left blends short, recent and long-run averages, uses only awake on-battery intervals (`gaugeInterval`, `:137-145`) and accounts for voltage sag (`:43-50`). The replay shows near-best accuracy, and it settles within 2 minutes of unplugging.
- Time to the limit and to the hold is calibrated on real charges and continuous across the knee. The charge target comes from powerd's policy file plus remembered and observed fallbacks (`BatteryCharging.swift:200-256`). Live, it read the limit and hold correctly.
- No battery: `readBattery()` returns nil, so the card shows "—" and isn't tappable (`OverviewView.swift:32-34`). On Intel (no telemetry), power falls back to V × I.
- Pure logic is heavily tested: estimator, replay, charge calibration, policy parsing and the resolver.

**Issues:**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| B1 | Medium | `BatteryCharging.swift:69-101` (the `targetPercent >= 100` branch, `:80-83`) | "Time to full" toward **100 %** uses a physical taper model that has never been checked against a charge above raw 85 %. The doc comment says no such data exists on this Mac. | Public users without a charge limit (or with Optimized Charging not holding) see this number on every charge. If the real taper is slower or faster, it will be off by tens of minutes with no test to catch it. | Log one full charge to 100 % (`ioreg` every 30 s, or the powerlog rows after it) and add it as an out-of-sample test like `LiveChargeTests`. Until then, consider showing the 100 % estimate only below ~80 % and "Almost full" above. |
| B2 | Low | `MacStatsApp.swift:273-274` → `BatteryDetailsCard.swift:40-41`; resolver `BatteryCharging.swift:228-231` | While Optimized Charging holds at 80 %, the drill-in says **"Charge limit 80%"** although the user's limit is 85 % (live, now). | It reads as if the setting were ignored or wrong. | Carry "hold vs limit" through to the view, e.g. "Held at 80% (Optimized Charging) · limit 85%". |
| B3 | Low | `MacStatsApp.swift:259-262` + `BatteryCharging.swift:88` | When the hold releases and charging resumes at the shown 80 % (raw 79.0 %), the target is still the hold (`percent <= hold`) and the raw target 0.79 is already passed. The result is "Almost done" while ~10 min of charging to 85 % remain, until the percent ticks to 81. | A wrong status during a resumed charge. | In `.charging`, ignore a hold the charge has already reached (`s >= hold − 1 %`) and target the end limit. |
| B4 | Low | `BatteryTelemetry.swift:43-50` | The remaining-energy model is 1.5–4 % optimistic over measured discharges. | Time left is a few percent long, in the harmful direction. | Lower the end voltage a little or fit the average voltage to the powerlog V-vs-charge curve; a ~3 % trim. |
| B5 | Low | `BatteryTelemetry.swift:163-164`, `:137-139` | On AC the gauge paused updates for 420 s live (UpdateTime 1791229734 → 1791230154). After any gap over 180 s, "Power, last min" falls back to one instant reading, which was up to 4.8× off its minute. | One misleading power figure for a minute after a pause or wake. | When the interval is rejected, show "—" or keep the previous minute's value rather than the instant one. |
| B6 | Low | `MacStatsApp.swift:319-323` (callers `:228`, `:246`, `:337/342`) | The recent full-charge readings for health are saved only on plug/unplug, on-battery gauge updates and quit. A launch while plugged in that later crashes or is force-killed loses them (live: `batteryNominalCapacityRecent` is absent from defaults 10 min after this launch). | Health can read 98 % for a minute after the next launch, the case the persistence was added for. | Also save when `nominalPeak.values` changes, throttled like the drain save. |
| B7 | Low | `MacStatsApp.swift:212-281` | The integration glue (hold vs limit vs percent, the at-limit "Almost done", the target label) lives in the app target and has no tests. B3 is exactly such a glue bug. | Regressions here are invisible to `./Scripts/test.sh`. | Move the per-reading decision into a pure function in `MacStatsCore` and test it. |

**Why 8:** Everything readable live is exact, and the two estimates are well engineered and validated where data exists. The time-left replay says it is near the best achievable. It isn't a 9 because the to-100 % path is unvalidated (B1, Medium) and the live state allowed checking neither estimate today. The Lows are labels and edge transitions.

## CPU — 9/10
**Measured** (harness = the real `BreakdownScanner` plus a copy of `BreakdownScanSession.scan`, `MacStatsApp.swift:525-546`; logs in `round3-B/cpu-*.log`). My shell runs in **VS Code's integrated terminal under Claude Code** (zsh → `claude` → zsh → Code Helper → Code), so every load below should land in the **Code** row.

| Reading | MacStats (harness) | Ground truth | Diff |
|---|---|---|---|
| Card % (1 s windows, idle) | 3.4, 2.7, 1.7, 4.3, 5.2, 13.0 % | `top` CPU usage (user + sys), same seconds give or take 1 s: 5.7, 2.7, 2.0, 6.1, 3.7, 12.5 % | within noise, given the 1 s misalignment |
| 4 × `yes`, header | 51–53 % | 4 × 99.8 % in `top` ÷ 8 cores = 50 %, plus ~2 % baseline | ≈ 0 |
| 4 × `yes`, each process | 12 % of the Mac = "100% of one core" | `top` 99.8 % each | ≤ 1 point |
| Rows vs header | row sum = header in every scan (System is the remainder) | — | 0 by construction |
| Code row under load | 50–52 % (AM 402–416 %) | 4 × 100 % + `claude` 1.7 % + helpers | ≈ 0 |
| Short-lived children (2 loops of ~ms `sh` processes, 7.8 s) | Code 24–26 % (the two reaping `bash` loops at ~95 % of one core each) | `/usr/bin/time`: 14.1 core-s / 7.76 s = 182 % of one core, plus ~10 % base | ≈ 0 |
| Orphaned `yes` (parent shell exited, ppid 1) | under Code, 12 % each | the responsible process is VS Code | correct app |
| Killed between scans | "Exited processes" child row 11 % (AM 92 %) in Code | 3 × ~0.26 s of unseen work ≈ 77 % of one core | ~+15 points AM; a deliberate upper bound |
| Another agent's `swift-driver` (another Claude Code session) | in Code, 71–97 % of one core | it runs under VS Code | correct app |
| Process names | "claude" (binary named "2.1.289"), "Code Helper (Renderer)" (full name) | `ps` | correct |
| Scan cost | 1–5 ms per scan steady, 6–14 ms first (CPU 0.07 s for 13 scans) | — | ~0.5 % of one core while drilled in |

**Works well:**
- One tick source for card and header: `host_processor_info` per CPU, which isn't rate-limited (`SystemReaders.swift:15-43`), with wrap-safe deltas (`CPUUsage.swift:19-27`).
- Per-process CPU uses Mach ticks converted to ns (`ProcessReader.swift:158-178`) and is divided by the core count, so rows, header and bars share one scale. The footnote "Share of the whole Mac (all 8 cores)" and an inline "N% of one core" on process rows bridge to Activity Monitor (`BreakdownView.swift:114`, `:179-185`).
- Attribution follows the responsible process first, then the parent chain, and sees past root `login` through the full table (`ProcessScan.swift:14-30`, `:62-116`). MCP-style background "apps" are only a fallback (`:48-54`). Live, everything above was right.
- Edge states: the first scan is a baseline shown as "Measuring…" with a quick second scan (`MacStatsApp.swift:362-374`). Reused pids are told apart by start time (`ProcessScan.swift:96`, `:225`). Reaped children's CPU is credited and capped by what the machine actually did (`:360-388`), and work by vanished processes gets its own "Exited processes" row (`:407-419`). Stale tick reads give no header rather than 0 % (`:353-355`).
- Very thorough pure-logic tests (`ProcessScanTests.swift`, 50+ cases).

**Issues:**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| C1 | Low | `ProcessBreakdown.swift:158-163`, tooltip `BreakdownView.swift:479-482` | **System** lumps the kernel, WindowServer, other users' daemons and anything run with `sudo` or a setuid tool. Live, `top` (setuid root) went there, at 37 % of one core in one scan. It can't be expanded. | During GPU-heavy or sudo work, a user sees "System 20 %" and can't tell what it is. It's unavoidable without a privileged helper and is explained in the tooltip. | Leave the row; per-process figures for other users' processes need root (`ps` and `top` are setuid root for this reason). If ever wanted, only a privileged helper could split it. |
| C2 | Low | `BreakdownView.swift:163`, `:175`, `:188-191` | App rows show the share of the Mac ("52%"). Activity Monitor's figure (415 %) appears only in the tooltip or context menu for app rows; process rows show it inline. | Someone comparing VS Code with Activity Monitor at a glance sees an 8× gap until they hover. | Add the per-core sub-line to app rows too, as on process rows. |
| C3 | Low | `ProcessScan.swift:20-24` | The responsible app wins over the process itself. A GUI app started by its binary path from a terminal (`/Applications/X.app/Contents/MacOS/X`) is merged into the terminal app's row. | Rare, but the app then has no row of its own to Quit from. | Check `appPIDs.contains(current)` before the responsible pid when `current` is a *regular* app with windows. |
| C4 | Low | `ProcessScan.swift:48-54` | Background agents with a bundle id and accessory policy get their own top-level "app" rows: loginwindow, chronod, coreautha, photolibraryd, "WebThumbnailExtension Graphics and Media" (`round3-B/memory-rows.log`). | Clutter; odd names for WebKit GPU helpers. | Treat accessory-policy apps with no windows or Dock presence as fallbacks, or group them under "Other processes". |
| C5 | Low | `ProcessScan.swift:261-276` | CPU of short-lived children is credited to the reaping parent, which reads e.g. "bash 95% of one core", rather than to the short-lived commands. | Correct per app; the process row names the parent loop, not the compiler or `sh` that did the work. | Optionally label credited time as a child row ("Finished child processes") like the exited row. |
| C6 | — (not live-verified) | `ProcessScan.swift:104-107` | The Terminal.app case (a root `login` in the chain) wasn't tested live because Terminal isn't running and I may not launch apps. It is unit-tested (`childUnderRootLoginMapsToApp`), and the responsible-pid path covers it independently. | — | — |

**Why 9:** Every number I could produce matched ground truth within noise, rows add up to the header by design, attribution was right in all six live scenarios, and the logic is well tested. Only labelling and clutter nits remain.

## Memory — 9/10
**Measured** (`round3-B/memory-card.log`, `memory-rows.log`, `memory-footprint-check.log`):

| Reading | MacStats (harness) | Ground truth | Diff |
|---|---|---|---|
| Memory Used | 8.82 GB (App 4.92 + Wired 1.93 + Compressed 1.97) | Activity Monitor formula with `sysctl vm.page_pageable_internal_count − vm.page_purgeable_count` + wired + compressed (`vm_stat`): 8.81 GB | 0.01 GB (MacStats uses `internal_page_count`, 260 pages more) |
| Total | 16.0 GB | `hw.memsize` 17179869184 B | 0 |
| Pressure | normal (kernel level 1) | `memory_pressure`: 74 % free, normal | match |
| claude (pid 14424) | 339 MB | `footprint`: 355,076,424 B = 338.6 MiB | 0 |
| Code Helper (Plugin) (14126) | 352 MB | `footprint`: 368,838,816 B = 351.8 MiB | 0 |
| Code app row | 1.9–2.0 GB (32–45 processes) | `footprint` of the 21 processes in its parent tree 1.78 GiB. The row also includes responsibility-attributed and transient processes. | consistent |

**Works well:** Memory Used matches Activity Monitor's definition and its parts add up with consistent rounding (`MemoryStats.swift:66-94`). Per-process memory is the physical footprint (`ProcessReader.swift:43`), in binary MB/GB like Activity Monitor. Memory needs no "Measuring" state, and pressure is the kernel's real level (`SystemReaders.swift:144-149`).

**Issues:**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| M1 | Low | `ProcessReader.swift:18-36`; footnote `BreakdownView.swift:117` | The rows cover only the user's processes. WindowServer, root daemons and other users' processes (RSS ~2.6 GB here) appear nowhere, and the footnote only explains why rows can add up to *more* than Memory Used. | A user hunting RAM can't see a WindowServer leak, which Activity Monitor would show. | Say it in the footnote ("Your processes only; macOS's own are in App Memory above"). |
| M2 | Low | `ProcessBreakdown.swift:171` | "Other processes" always sorts last even when it is the largest row (2.4 GB here). | Easy to scroll past the biggest consumer. | Fine as a design choice; consider showing its total in the parts card. |

**Why 9:** Primary numbers match within noise and the units are Activity Monitor's. Only scoping and labelling nits remain.

## Overhead — 9/10
**Measured** (`round3-B/overhead-idle.log`): the installed MacStats (pid 82366), popover closed since launch.

| Reading | Value | Ground truth / budget | Verdict |
|---|---|---|---|
| CPU, popover closed | 0.24 s of CPU in 14:00 = **0.03 % of one core** | `ps -o time` | negligible |
| Memory, popover closed | footprint **12.5 MB** (peak 13.0 MB) | `footprint -p` | negligible |
| Per-process scan while closed | none: the scan timer exists only in `enterBreakdown` and is cancelled on close (`MacStatsApp.swift:362-382`, `:134-142`) | code | ✓ |
| One breakdown scan | ~5 ms of CPU (13 scans = 0.07 s), 1 Hz → ~0.5 % of one core; harness peak footprint 4.3 MB (`/usr/bin/time -l`) | harness | small |
| Idle sampler | every 10 s with 2 s tolerance; no publishing while closed (`MetricsStore.swift:76-99`) | code | ✓ |

**Issues:** O1 (Low, not measured): the popover's own rendering cost while open (0.5 s ticks plus SwiftUI) couldn't be measured, because opening it needs a click and the rules forbid that. In the app, the scan also pays LaunchServices lookups my CLI harness doesn't, so expect a few ms more per scan.

**Why 9:** The closed-state cost is about as low as a menu-bar app gets. The open cost is unmeasured but bounded by design.

## Network — 9/10
**Measured** (`round3-B/network-counters.log`): `readNetCounters()` rx 7,882,188,612 / tx 2,240,902,041 B equals the `netstat -ib` sum over non-loopback, non-`utun`/`ipsec`/`bridge` interfaces (en0 + awdl0) **to the byte**. Rates are a 1 s trailing difference, shown in 1000-based KB/s and MB/s like Activity Monitor (`NetworkThroughput.swift:20-23`).

**Issues:** N1 (Low) — on open, the first rate is averaged over the idle sampler's up-to-10 s window (`MacStatsApp.swift:172-182`), so the first frame is smoother than later ones. N2 (Low) — `awdl0` (AirDrop/peer) traffic is counted along with en0, which is arguably right but differs from what a user sees as "internet" speed.

**Why 9:** Exact counters and sensible exclusions; only nits.

## Cross-cutting issues
- **App-layer glue is the untested layer.** The core math is thoroughly tested (244 tests pass, `./Scripts/test.sh`, 6 s). The decisions in `AppModel.refreshBattery` and in `BreakdownView` (target vs hold vs percent, which label shows, per-core lines) are not, and the one real logic slip I found (B3) lives there.
- **Holds vs limits** need a clear model in the UI, not just the target percent (B2, B3).
- **Units are consistent and labelled.** CPU is a share of the Mac with "of one core" bridges, memory is binary GB like Activity Monitor, network is decimal KB/s like Activity Monitor, and power is "W, last min".

## Top fixes (ranked by impact ÷ effort)
1. **B2 — "Held at 80% (Optimized Charging) · limit 85%"** instead of "Charge limit 80%". Pass `hold` vs `limit` from `chargeTarget` (`MacStatsApp.swift:250-275`) to `BatteryDetailsCard.swift:40-41`. Tiny change; the user sees it daily.
2. **B3 — don't target a hold the charge has already reached** when charging resumes (`MacStatsApp.swift:259-262` / `BatteryCharging.swift:228`), so there is no false "Almost done".
3. **C2 — show "N% of one core" on app rows too** (`BreakdownView.swift:148-176`). It removes the main Activity Monitor comparison confusion.
4. **B1 — validate time to 100 %** with one logged full charge (an `ioreg` loop, or the powerlog after it) as an out-of-sample test. Until then, suppress the 100 % estimate above ~80 %.
5. **B7 — move the per-reading battery decision into a pure `MacStatsCore` function with tests** (it would have caught B3). Also save health readings when they change (B6) and avoid the instant-power fallback after gauge gaps (B5).

## Method & limits
- **Code read:**
  - all of `Sources/MacStatsCore/*` (battery telemetry/charging/estimator/parse, process reader/scan/breakdown, system readers, memory, network, refresh, store)
  - app glue: `MacStatsApp.swift`, `BreakdownView.swift`, `BatteryDetailsCard.swift`, `StatCard.swift`, `OverviewView.swift`, `MemoryPartsCard.swift`, `MenuBarLabel.swift` (static glyph, no live menu-bar value)
  - test names and the replay/calibration tests.
- **Harnesses** were built outside the repo from the real core sources with the 26.5 SDK. The breakdown harness copies `BreakdownScanSession.scan` verbatim (NSWorkspace anchors, bundle-id cache, clock-then-process order). The battery harness replays `refreshBattery`/`chargeTarget` with the app's persisted defaults. Two harness copies are in `round3-B/harness-*.swift`.
- **Ground truth:** `top` (setuid root, so its own CPU lands in System), `ps`, `footprint`, `vm_stat`, `sysctl`, `memory_pressure`, `ioreg -rn AppleSmartBattery`, `pmset -g batt`, `system_profiler SPPowerDataType`, `/Library/Preferences/com.apple.powerd.charging.plist`, `netstat -ib`, and the powerlog (`/private/var/db/powerlog/Library/BatteryLife/` plus its Archives, Sep 28 – Oct 5).
- **Controlled load:** at most 4 × `yes` for ≤ 8 s, started and killed from my shell. All of my processes were stopped (`pgrep` clean; one `./h` still running belongs to the other reviewer's scratch folder and was left alone). Another reviewer's `swift` builds ran during two of my scans; they show up correctly attributed under Code and didn't change the conclusions.
- **Limits:**
  - On AC and held at 80 %, so time left and time to full could not be checked live. They were judged from the powerlog replay (in-sample to the tuning data) and the repo's charge tests.
  - Terminal.app wasn't running, so the root-`login` chain was checked only through unit tests.
  - The popover couldn't be opened (no clicks), so the open-state render overhead and the exact on-screen strings were verified from code, not screenshots.
  - The powerlog lacks `AccumulatedSystemLoad`, so the replay used coulomb-counter drain instead of the app's whole-Mac power.
  - Activity Monitor itself wasn't driven; its formulas and `footprint` stood in for it.
