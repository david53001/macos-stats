# MacStats readings accuracy review — 2026-10-05
**Overall: 8/10** — On the owner's scale this is "basically perfect, with nitpicks", just. Every primary number I could test live matched its ground truth within measurement noise: the CPU card and breakdown header matched `top` within 1.5 points (e.g. 64.3 % vs 64.4 % under a 4-core load), per-process CPU matched `top` exactly (100 % of a core = 12.5 % of the Mac), memory "used" equals Activity Monitor's formula computed from `vm_stat` to the megabyte, per-process memory matched Apple's `footprint` tool within 0.5 MiB, cycle count and health match System Settings, and the battery power that feeds "time left" agrees with the battery's own current accumulator within 1 %. Attribution was right in every case I could produce (VS Code's integrated terminal, Claude Code, orphaned shells, crash handlers, XPC services, short-lived processes). What keeps it from a 9: the Battery drill-in's per-app power loses all work done by processes that live less than a second (a build), the "Power now" figure is a single up-to-60-second-old instant that can be 4× off the minute's average, the time-to-full model is untested on real charging, and a handful of labelling / edge-state nitpicks. Overhead is negligible.

**Standard:** Activity Monitor / System Settings / battery gauge parity · **Method:** code analysis + live measurement · **Reviewer:** independent subagent (reviewer A)

## Calibration
- **What a 10 means here:** every number matches Apple's own readout within measurement noise (Activity Monitor CPU and Memory columns, "Memory Used", System Settings → Battery, the battery gauge), all work is attributed to the responsible app, units and scales can't be misread, estimates are honest against measured drain/charge, edge states behave, overhead is negligible.
- **Anchors used:** 3 = a primary reading badly wrong or major work missing; 6 = roughly right with noticeable gaps; 9 = within noise everywhere I could test, attribution right for terminal/IDE/helper/XPC, labels clear, edge states handled, pure logic tested, negligible overhead.
- **Scale:** 8–10 basically perfect (nitpicks only), 4–7 great with noticeable issues, 1–3 not to standard. An area with a High issue can't score 8+.
- **Weighting of the overall score:** Battery, CPU and Memory dominate; Overhead matters (it's a promise of the app); Network is minor.

### Terms used below
- **Physical footprint** — the memory a process is charged for by the kernel (its private, dirty and compressed pages). It is exactly what Activity Monitor's *Memory* column shows; Apple's `footprint -p <pid>` tool prints it.
- **Memory Used (Activity Monitor)** — App Memory + Wired + Compressed, where App Memory = anonymous ("internal") pages minus purgeable pages. File cache is *not* counted.
- **Responsible process** — the app macOS holds accountable for a process (e.g. VS Code for everything in its terminal, Chrome for its helpers, an app for its XPC services). Activity Monitor and privacy prompts use it.
- **Battery gauge** — the battery's fuel-gauge chip, read through the `AppleSmartBattery` IORegistry entry (`ioreg -rn AppleSmartBattery`). It refreshes about once a minute (`UpdateTime`).
- **mAh / mWh / W** — milliamp-hours is charge; multiply by volts to get energy (Wh); watts is energy per hour.
- **SystemLoad** — the gauge's whole-Mac power draw (mW) on Apple Silicon, with running sums (`AccumulatedSystemLoad` / `SystemLoadAccumulatorCount`) that give the exact average between two gauge updates.
- **PackCurrentAccumulator** — the gauge's running sum of battery current (mA per ~1 s count); its slope × voltage is an independent measure of the battery's real output power. I used it as ground truth for drain.
- **% of the whole Mac vs % of one core** — MacStats shows CPU as a share of all 8 cores (100 % = every core busy). Activity Monitor's per-process column uses 100 % = one core, so it reads 8× higher on this Mac.

## Scoreboard
| Area | Score | Verdict (one line) |
|---|---|---|
| Battery | 7/10 | Percent, cycles, health, temperature and average power all verified; time left is honest to measured drain; per-app power misses short-lived work and "Power now" is a noisy instant; time-to-full unverified. |
| CPU | 8/10 | Card, header and every per-process value matched `top`; attribution right for every live case incl. short-lived processes; only labelling/edge nitpicks. |
| Memory | 8/10 | Card = Activity Monitor formula exactly, per-process = `footprint` within 0.5 MiB; rows and header measure different things with no reconciling row. |
| Overhead | 9/10 | 0.03 % of one core and 12–13 MB with the popover closed; a breakdown scan costs 1.2–6 ms per second. Popover-open cost not measurable here. |
| Network | 7/10 | Byte deltas identical to `netstat`; VPN double-counting is a known, unhandled risk; binary units. |

## Battery — 7/10
**Measured** (on battery, 62–65 %, 20:38–21:03; logs `gaugelog.txt`, `packacc.txt`, `batt-harness.txt`, `estimator-replay.txt`):

| Reading | MacStats (harness) | Ground truth | Diff |
|---|---|---|---|
| Battery % | 64 % | `pmset -g batt`: 64 % | 0 |
| Cycle count | 128 | `system_profiler`: 128 | 0 |
| Health (Maximum Capacity) | 98 % on one read (4505/4563); the app shows the peak of the last 10 gauge reads → 99 % (peak 4558 in my log) | System Settings / `system_profiler`: 99 % | 0 after a few minutes; −1 on a fresh launch is possible |
| Battery temperature | 30.1 °C (`Temperature` 3013 centi-°C) | `ioreg` 3013 | 0 (unit conversion correct) |
| Average power (feeds time left) | SystemLoad accumulators: **3.78 W** (20:44:19–20:49:06) | PackCurrentAccumulator × V: **3.81 W** | −0.7 % |
| Average power, whole log | SystemLoad accumulators: **2.798 W** (20:44:19–21:02:47, 1108 s) | PackCurrentAccumulator: −237.9 mA × 11.78 V = **2.803 W** | −0.2 % |
| "Power now" | instant SystemLoad at the last gauge update: e.g. 1.80 W, 13.21 W | same minute's true average: 8.62 W, 3.19 W | single instant, up to 4.8× off the minute's average, up to 60 s stale |
| Energy left | 29.5 Wh (2647 mAh × mid-point of 11.82 V and 10.5 V) | design 52.6 Wh × 99 % × 60 % raw ≈ 31 Wh; raw mAh itself jumps ±50 mAh between gauge updates | plausible, ±2–5 % |
| Time left (replay of my gauge log through the real `BatteryEstimator`, session only, no persisted prior) | 21:02: expects **2.55 W** → **11 h 28 m** (29.3 Wh) | macOS (`pmset`): 12 h 05 m, implying ~2.4 W; measured drain: 3.12 W mean over the 21 min session, 1.9 W over the last 5 min | expectation sits between session mean and recent drain, as designed; ~5 % shorter than macOS |
| Time to full / charge limit | not live-verified (on battery) | — | — |

**Works well:**
- Percent from IOPS (`parseBattery`, `BatteryParse.swift:41-46`) matches `pmset`; cycle count and temperature units (centi-°C, `BatteryTelemetry.swift:110`) are right.
- Health uses `NominalChargeCapacity / DesignCapacity`, truncated, and the peak of the last 10 gauge reads (`RecentMax`, `MacStatsApp.swift:195`) — the right fix for a value that swings 4497–4558 mAh minute to minute.
- The average-power input is excellent: the gauge's SystemLoad running sums agree with the battery's own current accumulator within 0.7 %, so the estimator is fed true whole-Mac drain. Intervals spanning sleep are rejected (`gaugeInterval`, `BatteryTelemetry.swift:127`), plugged-in time is excluded, and both are unit-tested.
- The time-left estimator is honest: replaying my 21-minute gauge log through the real `BatteryEstimator` (`estimator-replay.txt`) gives an expected draw (2.55 W at the end) that sits between the session mean (3.12 W, inflated by two reviewers' compiles) and the last 5 minutes (1.9 W), and moves smoothly — 5.5 W after the first busy minutes, settling as the Mac went quiet — while macOS's own figure jumped between 10 h 25 m and 12 h 05 m over the same period. The app's own persisted drain average after 22 min was 3.79 W, consistent with the measured 3.12 W session mean plus the earlier busy minutes. Bias-corrected averaging keeps one spike from dominating (tested).
- Remaining energy accounts for the voltage sag to a 3.5 V/cell end (`remainingWh`, `BatteryTelemetry.swift:43`) — a mid-point of ~3.72 V/cell, close to a real Li-ion curve.
- Unplug/plug is picked up at once through an IOPS notification and never measured across (`MacStatsApp.swift:184`).
- 35 estimator/charging tests + 15 parse tests on the pure logic.

**Issues:**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| B1 | Medium | `ProcessScan.swift:153` (`ProcessSampler.ingest`), energy path | Per-app power (Battery drill-in) only counts processes that are alive at two scans; energy of processes that start and exit within one 1 s scan is lost — unlike CPU, there is no reaped-children energy to credit. Measured: two cores busy with back-to-back short `dd` processes showed **0.13 W** for the app (`h-energy-burst.txt`), while the same two cores running long-lived `yes` showed **6.2 W**; the CPU view of the short-lived load was correct (25 %). | A build (many sub-second compiler processes) or a script loop is nearly invisible in "which app is draining my battery". | Credit the parent with energy in proportion to its credited child CPU time (watts-per-CPU-second of the app's own live processes, or a per-core-type average), and/or label rows "CPU power of running processes". |
| B2 | Low | `BatteryDetailsCard.swift:44-46`, `BatteryTelemetry.swift:63` | "Power … now" is the instantaneous `SystemLoad` at the last gauge update: one instant, refreshed only every ~60 s. In my log it read 1.80 W in a minute that averaged 8.62 W, and 13.21 W in one that averaged 3.19 W. | A user sees "13 W now" for a minute after a spike that's long over. | Show the last gauge interval's average (`averageWatts(from:to:)`, already computed) as "now", or label it "last reading". |
| B3 | Low | `BatteryCharging.swift:38-48` | Time to full is a model (constant current to 80 %, then 0.45× taper) calibrated on one charge log; above the knee the measured current is treated as constant, although it keeps falling, so the last 10–15 % will be under-estimated. Not verifiable live. | Time to full near the end of a charge reads short. | Validate against 2–3 logged charges; above the knee apply a residual taper to the measured current. |
| B4 | Low | `BatteryCharging.swift:71-73` | Any charging→"not charging" stop between 50 and 99 % is learned and persisted as a charge limit — including a thermal or weak-adapter pause. The next charge then shows "Time to 72 %" until it passes 72. | Rare wrong label/target. | Learn a limit only when the stop repeats at the same percent, or when powerd's file confirms a policy. |
| B5 | Low | `MacStatsApp.swift:259-264`, `:205-207` | `saveEstimator` stamps `lastEstimatorSave` even when there's nothing to save (first launch), and nothing is saved at quit; up to 10 min of learned drain is lost on every quit/relaunch. (Confirmed: `defaults` had no typical value 6 min after launch.) | Slightly slower convergence after relaunch. | Only stamp after a real save; save in `applicationWillTerminate`. |
| B6 | Low | `BatteryDetailsCard.swift:46` | "avg" is the mean since unplugging *or since MacStats launched*, whichever is later, but the label doesn't say so. | Expert-only confusion. | "avg since unplug" / tooltip. |
| B7 | Low | `MacStatsApp.swift:195` | On a fresh launch the health peak has one reading, so it can read 98 % while System Settings says 99 % (harness single read: 98 %). | First minutes only. | Persist the last peak. |

**Why 7:** every battery number I could check is right, and the most important derived number (time left) is built on verified inputs and behaves honestly. But one of the two things the Battery drill-in exists for — "which app is draining my battery" — misses a whole class of work (B1, Medium), "Power now" is noisier than its label suggests, and the charging side can't be verified and rests on a lightly validated model. Noticeable issues, not big ones → 7.

## CPU — 8/10
**Measured** (`h-cpu-load.txt` + `top-load.txt`: 4 × `yes` from Claude Code in VS Code's integrated terminal; `h-cpu-burst.txt` + `top-burst.txt`: two loops of short-lived `dd`):

| Reading | MacStats (harness) | Ground truth (`top`, same seconds) | Diff |
|---|---|---|---|
| Header / card, 4-core load (5 consecutive 1 s scans) | 66.3 / 63.0 / 63.8 / 64.3 / 64.0 % | 66.9 / 64.5 / 63.6 / 64.4 / 64.1 % (user+sys) | ≤ 1.5 pt (windows aligned to ~0.3 s) |
| Header / card, short-lived burst (4 scans) | 33.3 / 27.6 / 30.7 / 27.3 % | 33.9 / 27.4 / 30.9 / 28.0 % | ≤ 0.7 pt |
| One `yes` process | 12 % of Mac (context menu: "100 % of one core") | 99.0–101.0 % of one core | 0 |
| `yes` × 4 attributed to | Code (VS Code), 4 children at 12 % each | parent chain `yes → zsh → claude → zsh → Code Helper → Code` | correct |
| Short-lived `dd` loops (each `dd` ~0.2 s) | Code 25 %: each `bash` parent 96–97 % of a core via reaped-child credit | 2 cores busy, `top` 25–27 % above idle | correct |
| Rows vs header | rows sum = header exactly every scan (System row = remainder, 0.3–12 %) | — | by construction |
| Root processes (WindowServer, mds) readable unprivileged? | no — `proc_pidinfo`/`proc_pid_rusage` return EPERM (`rootprobe`) | `top`/`ps` are setuid root | the "System" row is the honest limit |

Attribution sample (`attribution-sample.tsv`): Claude Code CLI, its node children, orphaned `zsh` (ppid 1), `sourcekit-lsp`, `SourceKitService` (launchd child) → **Code**; `chrome_crashpad_handler` (ppid 1) → its browser/app; `com.apple.SafariPlatformSupport` XPC → **Spotify** (its responsible app); widget extensions and system daemons → Other processes.

**Works well:**
- Per-process CPU uses `ri_user_time + ri_system_time` converted from Mach ticks to ns (`ProcessReader.swift:42`, `:158-178`), overflow-safe — the old 41.7× bug is gone and is unit-tested.
- Attribution asks macOS for the responsible app first, then walks parents, and can see past unreadable root processes (`ProcessScan.swift:9-20`, `ProcessReader.swift:89-103`), cached per pid + start time so pid reuse can't misattribute (`ProcessScan.swift:59`).
- Work of processes that came and went between scans is credited to the surviving parent through the kernel's reaped-children time, capped by what the machine actually used (`ProcessScan.swift:159-192`, `:228-245`) — verified live with sub-second `dd` processes.
- Header and rows are measured over the *same* interval and the System row makes them add up (`addingSystemRow`, `ProcessBreakdown.swift:154`).
- Scale is labelled ("Share of the whole Mac (all 8 cores)", `BreakdownView.swift:105`) and the per-core figure is one right-click away (`:175`).
- 28 scan tests + 16 breakdown tests cover the Terminal root-`login` chain, pid reuse, reaped-child debt and caps.

**Issues:**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| C1 | Low | `ProcessScan.swift:14`, `MacStatsApp.swift:407` | Every `NSRunningApplication` is an anchor, including processes that *disclaim* responsibility. Claude.app's MCP server (`disclaimer → npm exec @modelcontextprotocol/server-pdf`, 178 MB with its `node` child) shows as its own "app" named by its command line, "npm exec @modelcontextprot…", instead of under Claude. | Odd row name; the work isn't with the app that started it. | When the responsible pid is the process itself and it has no bundle (`bundleURL == nil`), keep walking the parent chain. |
| C2 | Low | `BreakdownView.swift:105`, `:251` | Values are % of the whole Mac, 8× smaller than Activity Monitor's per-process figures. Labelled in the footer and context menu, but the row itself carries no hint. | Users comparing with Activity Monitor at a glance will think MacStats is wrong. | Optional "per core" toggle, or show "of 8 cores" in the header. |
| C3 | Low | `CPUUsage.swift:3-6`, `:17-21` | Tick counters are `UInt32`; the idle count (≈ 700/s here) wraps after ~70 days of uptime, giving one sample with a negative total delta → 0 %. | One wrong point every couple of months. | Compute deltas with wrapping subtraction (`&-` on UInt32) per field. |
| C4 | Low | `RefreshScheduler.swift:42` | First CPU values in a breakdown cover only 0.5 s (System row was 12 % at 0.5 s vs ~1 % later in my run). | Brief noisy first frame. | Acceptable; or show the first numbers dimmed. |
| C5 | Low (risk) | `ProcessScan.swift:64-71` | The Terminal.app path (root `login` in the chain) is unit-tested but could not be produced live without opening a Terminal window (not allowed). | Residual, tested risk. | — |

**Why 8:** every live number matched `top` and every attribution case I could produce was right, including the hard ones (short-lived processes, orphaned shells, XPC). The remaining items are labelling and rare edge cases → 8. Not 9 because of the Activity-Monitor-scale gap a casual user will still trip on and the unverified Terminal.app path.

## Memory — 8/10
**Measured** (`mem.txt`):

| Reading | MacStats (harness) | Ground truth | Diff |
|---|---|---|---|
| Card "used" | 10.91 / 16.00 GB | Activity Monitor formula from `vm_stat` at the same moment: (Anonymous 411 710 − purgeable 7 294 + wired 109 086 + compressor 201 613) × 16 KiB = 10.91 GiB | 0.00 |
| Card earlier run | 10.55 GB | 10.55 GiB | 0.00 |
| Pressure | normal | `memory_pressure`: 69 % free (normal) | — |
| VS Code main | 99.7 MiB | `footprint`: 100 MB | ≤ 0.5 |
| VS Code renderer | 212.2 MiB | 212 MB | ≤ 0.5 |
| Chrome main | 762.5 MiB | 762 MB | ≤ 0.5 |
| Claude renderer | 398.8 MiB | 399 MB | ≤ 0.5 |
| Spotify renderer | 248.1 MiB | 248 MB | ≤ 0.5 |
| Rows total | 10.46 GB over 518 user processes | header 10.91 GB | different quantities (see M1) |

**Works well:**
- "Used" is App Memory (internal − purgeable) + wired + compressed with 16 KiB pages read from the kernel (`MemoryStats.swift:50-55`, `SystemReaders.swift:25-49`) — the Activity Monitor definition, not the old active-pages one; GiB displayed as "GB" like Activity Monitor.
- Pressure is the kernel's own level (`kern.memorystatus_vm_pressure_level`), not a heuristic.
- Per-process value is `ri_phys_footprint` (`ProcessReader.swift:43`), Activity Monitor's Memory column, matching `footprint` to within rounding. RSS is only a fallback.
- The scan covers all 518 user processes, grouped by the same verified attribution as CPU; the bar scale is total RAM, so bars are true shares.

**Issues:**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| M1 | Low | `BreakdownView.swift:106`, `ProcessScan.swift:263-267` | Rows (your processes' footprints, which include their compressed pages) and the header (system-wide used incl. kernel, WindowServer, other users) measure different things, and unlike CPU there is no remainder row. Footnote says "Total also counts macOS and the kernel". Here they were 10.46 vs 10.91 GB — close by coincidence; they can diverge either way. | Users expect rows to add up to the header the way CPU's do. | Add a "System & other users" row = max(0, used − Σ rows) with a tooltip, or show "Σ rows" in the header. |
| M2 | Low | C1 above | Same anchor issue: Claude's MCP server (178 MB) is its own row. | — | See C1. |
| M3 | Low | — | Activity Monitor itself could not be opened (no UI interaction allowed); parity is against its documented formula computed from `vm_stat`. | Residual. | — |

**Why 8:** every memory number matches its ground truth exactly; the only issues are presentation (rows vs header) → 8.

## Overhead — 9/10
**Measured:**

| Reading | Value | Notes |
|---|---|---|
| MacStats CPU, popover closed | 0.29 s CPU in 15 min 41 s, 0.43 s in 30 min 43 s = **0.02–0.03 % of one core** | `ps -o time`; `top -stats power`: 0.0 |
| MacStats memory, popover closed | footprint **12–13 MB** (peak 13 MB), RSS 65 MB | `footprint -p` |
| One breakdown scan (≈520 processes, CPU) | **1.2–6.3 ms** (median ~2.4 ms in steady state; 5.5 ms when scanning every 0.2 s) | harness `timing`/`cpu` modes, once per second while a breakdown is open ≈ 0.1–0.6 % of one core |
| Idle sample (CPU ticks + net + VM) | 28 µs | every 10 s |
| Battery read (IOPS + 11 gauge keys) | 219 µs | every 10 s |

**Works well:** the per-process scan exists only between `enterBreakdown` and `exitBreakdown` (`MacStatsApp.swift:279-297`) and is torn down when the popover closes (`:104`); idle work is microseconds every 10 s with 2 s timer tolerance; memory is handed back after close (`malloc_zone_pressure_relief`).

**Issues:**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| O1 | Low | `MacStatsApp.swift:407` | `NSWorkspace.shared.runningApplications` is copied every scan (allocations per tick). | Negligible today. | Cache, refresh on `didLaunch/didTerminate` notifications. |
| O2 | Low (limit) | — | Popover-open cost (0.5 s SwiftUI ticks) could not be measured without clicking the menu-bar item. | Unverified. | — |

**Why 9:** negligible cost where it matters (closed), a few ms per second only while a breakdown is open.

## Network — 7/10
**Measured:** three paired reads, harness vs `netstat -ib` (sum of non-loopback interfaces): byte **deltas identical** (rx +8 820 B, tx +92 044 B in both); absolute counters differ by a constant ~44 KB (an interface `netstat` doesn't list), which cancels in rates.

**Works well:** 64-bit per-interface counters via `IFMIB_IFALLDATA` (no 4 GiB wrap), loopback skipped, 1 s trailing window while open.

**Issues:**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| N1 | Medium (unverified) | `SystemReaders.swift:59-60`, `:80` | VPN tunnels (`utun*`) are summed with the physical interface, so traffic through a VPN can be counted twice (the code says so). Not testable here (no VPN). | Up to 2× download speed for VPN users. | Skip `utun*`/`ipsec*`/`ppp*` (or skip interfaces without a link-layer address) and sum physical ones only. |
| N2 | Low | `OverviewView.swift:65-68` | Rates use 1024-based units labelled KB/s and MB/s. | Up to 4.9 % vs tools that use 1000. | Pick one convention and document it. |

**Why 7:** what it measures is exact, but a common setup (VPN) can double it.

## Cross-cutting issues
- **Groups that can't be broken down are labelled honestly.** Root processes can't be read without privileges (I verified EPERM), and the app says so in the System row's tooltip. Good.
- **Instants vs averages.** CPU and network use averages over a window; battery "Power now" uses an instant. Consistency would help (B2).
- **Tests are strong on pure logic** (184 tests pass under `./Scripts/test.sh`, `tests.txt`), but there is no recorded-data test for the charge-time model and no test that energy credit exists (B1, B3).

## Top fixes (ranked by impact ÷ effort)
1. **B2 — show the last gauge interval's average as "Power now"** (`BatteryDetailsCard.swift:44`, value already computed by `averageWatts`). Minutes of work; removes up-to-4.8× swings.
2. **N1 — skip VPN tunnels in the network sum** (`SystemReaders.swift:80`). A few lines; removes a possible 2× error.
3. **B1 — credit short-lived children's power to the parent** (`ProcessScan.swift:153-191`), proportionally to the credited CPU time. Makes builds visible in the Battery drill-in.
4. **C1/M2 — don't treat self-responsible, bundle-less processes as apps** (`ProcessScan.swift:14`). Puts Claude's MCP servers under Claude.
5. **M1 — add a reconciling "System & other users" row to Memory** (`ProcessScan.swift:263`), mirroring CPU.
(Then B5, C3, B4, B7, N2.)

## Method & limits
- **Repo:** `/Users/davidghermansteinberg/Desktop/Home/Projects/Code/Mac Apps/MacStats`, branch `fix/readings-accuracy` (commit `c4d208d`, v1.1.0); `file:line` references are relative to it. The installed app was `~/Applications/MacStats.app` 1.1.0.
- **Harness:** `main.swift` (copied here) compiled together with every `Sources/MacStatsCore/*.swift` file except `AppleSensorReader.swift` (C shim; not in scope) using `swiftc -sdk …/MacOSX26.5.sdk -O`. It replicates the app glue: `procScanTick` order (clocks, then processes), `NSWorkspace.runningApplications` anchors, row naming, value formatting, scan cadence (0.5 s then 1 s), and the battery estimator feed (only on-battery gauge intervals that pass `gaugeInterval`).
- **Ground truth:** `top -l N -s 1` (same seconds as harness scans), `footprint -p`, `vm_stat`, `memory_pressure`, `pmset -g batt`, `system_profiler SPPowerDataType`, `ioreg -rn AppleSmartBattery` (sampled every 15–20 s for ~25 min, including the independent `PackCurrentAccumulator`), `netstat -ib`.
- **Load:** at most 4 × `yes` for 9 s, and two short-lived-`dd` loops for 8 s, all from my shell, all ended (verified with `pgrep`). Another reviewer and their compiles were active at the same time, so the machine was never fully quiet; comparisons were made over the same seconds.
- **Not tested live:** charging (the Mac was on battery the whole time), Terminal.app tabs, VPN traffic, memory pressure warning/critical, a Mac without a battery or an Intel Mac, the popover-open cost, and the app's own on-screen values (I didn't click the menu-bar item). Activity Monitor and System Settings were not opened; their numbers were taken from `system_profiler` and the documented Activity Monitor formula.
- **Files:** `docs/reviews/2026-10-05-readings-accuracy/A/` — harness source, CPU/energy/memory runs, `top` excerpts, attribution sample, gauge logs, estimator replay, test log.
