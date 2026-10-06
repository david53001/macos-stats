# MacStats readings accuracy review — 2026-10-05
**Overall: 8/10** — On the owner's scale this is "basically perfect" for CPU, memory, network and overhead. Every number I could check live matched Apple's own readout within measurement noise. That includes CPU %, per-app CPU (with Terminal-style work, short-lived processes and exited orphans attributed to the right app), memory used and per-process footprints, battery %, health, cycles, temperature, power and network. Overhead with the popover closed is about 0.03 % of one core. Battery is the weak spot, and it only just keeps the overall score at 8. Time to the charge limit is excellent (1.6 min mean error on four real charges). Time left is the best of every simple predictor I tried, but it is still often off by about 30 % for the next hour. Time to 100 %, which is the default path for public users without a charge limit, has never been checked against a real charge. There are no High issues. Two Mediums (both battery estimates) and a handful of Lows remain.

**Standard:** Activity Monitor / System Settings / battery gauge parity · **Method:** code analysis + live measurement · **Reviewer:** independent subagent (round 3, reviewer A)

## Calibration
- **Target:** a native macOS 14+ menu-bar monitor (SwiftUI `MenuBarExtra` + IOKit/Mach/libproc), Apple Silicon first. Its audience is the owner plus public GitHub users who compare it with Activity Monitor and System Settings.
- **What a 10 is:** every number matches Apple's readout within noise, and work is attributed to the responsible app the way Activity Monitor and iStat Menus do it. Units and scales can't be misread, estimates are honest against measured drain or charge, edge states behave, and overhead is negligible.
- **Anchors:** 3 = a primary reading is badly wrong. 6 = roughly right with noticeable gaps. 9 = within noise everywhere testable, with only nitpicks left. An area with a High issue cannot score 8 or more.
- **Machine and state during the review:** M3, 8 cores, 16 GB, 16 KiB pages, macOS 26, branch `fix/readings-accuracy` (v1.1.0). The Mac was **plugged in and held at 80 %** ("AC attached; not charging"; Optimized Charging hold). An active charge and on-battery drain could therefore not be measured live. I judged those by replaying the Mac's own powerlog history (see Method).

**Terms used below**
- **Footprint (physical footprint):** the memory macOS charges to a process. It is Activity Monitor's "Memory" column (`ri_phys_footprint`; the `footprint` tool prints it).
- **Responsible process:** the app macOS holds accountable for a process. For example, Terminal is responsible for everything in its tabs, and an app is responsible for its XPC helpers.
- **Gauge:** the battery's fuel-gauge chip. Its readings are published in the IORegistry as `AppleSmartBattery` (`ioreg -rn AppleSmartBattery`) and refresh about once a minute.
- **mAh:** charge (milliamp-hours). **Wh:** energy (watt-hours) = charge × voltage.
- **Raw charge:** `AppleRawCurrentCapacity / AppleRawMaxCapacity`. It runs about 1–3 points below the percent macOS shows.
- **"% of one core":** Activity Monitor's scale (100 % = one core busy). MacStats' main scale is the share of the whole Mac (100 % = all 8 cores), so 12.5 % in MacStats = 100 % in Activity Monitor.
- **MAE:** mean absolute error. **p90:** the 90th-percentile error (9 in 10 readings are closer). **Error in %** for drain is |log(predicted ÷ actual)|, so 31 % ≈ off by a factor of 1.31 either way.
- **Powerlog:** macOS's own battery history database (`/private/var/db/powerlog/Library/BatteryLife/`), which logs one gauge row about every minute.

## Scoreboard
| Area | Score | Verdict (one line) |
|---|---|---|
| Battery | **7/10** | Readings are exact and time to the limit is excellent. Time left is honest on average but about ±30 % per reading, and time to 100 % is untested. |
| CPU | **9/10** | Header, rows and attribution matched `top` in every scenario I could create, including short-lived and orphaned work. Only nitpicks. |
| Memory | **9/10** | Memory Used and its parts equal the `vm_stat` formula, and per-process values equal `footprint` exactly. One footnote is misleading. |
| Overhead | **9/10** | Popover closed: about 0.03 % of one core, 13 MB footprint. A breakdown scan costs 1–5 ms per second, and only while drilled in. |
| Network | **9/10** | Matches `netstat -ib` byte for byte on the active link, and skips VPN tunnels and bridges. |

## Battery — 7/10
**Measured** (live = plugged in and held at 80 %; replay = this Mac's powerlog, Sep 28 – Oct 5, 4 161 gauge rows; files in `round3-A/`)

| Reading | MacStats (harness) | Ground truth | Diff |
|---|---|---|---|
| Percent | 80 % | `pmset -g batt` 80 % | 0 |
| Status | "Plugged in, not charging" | pmset "AC attached; not charging" | match |
| Charge limit row | 80 % (powerd: limit 85, Optimized Charging hold 80; resolves to 80) | Charging stopped at 80 % (raw 79.01 %) | correct number, but see B3 |
| Health | 99 % (4534 / 4563 mAh, truncated) | System Settings / `system_profiler` "Maximum Capacity: 99%" | 0 |
| Cycle count | 128 | `system_profiler` 128 | 0 |
| Battery temperature | 30 °C (2999 centi-°C) | ioreg `Temperature` = 2999 | 0 |
| Adapter | 30 W | ioreg `AdapterDetails.Watts` = 30 | 0 |
| Power, last min | 2.86 W, then 2.53 W (two gauge intervals) | ioreg instantaneous `SystemLoad` 2.55 / 2.39 W | within the minute's spread |
| Time to limit (replay, 4 real charges, 238 predictions) | — | where charging really stopped | **MAE 1.6 min**, bias −1.3 min, worst −12 min (first minutes of a 38 % → 85 % charge) |
| Time to 100 % | model only: 20 → 100 % at 2.1 A = 154 min; 79 → 100 % at 1.5 A = 70 min | **no real charge above raw 85 % exists** | not verifiable (B2) |
| Expected drain vs the next 60 awake minutes (replay, 33.8 h on battery, 14 sessions, 1 600 points) | mean error 31 %, bias −2 %, 44 % of readings within ±20 %, p90 71 % | coulomb counter (`PassedCharge`) | best predictor tested (see below) |
| Same, vs. alternatives | instantaneous draw (macOS-style) 60 %, typical-only 35 %, session-mean 33 % | — | MacStats' blend is best or tied |
| Rest-of-session drain | mean error 28 %, bias −2 % | coulomb counter | — |
| Time-left movement per ~10 gauge readings | median 10 %, p90 31 % | — | reasonably steady |
| Energy left (`remainingWh`) vs. energy really delivered | +1.5 … +4.3 % over 7 long sessions (+9 % on one short one) | Σ ΔmAh × V | slightly optimistic |
| `SystemLoad` (app's power source) vs. coulomb drain | 4.72 W vs. 4.52 W time-mean | coulomb counter | +4 %, which offsets the line above |

**Works well**
- Every direct gauge reading (percent, state, health, cycles, temperature, adapter, power) equals Apple's figure. Health uses `NominalChargeCapacity / DesignCapacity` truncated, which is the same rule `system_profiler` uses. It takes the peak of the last 10 readings, persisted, so it doesn't flicker 98/99 (`BatteryTelemetry.swift:54-57`, `:74-94`).
- Time to the charge limit or hold is excellent when the target is right: 1–2 min mean error per session, including today's charge to the 80 % hold, which the model wasn't fitted to (`time-to-limit-replay.txt`).
- The charge target is read live from powerd's policy file (`BatteryCharging.swift:156-177`). It correctly reads today's file as limit 85 (`manualChargeLimit`, `isEndOfCharge`) plus hold 80 (`optimizedBatteryCharging`). The powerlog's SmartCharging table backs this up: earlier charges had no Optimized Charging prediction and ran to 85, while today's had one (probability 82) and stopped at 80.
- Time left feeds only awake on-battery intervals. Sleep is rejected by both the timestamp and the accumulator count (`BatteryTelemetry.swift:137-145`), and plug/unplug starts a new session (`MacStatsApp.swift:220-229`). Bias over 5 days is about 0, and the error is half that of the instantaneous figure macOS-style readouts use.
- Graceful fallbacks: no battery → `nil` and "no battery". On Intel, power falls back to V × I. With no telemetry, macOS's own time is used.
- Tests are real-data replays (`TimeLeftReplayTests`, `ChargeCalibrationTests`), and all 244 tests pass (`tests.txt`).

**Issues**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| B1 | Medium | `BatteryEstimator.swift:105-125`; display `BatteryDetailsCard.swift:36`, `:104-106` | Time left is the best simple predictor I could find, but one reading is still off by a mean 31 % against the next hour's real drain (p90 71 %). In the replay, 09-30 08:38 showed **15 h 55 m** at an expected 2.8 W while the rest of that session drained 3.9 W (about 11 h). It is shown to the minute ("15h 55m"), which implies a precision it doesn't have. | Users compare it with what really happens and see it move by hours. It is inherent to predicting usage, but the presentation overstates certainty. | Round coarser as the horizon grows (e.g. to 5 min under 2 h, 15 min under 6 h, "about 9 h" above). Optionally add an "at recent use" hint. No model change is needed; the model is already the best of those tested. |
| B2 | Medium | `BatteryCharging.swift:63-101` (the comment itself says "No data exists above raw 85 %") | Time to 100 %, the path for every user without a charge limit, has never been compared with a real charge. The taper above the 0.8 knee and the C/20 end are textbook physics, not a fit. It predicts 79 → 100 % at 1.5 A = 70 min and 50 → 100 % = 110 min. | It is the main "time to full" path for public users, and it is untested (anchor 6: "time-to-full unreliable, an untested risky path"). | Validate it on one real full charge (plug in at about 50 % with no limit and replay the powerlog as `ChargeCalibrationTests` does), or above the knee fall back to macOS's `AvgTimeToFull` until it is validated. |
| B3 | Low | `MacStatsApp.swift:273-274`, `BatteryDetailsCard.swift:41`, `BatteryCharging.swift:228-231` | While Optimized Charging holds at 80 %, the drill-in says **"Charge limit 80%"**. The real limit is 85 % (and 100 % for users without one), and macOS will top off later (powerlog `timeTillTopOff` 6 300 s). | A user can read it as their limit setting being 80 %. | Keep the hold separate from the end limit (`PowerdChargePolicy.hold`) and label it "On hold at 80% (Optimized Charging)". |
| B4 | Low | `BatteryCharging.swift:109-121`; live: `defaults read com.macstats.MacStats` → `batteryLearnedChargeLimit = 80` | The fallback "observed limit" learns where charging stopped. Today it learned the Optimized Charging hold (80) as a limit, even though the real limit is 85. It is used only when powerd's file has never been read (macOS 14/15 or a changed file format), and there the next charge would show "Time to 80%" until the charge passes 80. | Wrong target, and therefore a wrong time to full, on older macOS. Not reachable on this Mac. | Don't learn a stop the powerd file marks as a hold, or need two consistent stops before trusting one. |
| B5 | Low | `BatteryEstimator.swift:117-122` | On a first-ever launch on battery (no persisted typical) where macOS still reports "calculating" (−1), the first two minutes use one gauge interval. Replay start: 0.6 W → **"66h 51m"**. | Edge state on first launch only. | Return nil ("Calculating…") when there is no typical, no macOS figure and less than `settleSeconds` of data. |

**Why 7:** every direct reading is exact and the charge-limit estimate is excellent. There is no High issue. The two estimates people actually look at most still have one Medium each: time left's per-reading spread (inherent, but shown with false precision), and time to 100 % (unvalidated for the default user). That is "a great app with noticeable issues", at the top of that band.

## CPU — 9/10
**Measured** (harness = the real `Sources/MacStatsCore` plus a line-for-line copy of `BreakdownScanSession`, `MacStatsApp.swift:519-547`, scanned at 0 / 0.5 / +1 s like the app; ground truth `top -l N -s 1` running at the same time)

| Reading | MacStats (harness) | Ground truth | Diff |
|---|---|---|---|
| Idle header (8 scans) | 2.3–5.8 % | `top` CPU usage 1.9–6.0 % user+sys | within window jitter |
| Rows sum vs header | equal in every scan (System row = remainder) | — | 0 |
| 3 × `yes` from VS Code's terminal (under Claude Code) | header 38.8–40.4 %; **Code** row 37.8–39.1 % (= 302–313 % of one core); each `yes` 12.5 % (100 % of one core) | `top`: each `yes` 99.9–100 %; total about 39–44 % | match |
| 2 loops of short-lived `dd` (each process lives for well under a second) | **Code** 24.5–26.0 % (196–208 % of one core), credited to the two `bash` parents | about 200 % of one core of real work | match |
| 2 orphaned `yes` (parent = launchd) killed mid-interval | in the kill scan: **Code → "Exited processes" 162 % of one core**, System 0.8 % | about 150 % (2 × 0.75 s in a 1.01 s window) | +8 %, within the upper-bound design |
| Energy, 2 × `yes` | Code 6.96–8.0 W; Other 0.00 W | `SystemLoad` 9.96 W (whole Mac incl. about 2.3 W idle base) | plausible |
| Scan cost | 1.0–5.4 ms per scan (5 ms when the CPU is idle at low clocks) | — | — |

**Works well**
- Attribution walks the responsible pid first, then the parent chain, then the full process table when a chain leaves the user's processes (`ProcessScan.swift:14-30`, `:81-115`). `claude` (Claude Code), its shells, `yes`, `bash`/`dd`, `sourcekit-lsp` and every Code Helper land under **Code**. XPC helpers (e.g. `com.apple.SafariPlatformSupport` → JVoice, `MTLCompilerService` → each app) land under their app.
- Short-lived children: their CPU is credited to the surviving parent from the kernel's reaped-child time, with no extra syscalls. Root-subtree jumps are capped by the machine's unexplained remainder (`ProcessScan.swift:360-388`).
- Exited orphans get their own "Exited processes" child row instead of inflating a live process or System (`ProcessScan.swift:407-419`).
- One scale everywhere: header, rows and card are all share of the whole Mac. The footer says "Share of the whole Mac (all 8 cores)". Process rows and tooltips add Activity Monitor's "% of one core".
- Tick reads use per-CPU counters (no rate limit, so no stale reads). Header and rows cover the same interval. pid reuse is detected by start time, and a new process counts from zero.
- Thorough pure-logic tests (about 70 for attribution, sampling, credit and caps).

**Issues**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| C1 | Low | `ProcessScan.swift:262-278` | Reaped children's CPU is shown on the parent's own row: `bash  96% of one core` while `bash` itself is idle and its `dd` children did the work (`cpu-shortlived-dd.txt`). | An expert comparing with Activity Monitor won't find a busy `bash`. Quitting it is still the right action. | Show the credit as an "Ended child processes" child row, like the exited-process row, or add a hint on that row. |
| C2 | Low | `ProcessScan.swift:48-54` | LaunchServices-registered agents (photolibraryd, chronod, universalaccessd, loginwindow, coreautha, "WebThumbnailExtension Grap…") get their own app rows (`memory-rows.txt`). | Clutter only. Their numbers are right, and Activity Monitor uses the same names. | Treat accessory processes without a Dock/UI presence and without an `.app` bundle path as fallbacks. |
| C3 | Low | — | Not live-verified: Terminal.app tabs (root `login` in the chain) and `sudo` work. No Terminal was open, and I couldn't open one without UI events. These are covered by unit tests (`childUnderRootLoginMapsToApp`, `responsiblePidOverridesParentChain`). | — | Owner check: run `yes` in a Terminal tab with the CPU breakdown open. |
| C4 | Low | `BreakdownView.swift:479-482` | The System row lumps WindowServer, the kernel and other users' daemons, and at idle it is often the top row (1–4 % of the Mac). | By design and explained in the tooltip. Activity Monitor lists these individually. | None needed. Optionally name the biggest known contributor ("incl. WindowServer"). |

**Why 9:** every scenario I could create, including the hard ones (short-lived, orphaned and killed work, a terminal inside an IDE), matched `top` within window noise. Rows add up to the header, units are labelled, edge states are handled and tested, and overhead is tiny. Only nitpicks remain.

## Memory — 9/10
**Measured**

| Reading | MacStats (harness) | Ground truth | Diff |
|---|---|---|---|
| Memory Used (card / header) | 8.87 GiB of 16.0 | `vm_stat`: (anonymous 329 815 − purgeable 3 269 + wired 125 583 + compressor 129 257 pages) × 16 KiB = 8.87 GiB | 0 |
| App / Wired / Compressed | 4.98 / 1.92 / 1.97 GB (rounded parts add up to the header) | same pages from `vm_stat` | 0 |
| Compressed data held | 4.73 GB | `vm_stat` "Pages stored in compressor" 310 062 × 16 KiB = 4.73 GiB | 0 |
| Pressure | normal | `kern.memorystatus_vm_pressure_level` = 1 | match |
| Per-process footprint (Code Helper (Plugin), claude, DockHelper, Spotlight) | 352 / 339 / 213 / 194 MB | `footprint -p`: 352 / 339 / 213 / 194 MB | 0 |
| Per-app rows | Code 1 986 MiB over 40 processes; user processes total 6.13 GiB | — | — |

**Works well**
- Memory Used is App Memory (anonymous − purgeable) + Wired + Compressed, which is Activity Monitor's definition (`MemoryStats.swift:66-73`). Page size is read from the kernel (16 KiB here), not assumed.
- Rows use physical footprint, which is Activity Monitor's Memory column, with RSS only as a fallback (`ProcessReader.swift:38-58`).
- The Memory drill-in shows Memory Used's parts with tooltips, and the rounded parts add up to the rounded header (`roundedParts`, tested).
- Units are consistent with Activity Monitor (1024-based, labelled GB/MB).

**Issues**
| # | Severity | Where | Problem | Why it matters | Suggested fix |
|---|---|---|---|---|---|
| M1 | Low | `BreakdownView.swift:117` | The footnote says rows "can add up to more than Memory Used", but here they add up to **less**: 6.1 GB of the user's processes against 8.9 GB used. The rest (WindowServer and other users' processes, the kernel and wired memory) isn't explained. | A user summing rows sees about 2.7 GB "missing". | Reword to something like "Your processes only, counted at full size: they can add up to more or less than Memory Used". |
| M2 | Low | — | Not compared with Activity Monitor's on-screen "Memory Used" (reading its UI needs clicks). Parity rests on the formula matching `vm_stat` exactly. | — | Owner check: glance at Activity Monitor → Memory → Memory Used next to the card. |

**Why 9:** every number equals its kernel or `footprint` ground truth exactly. Only a wording nit and one unread UI remain.

## Overhead — 9/10
**Measured** (`overhead-closed.txt`, `read-costs.txt`)

| Reading | MacStats | Note |
|---|---|---|
| CPU, popover closed | 0.31 s of CPU in 21 min ≈ **0.025 % of one core**; `top` %CPU 0.0, about 3 idle wakeups per 10 s | idle sampler every 10 s |
| Memory, popover closed | footprint **13 MB** (peak 13 MB), RSS 69 MB | not opened since its 22:48 launch |
| Per-tick reads (open popover, every 0.5 s) | CPU ticks 9.9 µs, network 7.5 µs, VM + pressure 4.2 µs | about 22 µs a tick |
| Battery tier (every 10 s open / closed) | IOPS 92 µs + gauge 132 µs (+ powerd file 68 µs on changes) | — |
| Breakdown scan (only while drilled in, 1 per second, off the main thread) | 1.0–5.4 ms including the running-apps list; process read 0.49 ms; full parent table 0.12 ms only when needed | 0.1–0.5 % of one core |

**Works well:** the per-process scan exists only while a breakdown is open (`MacStatsApp.swift:362-382`) and stops on close (`:137`). Publishing is paused while closed, so hidden SwiftUI views don't re-render (`MetricsStore.swift:76-99`). Scans run off the main thread and are skipped rather than queued (`:485-508`).

**Issues:** none found. **Limit:** I couldn't open the popover (no UI events), so the open-state rendering cost and post-open footprint weren't measured.

**Why 9:** negligible in every state I could measure. The open-popover cost is unmeasured.

## Network — 9/10
**Measured** (`network-vs-netstat.txt`; harness read during an 8 MB download)

| Reading | MacStats | `netstat -ib` | Diff |
|---|---|---|---|
| Received bytes over the window | 8 544 499 B (8.6 MB/s) | en0 8 544 226 B (only interface with traffic) | 273 B (read timing) |
| Sent bytes | 29 639 B | en0 29 467 B | 172 B |

**Works well:** 64-bit `IFMIB_IFALLDATA` counters (no 4 GiB wrap), VPN tunnels (`utun*`, `ipsec*`) and bridges skipped so traffic isn't double-counted (`SystemReaders.swift:101-140`), and 1000-based units like macOS.

**Issues:** none found. I didn't test a VPN live (no tunnel had traffic).

## Cross-cutting issues
- **False precision on estimates.** Time left and time to 100 % are shown to the minute even where the realistic uncertainty is tens of minutes to hours (B1, B2). The live readings are exact; it's the estimates whose presentation outruns their accuracy.
- **Private formats as the source of truth.** The charge target depends on powerd's private plist (`BatteryCharging.swift:156`) and attribution on `responsibility_get_pid_responsible_for_pid` (`ProcessReader.swift:110-121`). Both fail safe (`.unknown` → "Time to 100%"; nil → parent chain), and B4 is the one place where the fallback learns the wrong thing.
- **Tests:** 244 pass (`./Scripts/test.sh`). The battery estimators are tested against real replays from this Mac. The only untested risky path I found is time to 100 % (B2).

## Top fixes (ranked by impact ÷ effort)
1. **Validate time to 100 % on one real full charge** (B2, `BatteryCharging.swift:69-101`): plug in around 50 % with the limit off, then replay the powerlog the way `ChargeCalibrationTests` does. Until then, fall back to macOS's `AvgTimeToFull` above the knee.
2. **Round time left by horizon** (B1, `BatteryDetailsCard.swift:104-106` and `cardMeta`): 5-minute steps under 2 h, 15 minutes under 6 h, "about N h" above. This is cheap and removes the false precision.
3. **Label the Optimized Charging hold as a hold, not a limit** (B3, `MacStatsApp.swift:273-274`, `BatteryDetailsCard.swift:41`): "On hold at 80% (Optimized Charging)".
4. **Fix the Memory footnote** (M1, `BreakdownView.swift:117`): "can add up to more or less than Memory Used; your processes only".
5. **Show "Calculating…" on a cold first launch** (B5, `BatteryEstimator.swift:117-122`) instead of a one-interval guess.
6. Optional: show reaped-child CPU as its own child row (C1), and don't learn Optimized Charging holds as limits in the fallback (B4).

## Method & limits
- **Code read:** all of `Sources/MacStatsCore` used for readings (ProcessScan, ProcessReader, ProcessBreakdown, CPUUsage, MemoryStats, SystemReaders, NetworkThroughput, BatteryTelemetry, BatteryEstimator, BatteryCharging, BatteryParse, MetricsStore, RefreshScheduler) and the app glue (`MacStatsApp.swift`, `BreakdownView.swift`, `BatteryDetailsCard.swift`, `StatCard.swift`, `MemoryPartsCard.swift`, `OverviewView.swift`, `MenuBarLabel.swift`). The menu-bar item is a static glyph, so there is no menu-bar number to check.
- **Harnesses** were built from the real sources with the 26.5 SDK, outside the repo. The breakdown harness copies `BreakdownScanSession` line for line, including the anchors from `NSWorkspace` and the clock order (`harness-breakdown.swift`). The battery harness copies `refreshBattery`'s target and limit resolution for the current state.
- **Live loads:** at most 3 × `yes` or 2 × `dd` loops for ≤ 8 s, started from VS Code's integrated terminal under Claude Code. I checked that no other reviewer's `yes` was running before each run, and killed everything I started afterwards.
- **Replays:** the powerlog (`PLBatteryAgent_EventBackward_Battery`, Sep 28 – Oct 5, copied and read with `immutable=1`). For time left, drain per interval came from the coulomb counter `PassedCharge` × voltage. Intervals over 180 s (sleep) and counter resets were skipped, and the result was scored against the next 60 and 120 awake minutes and the rest of the session (`harness-timeleft-replay.swift`). For time to the limit, I fed `InstantAmperage` to the app's `ChargeCurrent` and scored against when charging really stopped (`harness-charge-replay.swift`). Caveats: the replay's input is the coulomb drain, while the app uses the gauge's `SystemLoad` (4 % higher on average). Dark-wake intervals during sleep are included. Charges that the powerlog splits into fragments were skipped.
- **Not verifiable here:** an active charge or on-battery drain live (Mac held at 80 % on AC), time to 100 % (no data), Terminal.app and `sudo` attribution, a VPN, the open-popover overhead, and Activity Monitor's on-screen numbers (no UI interaction allowed).
- **Evidence files:** `docs/reviews/2026-10-05-readings-accuracy/round3-A/`. Key files: `battery-live.txt`, `power-interval.txt`, `time-to-limit-replay.txt`, `time-to-100-model.txt`, `timeleft-replay.txt`, `remainingWh-check.txt`, `cpu-idle*.txt`, `cpu-3yes-*.txt`, `cpu-shortlived-*.txt`, `cpu-orphan-exit.txt`, `energy-2yes.txt`, `memory-card-vs-vmstat.txt`, `memory-rows.txt`, `overhead-closed.txt`, `read-costs.txt`, `network-vs-netstat.txt`, `tests.txt`. To re-run a harness: `swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -O -o h $(ls Sources/MacStatsCore/*.swift | grep -v AppleSensorReader) <harness>.swift` from the repo root (rename the harness to `main.swift` first; the replays take the powerlog rows exported to CSV as their argument, from copies of each `.PLSQL` file: `sqlite3 -csv "file:<db>?immutable=1" "select timestamp, ExternalConnected, IsCharging, Voltage, AppleRawCurrentCapacity, AppleRawMaxCapacity, PassedCharge, SystemPower, InstantAmperage, Level, RawLevel from PLBatteryAgent_EventBackward_Battery"`, concatenated and sorted by timestamp).
