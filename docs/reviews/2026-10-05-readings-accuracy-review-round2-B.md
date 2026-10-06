# MacStats readings accuracy review — 2026-10-05 (round 2, reviewer B)
**Overall: 7/10.** A great app with a few noticeable issues. CPU and memory rows are now very good. Per-process CPU matched `top` exactly under a controlled load (4 × `yes` read 402–408 % of one core against 400 %). Work by short-lived processes is credited to the right app (196 % against 194 % measured with `/usr/bin/time`). Every per-process memory value matched `footprint` to the MB. Attribution was right for VS Code's integrated terminal, Claude Code, its MCP servers, browser and Electron helpers, and XPC services. Overhead with the popover closed is close to nothing (0.015 % of one core, 13 MB). Battery readings match macOS's own figures: percent, health, cycle count and temperature. Power comes from the gauge's own one-minute average. Time left is unbiased against the next hour of real drain and about twice as accurate as a macOS-style last-minute figure.

Three things keep the score below 8:
- **Time to full** targets 100 % until MacStats has seen charging stop at the charge limit. On this Mac's history that would show about 79 min when charging really stops after about 24 min. This affects the first charge after an install, and the next charge after any charge past the limit.
- **Memory breakdown rows don't add up to the header.** The rows plus "System & other" sum to 14.6 GB against a 10.4 GB header. About 1.5 GB of the 5.3 GB "System & other" row isn't held by any process or by wired memory.
- **Time left still swings by about ±20 %** within a quarter hour of ordinary use.

No High issue was found.

**Standard:** parity with Activity Monitor, System Settings and the battery gauge · **Method:** code analysis + live measurement · **Reviewer:** independent subagent (round 2, B)

Scope: branch `fix/readings-accuracy` (v1.1.0, head `164ce01`) of `/Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats`, measured on an M3 (8 cores, 16 GB, macOS 26.7.1) on battery. `round2-B/…` below means `docs/reviews/2026-10-05-readings-accuracy/round2-B/` in the repo, where the measurement logs and harness sources live. Code references are `file:line` under `Sources/`.

## Calibration
- **What it is:** a native macOS 14+ menu-bar monitor for Apple Silicon first. The owner uses it daily and the public installs it from GitHub. They compare it with Activity Monitor and System Settings, and use it to find what is using CPU, RAM and battery.
- **What a 10 looks like:** every number matches Apple's own readout within measurement noise, all work is attributed to the responsible app, units are unambiguous, estimates are honest against measured drain or charge, edge states behave, and overhead is negligible.
- **Scale:** 8–10 basically perfect (nitpicks only) · 4–7 great app with noticeable issues · 1–3 not to standard. An area with a High issue can't score 8 or more.
- **Terms used below:**
  - **Footprint:** a process's physical memory footprint, the number Activity Monitor's Memory column shows. It includes the process's compressed memory counted at full size.
  - **Responsible process:** the app macOS holds accountable for a process. For example, Terminal is responsible for every command run in its tabs, and an app for its XPC helpers. Activity Monitor and privacy prompts use the same idea.
  - **Gauge:** the battery's fuel-gauge chip. Its values appear in `ioreg -rn AppleSmartBattery` and refresh about once a minute.
  - **mAh / Wh:** charge (milliamp-hours) and energy (watt-hours). Wh = mAh × volts / 1000.
  - **SystemLoad / AccumulatedSystemLoad:** the gauge's whole-Mac power reading, plus a running sum of it. Sum ÷ count gives the exact average between two reads.
  - **"% of whole Mac":** 100 % means all 8 cores busy. Activity Monitor's per-process % uses "100 % = one core", so 12.5 % here is 100 % there.

## Scoreboard
| Area | Score | Verdict (one line) |
|---|---|---|
| Battery | 7/10 | Percent, health, cycles, temperature and power match the gauge. Time left is unbiased but still swings. Time to full is excellent once the limit is learned, but about 3.6× too long before that. |
| CPU | 8/10 | Header, rows and the System remainder match `top`. Attribution is right for IDE terminals, Claude Code and helpers. Only labelling and heuristic nitpicks. |
| Memory | 7/10 | Card = Activity Monitor's Memory Used formula; rows = footprint to the MB. Rows plus the "System & other" remainder don't reconcile with the header (14.6 vs 10.4 GB). |
| Overhead | 9/10 | Closed: 0.015 % of one core, 13 MB footprint. A breakdown scan costs about 5.5 ms per second. Open-popover rendering couldn't be measured. |
| Network | 9/10 | Byte-exact against `netstat -ib`. VPN tunnels and bridges are excluded. Units are 1000-based and labelled. |

Weighting: Battery, CPU and Memory dominate and Network is minor. The weighted result is about 7.6, rounded down to 7 because two primary-area Medium issues remain.

---

## Battery — 7/10
**Measured** (Mac on battery the whole time; 16-minute gauge log in `round2-B/battery_gauge_log.txt`, replayed through the app's own pipeline in `round2-B/battery_live_replay.txt`)

| Reading | MacStats (harness, real `MacStatsCore` code) | Ground truth | Diff |
|---|---|---|---|
| Percent | 57 → 55 % | `pmset -g batt` 57 → 55 % | 0 |
| Health | 99 % (peak of last 10 gauge readings ÷ design) | System Settings / `system_profiler`: Maximum Capacity 99 % | 0 (the raw value alone gave 98 % on 3 of 17 readings; the peak hides that) |
| Cycle count | 128 | `system_profiler` 128 | 0 |
| Battery temperature | 30 °C | gauge `Temperature` = 2998 (hundredths of °C) → 29.98 °C | 0 |
| "Power, last min" | gauge one-minute averages 1.8–5.3 W | V × I at the same gauge update: within 3–8 % where the load was steady | ok |
| Whole-window drain (951 s) | gauge sums: mean 3.52 W | charge counter: 0.89 Wh lost → 3.36 W | −5 % (within the gauge's mAh rounding) |
| **Time left** at the end of the window (25.9 Wh left) | **8 h 17 m** | 7 h 21 m at the window's measured 3.52 W | **+13 %** (macOS at the same moment: 12 h 12 m, +66 %) |
| Time left, range over 16 min | 5 h 44 m – 8 h 17 m | — | swings ±18 % (macOS: 3 h 34 m – 14 h 18 m) |
| Time left vs the next hour's real drain (5 days of this Mac's powerlog, 137 points) | median ratio 0.94, mean error 31 %, 43 % within ±20 % | macOS-style last-minute figure: mean error 60 %, 17 % within ±20 % | unbiased (2-hour horizon: bias −13 %) |
| Time to the 85 % limit, once learned (47 points, 6 charges) | mean error 1.6 min, worst 10.9 min | when charging actually stopped (powerlog) | excellent (in-sample: same data the model was fitted on) |
| Time to full **before** the limit is learned | shows on average 79 min (to 100 %) | charging stopped after 24 min on average | **+55 min, median 3.6×** |

Notes on the data. The replays (`round2-B/timeleft_replay_*.txt` and `timetofull_replay.txt`) push this Mac's powerlog through the real `BatteryEstimator`, `ChargeCurrent` and `minutesToTarget`. The powerlog only has per-minute instantaneous V × I, which is noisier than the gauge running sums the app uses, so the time-left replay is if anything pessimistic. Another reviewer's `yes` loads ran during part of the live window, which is why the gauge reads 13–16 W at two moments.

**Works well**
- Percent is macOS's own value. Health, cycle count and temperature are read straight from the gauge with the right units (hundredths of °C; mAh). Health truncates the way System Settings does, and the peak-of-10 filter hides the gauge's ±1 % flicker (`BatteryTelemetry.swift:54-57`, `MacStatsApp.swift:214`).
- Power comes from the gauge's running sums (`BatteryTelemetry.swift:139-156`), not one noisy instant. Gauge intervals that span sleep are rejected (`gaugeInterval`, `:127-135`). The whole-window average agrees with the charge counter within 5 %.
- Time left blends a 5-minute average, a 30-minute average and a persisted typical draw (`BatteryEstimator.swift`). Against real drain it is unbiased over the next hour and much steadier than macOS. Live at the end of the window it read 8 h 17 m against 7 h 21 m true, where macOS read 12 h 12 m. The first two minutes fall back to the learned typical draw, then to macOS's figure. Plug and unplug start a new session immediately (an IOPS notification, `MacStatsApp.swift:314-323`).
- Time to the charge limit is accurate once the limit is known. The model is continuous across the knee and its edge states are tested ("Almost full" instead of a stuck "1m").
- Desktops with no battery work: `readBattery()` returns nil, so the card shows "—" / "no battery" and isn't tappable (`OverviewView.swift:32-36`).
- Pure logic is well tested: 37 battery tests in `BatteryEstimatorTests`, plus parse and calibration suites. The whole suite passes: 221 tests via `./Scripts/test.sh`.

**Issues**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| B1 | Medium (could be High; see note) | `MacStatsApp.swift:265-281`, `:238-249`; `BatteryCharging.swift:109-121`, `:137-156` | The charge limit is known only from powerd's policy file or from MacStats having watched charging stop. Live on this Mac the file reads `noLimit`: its policy list is empty, and it was rewritten at 18:41, just after unplugging. `batteryLearnedChargeLimit` is absent after the reinstall. So the next charge targets 100 %. Replaying 47 points from this Mac's 6 limit-ended charges, "Time to full" would show 79 min on average when charging stopped after 24 min (median 3.6× too long). | This hits the first charge after every install, and the next charge after any charge past the limit (a learned limit is forgotten then). Every public user with a charge limit or an Optimized Charging hold sees it. Note: it is High if powerd never fills in the policy while plugged in; not live-verified, because the Mac stayed on battery. | When the target is only assumed, label it honestly ("Time to 100 %") or show "Calculating…" until charging has run a few minutes. Look for a live source of the limit (e.g. the gauge's `ChargerData.NotChargingReason` once it holds, or the macOS 26 charge-limit preference). Persist the learned limit across a one-off "charge to full". |
| B2 | Low | `BatteryEstimator.swift:22-25`, `:84-88` | The 5-minute average carries 60 % of the weight, so time left moved 5 h 44 m → 8 h 17 m in 16 min of ordinary use, against 7 h 21 m at the measured drain. On 5 days of history, mean error is 31 % (1 h) and 29 % (2 h), with a −13 % draw bias at 2 h (time left about 15 % optimistic). | Much better than macOS, but a user still sees ±1 h jumps. | Tune with the replay harness (`round2-B/harness/timeleft_powerlog_replay_main.swift`), e.g. short weight 0.4 or τ = 10 min. Both the session mean and the estimator land around 25–31 % error, so steadiness costs little accuracy. |
| B3 | Low | `BatteryCharging.swift:63-68`, `:69-101` | The time-to-full curve (knee 0.8, decline 0.4, C/20 termination) was fitted on one Mac and one ~30 W adapter, with no data above raw 85 %. | Other Macs, fast-charge adapters and the final stretch to 100 % are unvalidated. Not live-verified here (the Mac was on battery). | Keep macOS's figure as a sanity bound, or widen calibration with other users' powerlogs before trusting it above 85 %. |
| B4 | Low | `BatteryDetailsCard.swift:48-50` | "Avg since unplugged" averages awake time only, because sleep intervals are rejected. | After an overnight sleep on battery, the label suggests something it isn't. | "Avg (awake) since unplugged". |
| B5 | Low | `BatteryTelemetry.swift:43-50` | Remaining energy uses the midpoint between the present voltage and 3.5 V per cell. A Li-ion curve sits above that midpoint for most of the discharge. | Time left is slightly pessimistic (a few %). That is the safe direction. | Optional: use the gauge's own remaining-energy figure if one is exposed. |

**Why 7:** every directly measurable battery reading matches ground truth, and time left is honest on average and far better than macOS. B1 is a Medium with a large magnitude (3.6×) and a confirmed precondition on this Mac (`noLimit` from powerd, no learned limit), so the area can't be 8 or more.

---

## CPU — 8/10
**Measured** (harness = `round2-B/harness/breakdown_main.swift`, which reproduces `AppModel.procScanTick` line for line: same clocks, anchors, bundle-id cache and `BreakdownScanner`)

| Reading | MacStats (harness) | Ground truth | Diff |
|---|---|---|---|
| 4 × `yes` (1 s scans) | Code row 402.2 / 408.5 / 403.6 / 403.2 / 404.2 % of one core | `top`: 4 × 99.8–100.8 % | ≤ 2 % of one core |
| Header during the same load | 51.9–55.2 % | `top` CPU usage 51.5–54.9 % | ≤ 1 point |
| Short-lived processes (2 loops of `dd`, about 1,000 processes in 5 s) | 195.4–196.0 % of one core, shown as the two `bash` loop rows (12.1 % each) | `/usr/bin/time`: 2 × 5.00 CPU-s in 5.17 s = 193 % | +1.5 % |
| System row (5 s scan) | 18.9 % of one core | `top`: sum of processes not owned by the user = 14.6 % (top 60 only) | +4 % of one core (≈ 0.5 % of the machine; `top` omits its long tail) |
| Rows sum vs header | identical in every scan | — | 0 |
| Attribution (488 processes) | VS Code: renderer, plugins, `zsh`, `claude`, MCP `node`, `sourcekit-lsp`, orphaned `sleep`/`bash` (ppid 1) → Code. Claude.app helpers, incl. self-responsible Plugin helpers and disclaimed `node` → Claude. Chrome/Spotify helpers → their apps. | `responsibility_get_pid_responsible_for_pid` + parent chain (`round2-B/attribution_dump.txt`) | no misattribution found |

**Works well**
- Per-process CPU uses Mach-tick → ns conversion (`ProcessReader.swift:158-178`) and per-interval deltas keyed by pid + start time, so a reused pid is a new process (`ProcessScan.swift:224-235`).
- Processes that start between scans count from zero, so a new job isn't missed.
- Work of children reaped between scans is credited to the reaping parent. The controlled `dd` test matched `/usr/bin/time` within 1.5 %.
- Work of processes that exited unseen is credited back to their app, out of the remainder's growth only (`exitWorkCredit`). In the `yes` test's last scan, 234 % of one core went to Code under a 246 % header.
- Attribution is responsibility-first at every step of the parent chain. Background-only "apps" (MCP servers, widget extensions) are only fallbacks (`ProcessScan.swift:14-54`). This fixes the 2026-10-02 audit's "Terminal work invisible" problem. It is proven live for VS Code's terminal and Claude Code, including shells that were reparented to launchd.
- The rows, including "Other processes" and "System", add up to the header exactly, which is measured over the same interval (`addingSystemRow`).
- The scale is labelled ("Share of the whole Mac (all 8 cores)"), and the right-click menu gives the Activity Monitor figure ("N% of one core").
- 51 process-scan tests cover reaping, debt expiry, pid reuse, budgets and the attribution rules.

**Issues**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| C1 | Low | `BreakdownView.swift:112`, `:174-177`, `:258-261` | Rows use the whole-Mac scale: a process pegging one core reads "12%". The only cues are a caption-size footnote and a right-click item. | A user comparing with Activity Monitor (100 %) or iStat may think MacStats under-reads by 8×. | Show the per-core figure in a row tooltip, or as a secondary value on expanded process rows. |
| C2 | Low | `ProcessScan.swift:376-385`, `:433-450` | Exit credit hands remainder growth to an exited process's app, up to its last rate. If a root daemon spikes in the same second, its work can land on the user's app. | Bounded and short-lived; not observed wrong in testing. | Fine as is; maybe also cap the credit by the exited process's own last-interval share of the header. |
| C3 | Low | `MacStatsApp.swift:444-470` | The per-process scan runs on the main actor: 3.9–7.3 ms (median ≈ 5.6 ms) every second while drilled in. | About 0.55 % of one core, and a possible small hitch in the row animations. | Run `readRawProcesses` and the scan on a utility queue; publish on main. |
| C4 | Low (limit) | — | Terminal.app attribution wasn't live-verified: no Terminal tab was open, and opening one would need UI interaction. | The logic is unit-tested (`childUnderRootLoginMapsToApp`) and the same API was proven live, so confidence is high. | — |
| C5 | Low | `BreakdownView.swift:446-447` | Work run with `sudo`, and root helpers an app triggers (e.g. XProtect scanning a new binary: 9.4 % of one core in `top`), land in "System". | Correct by Activity Monitor's rules and explained in the tooltip; mention only. | — |

**Why 8:** every CPU number I could test was within noise of `top` or `/usr/bin/time`, the rows reconcile with the header, and attribution was right in every IDE, terminal, helper and XPC case available. Only labelling and heuristic nitpicks remain. It isn't 9 because the Terminal path couldn't be shown live and the per-core scale is easy to misread.

---

## Memory — 7/10
**Measured** (`round2-B/memory_breakdown.txt`, `memory_vmstat_ground_truth.txt`, `memory_remainder_check.txt`)

| Reading | MacStats (harness) | Ground truth | Diff |
|---|---|---|---|
| Card / header "Memory Used" | 10.31 GiB = (internal − purgeable + wired + compressor) × 16 KiB | Same `vm_stat` second, Stats-app formula (active + inactive + speculative + wired + compressor − purgeable − file-backed) = 10.31 GiB | < 3 MB |
| Per-process rows (6 checked) | 351.4 / 327.5 / 712.0 / 406.3 / 261.2 MiB | `footprint -p`: 351 / 327 / 713 / 406 / 261 MB | ≤ 1 MB |
| Pressure | normal (kernel level 1) | `memory_pressure`: 71 % free | match |
| Rows total (user's processes) | 9.32 GiB | `top` MEM for uid 501 = 9.32 GiB | 0 |
| "System & other" row | **5.25 GiB** (= 14.57 GiB "in use at full size" − rows) | wired 1.62 GiB + other users' footprints 2.17 GiB (`top` as root) = 3.79 GiB | **+1.46 GiB not held by any process or wired memory** |
| Rows + System & other vs header | 14.57 GiB | header 10.40 GiB | **+4.2 GiB** |

**Works well**
- The card's Memory Used formula (`MemoryStats.swift:54-59`) is Activity Monitor's (App Memory + Wired + Compressed), with 16 KiB pages handled. The 2026-10-02 audit's "+1.1 GB" problem is gone.
- Rows are physical footprint, which is Activity Monitor's Memory column, matched to the MB. The resident-size (RSS) fallback is used only if the rusage read fails.
- Grouping uses the same responsibility attribution as CPU, so Claude Code's 327 MB sits under Code. Group rows sort last so apps aren't buried.
- Pressure comes from the kernel's own level, not a heuristic.

**Issues**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| M1 | Medium | `ProcessBreakdown.swift:165-170`, `MemoryStats.swift:66-69`, `BreakdownView.swift:47-48`, `:113`, `:439-443` | The header shows Memory Used (10.4 GB), but rows plus "System & other" add up to "in use at full size" (14.6 GB). "System & other" is a pure remainder: of its 5.25 GB, only 3.8 GB is wired memory plus other users' processes. The remaining ~1.5 GB is accounting slack between the compressor's original-size count and the footprints. | A user who adds the rows gets 4 GB more than the header, and reads "macOS uses 5.3 GB" from a number that's about 28 % slack. The footnote and tooltip explain the full-size basis but not the slack. | Show both totals in the breakdown header ("10.4 GB used · 14.6 GB at full size"). Split the remainder into "Wired (kernel) 1.6 GB" and "Other (macOS, other users, compression)". Or present the remainder as an unlabelled gap rather than a ranked row. |
| M2 | Low (limit) | — | Activity Monitor's on-screen Memory Used couldn't be read directly (no UI interaction). It is validated against two independent formulas that agree within 3 MB. | — | — |

**Why 7:** every directly comparable number is exact: the card, the rows and pressure. M1 is a noticeable reconciliation and labelling problem a typical user hits as soon as they add the rows up. Activity Monitor has the same gap, but it doesn't present a synthetic remainder as if it were a process.

---

## Overhead — 9/10
**Measured** (`round2-B/overhead_closed.txt`, `overhead_scan_cost.txt`)

| Reading | MacStats | Notes |
|---|---|---|
| CPU, popover closed (12.5 min) | 0.11 CPU-s → **0.015 % of one core** | `ps -o time`. Launched 21:40:56 and never opened in this session. |
| Memory, closed | footprint **13 MB** (RSS 69 MB, mostly shared frameworks) | `footprint -p` |
| Per-process scan (breakdown open) | 3.9–7.3 ms per scan, 1 scan/s (≈ 0.55 % of one core) | harness, 488 processes, incl. `NSWorkspace` |
| Scan while closed? | none | Code: `procTimer` exists only between `enterBreakdown` and `exitBreakdown`, which `setVisibility(.idle)` calls. The measured 0.015 % rules out a hidden 1 Hz scan, which would cost about 0.5 %. |

**Works well:** the closed sampler runs every 10 s with 2 s timer tolerance. Publishing is paused while closed, so the hidden SwiftUI views don't re-render. The battery read costs microseconds. Malloc pressure relief runs after close.

**Issues:** C3 (the scan is on the main thread; Low). Not measured: the popover-open rendering cost and steady-state RAM after the first open, because opening the popover needs a click. **Why 9:** negligible wherever it could be measured.

---

## Network — 9/10
| Reading | MacStats `readNetCounters()` | `netstat -ib` (physical links) | Diff |
|---|---|---|---|
| rx / tx bytes | 7 811 541 623 / 2 045 945 324 | 7 811 541 623 / 2 045 945 324 | 0 B |
| 3 s later | 7 811 558 893 / 2 045 982 477 | same | 0 B |

**Works well:** 64-bit counters via `IFMIB_IFALLDATA`. VPN tunnels (`utun`, `ipsec`) and bridges are excluded to avoid double counting. Rates are a 1 s trailing average, in 1000-based KB/s and MB/s like Finder and Activity Monitor (`NetworkThroughput.swift:20-23`).
**Issues:** Low — when an interface disappears (unplugged USB Ethernet), its bytes leave the sum, so one sample clamps to 0. That's harmless. **Why 9:** byte-exact; low weight.

---

## Cross-cutting issues
- **Learned state is fragile across reinstalls.** The time-left typical draw survived the reinstall (it uses new keys), but the learned charge limit did not exist. Both are plain `UserDefaults` keys with no migration or seed (B1).
- **Two scales and bases in one popover.** CPU rows are a share of the whole Mac while Activity Monitor uses per core (C1). Memory rows are at full size while the header is Memory Used (M1). Both are documented in small print only. One consistent "how to compare with Activity Monitor" affordance, such as a tooltip on the header, would cover both.
- **The tests are strong on pure logic** (221 pass). The pieces that decide what users see in uncommon states — the charge-limit source and the memory remainder — are the ones without ground-truth checks.

## Top fixes (ranked by impact ÷ effort)
1. **Don't show a 100 % time to full when the limit is unknown** (`MacStatsApp.swift:238-249`, `:265-281`). Label the target as assumed ("Time to 100 %"), or wait until charging stops once. Then find a live source for the macOS charge limit. This removes a 3.6× error on the first charge.
2. **Reconcile the Memory breakdown with its header** (`ProcessBreakdown.swift:165-170`, `BreakdownView.swift:47-48`, `:439-443`). Show both totals, and split "System & other" into Wired plus the rest so ~1.5 GB of slack isn't presented as system memory.
3. **Steady the time left** (`BatteryEstimator.swift:22-25`): lower the 5-minute weight or lengthen τ, validated with the replay harness against the powerlog.
4. **Show Activity Monitor's per-core CPU figure on the rows** (`BreakdownView.swift:258-261`), e.g. a tooltip or the secondary value on process rows.
5. **Move the per-process scan off the main thread** (`MacStatsApp.swift:444-470`), and say "awake" in the average label (`BatteryDetailsCard.swift:48-50`).

## Method & limits
- **Code read:** all of `Sources/MacStatsCore` (process reader, scan, breakdown, memory, CPU, network, battery parse, telemetry, estimator, charging), plus `MacStatsApp.swift`, `BreakdownView.swift`, `BatteryDetailsCard.swift`, `StatCard.swift`, `OverviewView.swift` and `MenuBarLabel.swift`.
- **Harnesses** were compiled outside the repo from the real `Sources/MacStatsCore/*.swift` (minus `AppleSensorReader.swift`) with the 26.5 SDK. Sources are in `round2-B/harness/`. The breakdown harness replicates `procScanTick` exactly. The battery harnesses replicate `refreshBattery`'s discharging and charging branches.
- **Ground truth:** `top` (setuid root, so it sees root processes), `ps`, `/usr/bin/time`, `footprint`, `vm_stat`, `sysctl`, `memory_pressure`, `ioreg -rn AppleSmartBattery` (every 15 s for 16 min), `pmset`, `system_profiler`, `netstat -ib`, and this Mac's powerlog (`/private/var/db/powerlog`, 5 days, copied to scratch).
- **Controlled load:** 4 × `yes` for 6.5 s and 2 `dd` loops for 5.2 s, both from the VS Code / Claude Code shell, and both killed.
- **Not live-tested:**
  - charging (the Mac was on battery)
  - Terminal.app tabs, Activity Monitor's screen and the open popover (all need UI interaction, which was forbidden)
  - Intel or desktop Macs (judged from code: nil-safe fallbacks to V × A, "no battery")
- **Noise:** another reviewer ran `yes` loads during part of the battery window and one energy scan, so those intervals show 9–16 W. Their work also appears in the Code row because it ran under the same VS Code. Time-to-full accuracy after the limit is learned is in-sample: the model was fitted to the same powerlog.
- **Clean-up:** no repo files changed (only this report and `round2-B/`), MacStats wasn't touched, and every process I started was stopped. `./Scripts/test.sh`: 221 tests passed.
