# Readings accuracy fix: progress note (started 2026-10-05)

**Branch:** `fix/readings-accuracy` (from `feat/polish-perf` = `main` at `82e2251`).
**Driver:** one multi-agent Workflow (Claude Code `Workflow` tool) run from the main session.
**Input:** the audit `docs/superpowers/plans/2026-10-02-readings-accuracy-audit.md` plus the user's
2026-10-05 report (below).

## What the user reported (2026-10-05)
- **Battery:** time left (e.g. "7 h 06 min") is far longer than the battery really lasts; the
  charging "time until full" also looks wrong. Also wants watts, cycle count, health and
  temperature checked.
- **CPU:** an app (e.g. VS Code) shows 100 %+ and then drops when you open its breakdown;
  a total of 33 % elsewhere showed as 15 % on the MacStats dashboard. Renders started from
  Terminal don't show up under any app.
- **Feature:** expandable app rows: click an app (VS Code, Terminal running Claude Code …) to
  see the processes inside it, each with its own CPU / memory.
- **Constraint:** don't noticeably raise MacStats' own CPU or RAM use (footprint was cut to
  ~40 MB in the 2026-09-29 pass; the per-process scan only runs while a breakdown is open).

## Plan (workflow phases)
1. **Investigate** (3 parallel read-only agents, live measurements): battery, CPU, memory.
2. **Implement** (2 agents in separate git worktrees): (A) process attribution + expandable
   process tree + one CPU scale + memory-card formula; (B) battery readings.
3. **Integrate** both worktree branches into `fix/readings-accuracy`; build + `./Scripts/test.sh`.
4. **Verify** (independent agents, live on-device vs `top`/`ps`/`pmset`/`ioreg`/
   `system_profiler`), including MacStats' own CPU/RAM overhead; fix + re-verify if needed.
5. **Finalize:** install with `./Scripts/bundle.sh`, bump version, update `CLAUDE.md` Status and
   this note.

## Status
- [x] Branch created, audit doc committed (`d3cb687`).
- [x] Workflow finished 2026-10-05 (run ID `wf_cbc02384-581`, launched from the main Claude Code session).
  Implementation agents work on branches `readings/process-memory` and `readings/battery`
  (in temporary git worktrees), which get merged into `fix/readings-accuracy`. If the session
  dies mid-run, check `git branch` for those branches and continue from whatever got merged.
  Results are in the "Results (v1.1.0)" section below.
- [x] Verify round 1 battery fixes (`fix-r2`): `BatteryEstimator` averages are now
  bias-corrected EMAs (the first gauge interval no longer counts as a whole time constant:
  a 9.5 W unplug spike then 1.8 W read −66 % at 10 min, now −20 %; −50 % at 30 min, now −4 %);
  the charge limit is learned only when charging stops (charging → held), not from a full Mac
  drifting to 95–99 % on AC; "Almost full" instead of "Calculating…" while charging at 100 %.
  *(Superseded: time to full was rebuilt and checked on a live charge in review rounds 1 and 3,
  see below. Original note:)* time to full above 80 % divides by the smoothed
  measured current, which keeps falling in the constant-voltage phase, so it likely reads short.
  Check: log `ioreg -rn AppleSmartBattery` `Amperage` + percent every 30 s from ~75 % to 100 %
  and compare with `minutesToTarget` in `Sources/MacStatsCore/BatteryCharging.swift`.
- [x] **Independent accuracy review** (user's bar: ≥ 8/10, aim for 9 if cheap; if below, fix and
  re-review). Two reviewers with the same brief write
  `docs/reviews/2026-10-05-readings-accuracy-review-A.md` and `-B.md`. The brief is
  `docs/reviews/2026-10-05-readings-accuracy/reviewer-brief.md` (fill in `{REPORT}` and a
  scratch dir). If the reports are missing after a session cut-off, launch fresh general-purpose
  subagents with that brief.
  - Round 1 (v1.1.0): A 8/10, B 7/10 (`-review-A.md`, `-review-B.md`) → fixes merged from
    branches `review-fix/battery` + `review-fix/process` (merge `164ce01`, 221 tests).
  - Round 2: A 8/10, B 7/10 (`-review-round2-A.md`, `-round2-B.md`) → round-3 fixes in progress
    on branches `review3/battery` and `review3/process` (the owner was asked to plug in at 55 %
    so the battery agent can log a live charge). Next: merge both, `./Scripts/bundle.sh release`,
    review round 3 with the same brief (report names `-review-round3-A.md` / `-B.md`).
  - Round 3 fixes merged (`5a04426`, 244 tests, installed).
  - **Round 3: A 8/10, B 8/10 → bar met** (`-review-round3-A.md`, `-round3-B.md`). Both scored
    CPU 9, Memory 9, Overhead 9, Network 9; Battery 7 (A) / 8 (B). Battery is capped by two things
    that are not cheap: (1) time left is ±~30 % per reading against the drain that actually
    follows, because future load is unknowable; macOS's own figure is 60–96 % off on the same
    history; (2) time to 100 % has never been checked against a real awake charge to 100 %
    (needs one logged charge with the 85 % limit off). Cheap round-3 items were then fixed
    ("Review fixes (round 3 polish)" below; 255 tests; installed). No round-4 review was run.
  - Review reports under `docs/reviews/` are left uncommitted on purpose (reviewer-skill rule).

---

## Results (v1.1.0, finalized 2026-10-05)

**Version:** `Resources/Info.plist` → `CFBundleShortVersionString` **1.1.0**, `CFBundleVersion` **3**.
**Installed** with `./Scripts/bundle.sh release` into `~/Applications/MacStats.app` (not pushed,
no GitHub release). **Tests:** `./Scripts/test.sh` → **184 tests in 28 suites pass** (117 before).
Machine: M3 MacBook, 8 cores, 16 GB, 16 KB memory pages, macOS 26.

### Build environment (read this first)
Since a Command Line Tools (CLT, Apple's compiler package without Xcode) update on 2026-10-04,
the default SDK is `MacOSX27.0.sdk`, whose SwiftUI needs a `SwiftUIMacros` compiler plugin the
CLT doesn't ship. Every file with `@State` then fails with *"plugin for module 'SwiftUIMacros'
not found"*, even on unchanged code. Prefix every build/test/bundle command with the older SDK:

```bash
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swift build && ./Scripts/test.sh
./Scripts/bundle.sh release && open ~/Applications/MacStats.app
```

Since 2026-10-05 `Scripts/test.sh` and `Scripts/bundle.sh` (and therefore `install.sh` and
`package-release.sh`) source `Scripts/sdk-env.sh`, which sets this `SDKROOT` automatically when
the 26.5 SDK exists and `SDKROOT` is unset. Only a bare `swift build` needs the export.

### Terms
- **Responsible app / responsible pid:** the app macOS charges a process's work to
  (`responsibility_get_pid_responsible_for_pid`, a private but stable libsystem call). Everything
  in a Terminal tab → Terminal; XPC helpers launchd starts for an app → that app.
- **% of the whole Mac:** CPU as a share of all 8 cores (0–100 %). Activity Monitor shows
  "% of one core" (0–800 %), which is 8× larger for the same work.
- **rusage:** the kernel's per-process usage record (`proc_pid_rusage`, `rusage_info_v6`).
  Its CPU times are in **Mach ticks** (24 MHz on Apple Silicon), converted to nanoseconds.
- **Footprint:** a process's "Memory" in Activity Monitor (`phys_footprint`).
- **Gauge:** the battery's fuel-gauge chip, read from the IORegistry node `AppleSmartBattery`
  (`ioreg -rn AppleSmartBattery`). `SystemLoad` there = whole-Mac power in mW.
- **EMA:** exponential moving average. **Bias-corrected EMA:** the first readings don't count as
  a whole time constant (the weight grows with the data actually seen).
- **Charge limit:** macOS's manual charge limit (here 85 %), stored by `powerd` in
  `/Library/Preferences/com.apple.powerd.charging.plist`.

### What was wrong, why, and what changed

**CPU breakdown** (user: "VS Code 100 %+ then drops", "33 % showed as 15 %", "Terminal renders
missing")
- *Terminal work missing:* the parent-chain walk only knew the user's own processes and stopped
  at the root-owned `login` every Terminal tab runs under. Now (`Sources/MacStatsCore/ProcessScan.swift`,
  `owningAppPID(for:parent:responsible:appPIDs:)` + `ProcessAttributor`): per process, then per
  ancestor, the responsible app wins, else the process itself if it is an app, else step to the
  parent (the full `KERN_PROC_ALL` table is fetched lazily when the chain leaves the user's
  processes). Owners are cached per pid + start time. Leftover user processes go to an
  **Other processes** row (system agents such as `mediaanalysisd`).
- *Helpers shown as their own apps* (node, Chrome Helper, QuickLookUIService…): fixed by the same
  responsible-first rule.
- *Mixed scales (main cause of "33 % vs 15 %"):* rows were % of one core, the card/header % of the
  whole Mac. Now everything is % of the whole Mac, bars are out of 100 %, footer says
  "Share of the whole Mac (all N cores)", and a process's right-click menu shows the Activity
  Monitor figure ("N % of one core"). An app at 33 % in Activity Monitor = ~4 % here.
- *Rows never added up to the header:* header and rows used different time windows, and
  root/other-user CPU had no row. The header now comes from the scan's own interval
  (`MetricsStore.breakdownTotalCPU`) and a **System** row (kernel, WindowServer, other users,
  `sudo` work) = header − rows, never below 0.
- *"VS Code 100 %+":* VS Code's row legitimately contains everything run in its integrated
  terminal (Claude Code sessions, their builds, MCP servers). The new **expandable rows** show
  which process it is. The first breakdown window went 0.3 s → 0.5 s
  (`Sources/MacStatsCore/RefreshScheduler.swift`) to cut burst noise.
- *Short-lived processes* (each compile step, `yes | head`…): CPU of exited children is credited
  to the parent that reaps them (rusage `ri_child_*` growth minus what was already counted;
  `ProcessSampler`). The credit is capped so rows never exceed the header, and unpaid "debt"
  expires after 3 scans.
- *New process read 0 W / pid reuse:* new pids count from 0 for CPU and energy; reused pids are
  detected by start time (`ri_proc_start_abstime`).
- *Reader:* `Sources/MacStatsCore/ProcessReader.swift` now does `PROC_UID_ONLY` +
  `PROC_PIDT_SHORTBSDINFO` + one rusage read per process (task info only as fallback), which is
  cheaper than before.

**Expandable app rows (feature)** — `Sources/MacStatsApp/BreakdownView.swift`,
`Sources/MacStatsApp/ProcessActions.swift`: click an app row with 2+ processes to expand it (one
at a time, rotating chevron). Process rows show name, pid, own CPU/memory and a thin bar; top 5
first, then "n more…". Names are read only for visible rows and cached per pid + start time
(Claude Code's version-number name "2.1.289" is shown as `claude`). Right-click a process:
Quit (SIGTERM) / Force Quit (confirm, then SIGKILL) for that pid only, after re-checking the pid
is still ours with the same start time.

**Memory** (user: "used and per-app are off")
- *Card total:* was active + wired + compressed, which mixes in file cache and misses inactive
  app memory (off by ~±1 GB depending on workload). Now Activity Monitor's "Memory Used" =
  (internal − purgeable) + wired + compressor pages (`Sources/MacStatsCore/MemoryStats.swift`,
  `SystemReaders.swift` `readVMRaw`). Works the same on Intel (4 KiB pages).
- *Per-app:* the same attribution fix as CPU; 3.07 GiB in ~367 processes used to be dropped.
  Rows + Other now equal the total footprint of the user's processes. They intentionally do
  **not** add up to Memory Used (kernel, root processes, and footprint counts compressed memory
  at full size); a footer says so.

**Battery** (user: "7 h 06 min left but it drains much faster", "time to full wrong")
- *Time left too long:* the estimator gave 50 % weight to a stored "typical" draw (2.54 W) that
  had learned from plugged-in time and from post-sleep readings, while real on-battery use was
  ~5.5 W. Also, the gauge's power counters keep running through sleep, so the first reading
  after waking averaged ~0.05 W (could show ~13 h). Now (`Sources/MacStatsCore/BatteryEstimator.swift`,
  `BatteryTelemetry.swift` `gaugeInterval`): only awake, on-battery intervals ≤ 180 s are used
  (sleep-spanning ones are rejected); expected W = 0.6 × 5-min average + 0.4 × 30-min average
  pulled toward a typical drain worth 20 min of data; all are bias-corrected EMAs; the typical
  learns on battery only, under new UserDefaults keys `batteryDrainTypicalWatts/Seconds` (the
  polluted `batteryTypicalWatts/Seconds` are deleted at launch). First 2 min after unplugging:
  the stored typical if it rests on ≥ 20 min of data, else macOS's own figure. Saves to
  UserDefaults at most every 10 min and on plug/unplug (was every gauge update).
  Remaining energy uses the voltage midway between now and 3.5 V/cell (was present voltage,
  a few % high).
- *Time to full:* was macOS's `AvgTimeToFull` (jumpy, ~2× too long, ignores the 85 % charge
  limit). Now (`Sources/MacStatsCore/BatteryCharging.swift`): measured charge current
  (`ChargeCurrent`, EMA of gauge `Amperage`), constant current to 80 % then 0.45× current
  (`minutesToTarget`, in the shown percent), targeting the charge limit when one is active
  (read from powerd's file if it says so, else learned where charging actually stops; forgotten
  once charging goes past it). UI shows "Time to 85 %", a "Charge limit 85 %" row, and
  "Almost full" at 100 % (`Sources/MacStatsApp/BatteryDetailsCard.swift`).
- *Health:* rounded to nearest (showed 100 % vs Apple's 99 %); now truncated, from the highest
  `NominalChargeCapacity` of the last 10 gauge updates (it flickers).
- *Power "avg":* showed the blended estimate; now the real since-unplug average. The Intel V×A
  fallback is used only while discharging (while charging it measured power into the battery).

**Network** — `readNetCounters` (`Sources/MacStatsCore/SystemReaders.swift`) used 32-bit counters
that wrap every 4 GiB. Now one `IFMIB_IFALLDATA` sysctl returns 64-bit counters for all
interfaces (~6 µs vs ~23 µs). `NET_RT_IFLIST2`, suggested by the audit, turned out to be
truncated to 32 bits for unentitled apps.

### How each reading was verified (live, 2026-10-05)
Harnesses compiled the real `Sources/MacStatsCore/*.swift` with
`swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -O` (scratch files, not in
the repo; they may be gone).

| Reading | MacStats | Ground truth | OK |
|---|---|---|---|
| 4 × `yes` from a shell | app row 50.3 % of Mac; each `yes` 12.4–12.5 % (99–100 % of one core) | `top`: 99.8–100.4 % each | ✅ |
| 2 × `yes` under root `/usr/bin/login` (= Terminal tab) | attributed to the owning app | used to be dropped | ✅ |
| Rows (apps + Other + System) vs header | max difference 0.000 pp over 43 scans | equal by construction | ✅ |
| Short-lived children (40 × `yes \| head`) | 2.61 core-s | `/usr/bin/time`: 2.60 core-s | ✅ |
| Header/card CPU vs `top` | idle 2.1–14.0 %, load 51.8–64.2 % | `top` within 0.8 pp | ✅ |
| Memory card | 9.532 / 9.532 / 9.621 GB | `vm_stat`+`sysctl`: 9.529 / 9.528 / 9.615 GB (old formula: 9.27, ~260 MB low) | ✅ |
| Memory rows sum | 9.533 GB, 485 procs | `top` footprint sum 9.544 GB, 484 procs, 0 missing | ✅ |
| Per-app memory (Code / Claude / Chrome / Spotify) | 2134 / 969 / 966 / 909 MB | `top` sums 2145 / 969 / 965 / 910 MB | ✅ |
| Battery drain input | 2.715 W | gauge coulomb counter 2.750 W | ✅ |
| Time left after 10 min live (fresh estimator) | 10 h 21 | 10 h 06 – 10 h 45 from real drain; macOS 11 h 39 – 12 h 19 | ✅ |
| Time to 74 % during a real charge (replayed) | within 1–3 min | macOS said 93–132 min | ✅ |
| Health / cycles / temperature | 99 % / 128 / 30.1 °C | `system_profiler` 99 %, 128; ioreg 3004–3010 centi-°C | ✅ |
| Network counters | identical to the byte | `netstat -ib` (7.7 GB, past the 4 GiB wrap) | ✅ |

A correctly re-installed v1.1.0 popover (screenshot 20:32) showed CPU 11–12 %, Memory
10.2 / 16.0 GB "normal", Battery 66 % "9 h 14 m left" (on battery, mostly idle).

### MacStats' own overhead, before vs after
Measured with `ps -o rss=,pcpu=,time= -p <pid>` every 2 s and `footprint -p <pid>`.

| | Footprint | Idle CPU (popover closed) |
|---|---|---|
| **Before** (v1.0.1, running 3 days, popover opened many times) | 36 MB (peak 62 MB) | 0.22 s per 30 s = **0.73 % of one core**, bursts of ~70 ms every 10 s |
| **After** (v1.1.0, freshly launched, popover never opened) | 12–13 MB | 0.01 s per 30 s ≈ **0.03 % of one core** |
| **After**, popover opened once | 35–37 MB | not measured cleanly (see open items) |

- Breakdown scan (only while a breakdown is open): ~6.5–6.8 ms CPU per scan before,
  ~4.3–5.4 ms after (first scan ~7.7–8.8 ms while the responsible-pid cache fills). About
  +0.5 MB held while a breakdown is open, freed on back. No new timers.
- The "after" fresh-launch number is not a like-for-like comparison: most of the old idle cost
  was SwiftUI redrawing the (closed) popover's views after each 10 s idle sample, which only
  starts once the popover has been opened. That idle redraw cost was **not** changed in this
  round.

### Still open
1. **Time to full while charging (needs the Mac plugged in).** Above 80 % the formula divides by
   the smoothed measured current, which keeps falling in the constant-voltage phase, so it
   probably reads short; the 0.45 taper is from one 63→85 % charge. Also unverified live: reading
   an active limit from powerd's file while plugged in. Check: plug in at ~75 %, open the
   Battery breakdown, and log every 30 s
   `ioreg -rn AppleSmartBattery | grep -E '"(Amperage|CurrentCapacity|AppleRawCurrentCapacity)"'`
   until 100 % (or the limit); compare with the app's "Time to …" and `minutesToTarget` in
   `Sources/MacStatsCore/BatteryCharging.swift`. `ChargeCurrent.ingest` is still a plain EMA
   seeded at full weight with the first reading after plug-in (minor; make it bias-corrected
   like `BatteryEstimator.blend`).
2. **Idle overhead after the popover has been opened** (CPU investigation, medium): every 10 s
   idle sample publishes to `MetricsStore`, and SwiftUI redraws the closed popover's text
   (~50–190 ms per sample, ~0.7–1.3 % of one core). Proposed fix: while idle, buffer samples
   without publishing and publish once in `AppModel.setVisibility(.popoverOpen)` before the first
   tick. Re-measure with the `ps` method above after one manual open/close.
3. **Possible stuck "open" state (unconfirmed).** During finalize the popover was opened/closed
   with synthetic Accessibility clicks (`osascript … click menu bar item 1 of menu bar 2`); after
   one such close, the 0.5 s open-popover ticks kept running (~15 % of one core) with no popover
   visible, i.e. `RootView.onDisappear` didn't fire. This code path is unchanged since v1.0.1
   and the old app's lifetime CPU shows real clicks close it normally, so it is probably specific
   to synthetic clicks. Check by hand: open and close the popover a few times by clicking, then
   confirm MacStats sits at ~0 % in Activity Monitor. Also note: while the popover is **open**,
   MacStats used ~12–17 % of one core (sparkline redraws + 0.5 s ticks); no "before" number
   exists for that.
4. **Not clicked through in the real app:** expanding app rows, "n more…", and per-process
   Quit / Force Quit. Also: open one Terminal.app tab, run `yes > /dev/null` for ~5 s with the
   CPU breakdown open, and confirm it shows under Terminal at ~12.5 %.
5. **Minor verifier findings, not fixed:**
   - Process-row **Quit** (SIGTERM) has no confirmation (Force Quit does); consider confirming it
     or hiding actions on "Other processes" children.
   - `ProcessActions.isSameProcess` treats `startTime == 0` (task-info fallback rows) as a match,
     so a reused pid could be signalled; return false instead.
   - When a root-owned process the user started exits (closed tab's `login`, `sudo`), its
     children's already-counted CPU is credited once more to the reaping parent for one scan;
     the cap bounds it to the System row's share (System reads 0 % for that scan).
   - Claude Desktop's MCP servers (`npm exec @modelcontextprotocol/server-pdf --stdio`) register
     as running apps and get their own rows instead of being under Claude (cosmetic).
   - The "Other processes" row often tops the Memory list (~2.6 GB of macOS agents); pin it last
     if preferred (`sortedRows` in `BreakdownView.swift`).
   - A brief charging pause at 50–99 % is learned as a charge limit until the next charging
     reading goes past it.
   - The charging display logic in `AppModel.refreshBattery` has no unit tests (only the pure
     functions do).
6. ~~**Build scripts:** pin `SDKROOT`~~ — done: `Scripts/sdk-env.sh`, sourced by `test.sh` and
   `bundle.sh`.
7. **Not checked:** VPN/`utun*` double counting in network speed; CPU temperature against
   `sudo powermetrics`.
8. **Release:** not published. To ship: `./Scripts/package-release.sh`, merge to `main` and push, then
   `gh release create v1.1.0 dist/MacStats.app.zip --title "MacStats 1.1.0" --notes "..."`.

---

## Review fixes (round 1): battery (2026-10-05, branch `review-fix/battery`)

Input: two independent accuracy reviews (`docs/reviews/2026-10-05-readings-accuracy-review-A.md`
and `-B.md`, evidence under `docs/reviews/2026-10-05-readings-accuracy/A|B/`). Both scored Battery
7/10. Reviewer B's High issue was the time-to-full cliff; both flagged "Power now" and the
late save of the learned drain. Per-app battery power (reviewer A's B1) belongs to the
process/memory fix branch and was not touched here. **Tests:** `./Scripts/test.sh` → 189 tests in
29 suites pass (184 before).

### 1. Time to full / time to the charge limit (High, fixed)
- **Bug:** `minutesToTarget` (`Sources/MacStatsCore/BatteryCharging.swift`) charged the 80–100 %
  stretch at 0.45 × current below the 80 % knee, but used the measured current unchanged at or
  above it: at 2000 mA it said 60 min at 79 % and 26 min at 80 %. Its 0.45 taper came from a
  pmset log gap (63 → 85 % "in 35 min" was only an upper bound: the Mac slept in between).
- **Calibration data:** macOS's **powerlog**, which is world-readable:
  `/private/var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL` plus the gzipped
  `Archives/powerlog_*.PLSQL.gz` (one per day, about a week back). Table
  `PLBatteryAgent_EventBackward_Battery` has one row per gauge update (~1/min while awake) with
  `timestamp` (Unix s), `Level` (shown %), `RawLevel`, `AppleRawCurrentCapacity`,
  `AppleRawMaxCapacity`, `InstantAmperage` (= the gauge `Amperage` the app reads; checked live),
  `IsCharging`, `ExternalConnected`, `NotChargingReason`. Copy the files before querying, e.g.
  `sqlite3 copy.PLSQL "select timestamp, Level, RawLevel, AppleRawCurrentCapacity,
  AppleRawMaxCapacity, InstantAmperage, IsCharging from PLBatteryAgent_EventBackward_Battery"`.
  `pmset -g log` turned out too sparse (a charge level only when some event is logged).
- **What the data shows** (8 awake charging sessions, Sep 28 – Oct 5, raw 21 % → 84 %, ~30 W
  adapter, 1.5–2.2 A):
  - The current is not constant below 80 %: it drifts down with the charge level (Oct 4: 2.2 A
    at 40 % → 1.45 A at 82 %), then falls faster above ~80 %.
  - **Shown vs raw percent while charging:** macOS shows ⌊raw⌋ + 1 in 440 of 457 readings.
    16 of the other 17 come from the first 4 minutes after plug-in, while the shown percent still
    holds the higher value it had while discharging (e.g. 65 % shown at raw 61.9 %). The 85 %
    charge limit stopped charging at raw **84.00–84.02 %** in all 5 sessions that reached it. So
    the target for a limit T is raw (T − 1) %, and the distance is measured from the raw charge
    (the old code placed the charge at the shown percent, ~3 points high just after plug-in).
    While discharging the shown percent runs ahead of raw (62 % at raw 59.4 %, 99 % at 94.1 %).
    That doesn't affect time left, which is computed from the raw mAh.
  - No awake charge ever went above raw 85 %. The limit is 85 %, and the one charge to 100 %
    (Sep 29–30) happened while the Mac was asleep or off, so there are no powerlog rows for it.
- **New model:** the current at raw level s is I(s) = I₀ (1 − 0.4 s) up to the knee at 0.80.
  Above the knee it falls linearly to 0 at s = 1 (the constant-voltage phase), and it is
  continuous at the knee. I₀ is inferred from the measured current divided by the model's factor
  at the present s, and the time is ∫ full · ds / I(s), in closed form. "Full" is where the
  tapering current reaches C/20 (capacity / 20 h ≈ 220 mA, a standard Li-ion termination
  current; `chargeTerminationHours`). When the current is already below that, the function
  returns nil and the UI says "Almost full" (from 90 %) instead of a "1m" that could stick.
  Knee 0.80 and decline 0.4 minimise the error over all 10 767 (start, later level) pairs ≥ 5 min
  apart. A knee of 0.78–0.80 is best on the 2 329 pairs that end above raw 80 %.
- **Charge-current average** (`ChargeCurrent`): it is now a bias-corrected, time-weighted EMA
  like `BatteryEstimator`'s. It is not reported until a second reading arrives, because the first
  reading after plug-in is often a transient (Sep 28: 1096 mA, then 2278 mA 43 s later; Oct 1:
  827 → 1894 mA). This mattered: replaying the sessions, the plain EMA seeded at full weight gave
  first-10-minute errors up to 55 min.
- **Fit error** (replay of the 4 sessions that ran to the 85 % limit, fed like the app: gaps
  > 180 s count as 0 s, duplicate gauge rows skipped; predicted vs real minutes to the stop):

  | | readings | mean error (bias) | mean abs error | 90th pct | worst |
  |---|---|---|---|---|---|
  | v1.1.0 model, after 3 min | 192 | +4.0 min | 5.0 min | 7.6 min | 22 min |
  | **new**, after 3 min | 192 | −1.6 min | **1.7 min** | 2.8 min | 12 min |
  | v1.1.0, every reading | 207 | +4.3 min | 5.6 min | 8.0 min | 55 min |
  | **new**, from the 2nd reading | 203 | −1.7 min | **1.8 min** | 3.0 min | 12 min |

  The worst case (−12 min at 39 % on Oct 4) is a session whose current fell 34 % over the
  charge, more than the fitted 0.4 decline. Mean |error| / real time: 6.4 % (was 23 %).
  Tests (`Tests/MacStatsCoreTests/ChargeCalibrationTests.swift`) embed these 4 sessions and
  require every estimate after 3 min to be within 3.5 min or 20 % (mean abs error < 2 min), and
  from the 2nd reading within 4.5 min or 25 %. `ChargeTimeTests` in `BatteryEstimatorTests.swift`
  checks the rest: no cliff at 79 → 80 % (≤ 3 min with the measured current held), continuous
  and monotone in 1 % steps over 20–99 % (each step lowers the estimate by that 1 %'s modelled
  time + ≤ 1.5 min of rounding), sensible near full, and the limit target.
- **Not verified:** the stretch from raw 85 % to 100 % is the physical model, not a fit. Its
  predictions are 80 % → full ≈ 1 h at ~1.5 A, and ≈ 4–8 min at 99 % with 400 mA. To check it,
  turn the charge limit off once, charge to 100 % while awake, then rerun the powerlog query
  above.

### 2. "Power now" (fixed)
It showed one instantaneous `SystemLoad` from the last gauge update. Reviewer A measured it up to
4.8× off the same minute's average (13.2 W in a minute that averaged 3.2 W), and it stayed on
screen for that whole minute. Now `intervalWatts(from:to:)` (`Sources/MacStatsCore/BatteryTelemetry.swift`)
returns the average over the last gauge interval from `AccumulatedSystemLoad` /
`SystemLoadAccumulatorCount`, the same source the time-left estimate uses. With no awake
interval (first reading, or after sleep) it returns the instant reading. The Battery drill-in
(`Sources/MacStatsApp/BatteryDetailsCard.swift`) shows "Power, last min" and a separate row
"Avg since unplugged", or "Avg since MacStats started" when the app launched on battery
(`MetricsStore.batteryPowerWatts` / `batteryAverageSinceUnplug`).

### 3. Learned drain saved late (fixed)
`saveEstimator()` (`Sources/MacStatsApp/MacStatsApp.swift`) stamped the save time even when it
had nothing to write, so the call at launch pushed the first real save ~10 min out, and quitting
saved nothing. Now only a real write stamps it, which puts the first save at the first on-battery
gauge update (~1 min). After that it saves every 10 min, on plug/unplug, and on quit. Unchanged
values are not rewritten. Quit covers both `NSApplication.willTerminateNotification` (Quit
button, logout) and SIGTERM through a `DispatchSource`, since `install.sh` and `bundle.sh` stop
the running copy with `pkill`. That path was checked with a scratch program: `pkill`, then the
value saved, then exit 0. No new timers.

### 4. Other battery findings: not changed (all Low)
- **Learned limit from a pause** (A-B4): powerlog shows it happens. On Sep 30 charging paused for
  one reading at 84 % (`NotChargingReason` 128) and resumed. The existing rule "charging past the
  limit forgets it" already clears it a minute later, and an active powerd limit takes
  precedence anyway.
- **Health −1 % in the first minutes after launch** (A-B7), **Intel health fallback** and
  **untested glue** (B-B8), **remaining-energy voltage model** not checked against a full
  discharge (B-B3), and the **stale prior** (B-B6, by design).

## Review fixes (round 1): CPU/memory/network/overhead (2026-10-05)

**Context.** Two independent reviewers scored v1.1.0's readings (reports
`docs/reviews/2026-10-05-readings-accuracy-review-A.md` and `-B.md`; at the time of writing they
were uncommitted files in the main checkout at
`/Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats/docs/reviews/`). The target is
≥ 9/10 on CPU, memory, overhead and network. This round fixed the process/CPU/memory/network/
overhead findings on branch **`review-fix/process`** (from `fix/readings-accuracy` at `04650c7`).
Battery findings were handled separately, on another branch. **Tests:** `./Scripts/test.sh` →
**216 tests in 30 suites pass** (184 before). Open items 2, 7 (VPN) and the MCP-server and
"Other processes on top" bullets of item 5 in the list above are resolved by this round.

**How it was measured.** Harnesses in a scratch dir (not in the repo) compiled the real
`Sources/MacStatsCore/*.swift` with `swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -O`
and replicated `AppModel.procScanTick` (the per-app breakdown scan). Loads were at most 4 × `yes`
or 2 loops of short-lived `dd` for ≤ 6 s, started from Claude Code in VS Code's terminal (so they
belong to the **Code** row), and always cleaned up. Nothing was clicked, and the installed app was
not restarted.

| # | Finding (reviewer) | Result | Evidence (live, this Mac: M3, 8 cores, 16 GB) |
|---|---|---|---|
| 1 | Battery drill-in's per-app power misses short-lived processes (A-B1) | **Fixed** | 2 cores of sub-second `dd`: **0.18–0.44 W** before, **5.4–9.0 W per scan (mean 7.9 W; another run 6.5 W)** after. The same load in 2 long-lived `yes` reads 6.7–7.0 W. |
| 2 | Disclaimed helpers shown as apps, e.g. "npm exec @modelcontextprot…" 178 MB (A-C1/M2, B-C4) | **Fixed** | Memory: Claude 860 MB + "npm exec…" 178 MB → **Claude 1037 MB**; every other row unchanged. |
| 3 | Exited orphan processes inflate "System" for one scan (B-C1) | **Fixed** (credited back) + tooltip reworded | 4 × `yes` killed by a subshell that then exits: **System 380 % of a core** before; after, System stays at its 0.7 % level and the work (228 % of a core) shows under Code on the shell that started it. |
| 4 | Memory breakdown has no remainder row (A-M1, B-M1) | **Fixed, with a different formula** (see below) | Memory Used 9.92 GB, Σ rows 9.49 GB, so "Used − Σ rows" = 0.43 GB. That is less than wired memory alone (1.62 GB), so it isn't meaningful. The new row reads **4.95 GB**. |
| 5 | VPN double counting; KB/MB base (A-N1/N2, B network) | **Fixed** | Sum = `netstat -ib` over the kept interfaces, to the byte; still 7.4 µs per read. A's unexplained constant ~44 KB offset was `utun4`. |
| 6 | Idle overhead after the popover has been opened once (B-O1) | **Fixed** | Harness: **259 ms → 1.44 ms of CPU per idle tick** (the reads alone: 1.41 ms). |
| 6b | App stuck in 0.5 s "open" mode after close (open item 3 above) | **Not reproducible without clicks; unchanged** | See below. |
| 7 | 32-bit CPU tick wrap (A-C3) | **Fixed** | Unit test. |
| 7 | "% of one core" only on process rows (B-C5, A-C2) | **Fixed** | The app/group row context menus show it too. |
| 7 | Memory group rows top the list (B-M3) | **Fixed** | For memory, "System & other" and "Other processes" sort after all apps. |

**What changed, file by file**

- `Sources/MacStatsCore/ProcessScan.swift`
  - **Attribution (2).** `attributionAnchors` splits `NSWorkspace` running apps into
    - real apps: they have a bundle id and aren't background-only (activation policy `.prohibited`);
    - fallbacks: everything else.

    `owningAppPID(…, fallbackAppPIDs:)` keeps walking past a fallback and uses it only when no
    real app is above it. So Claude's MCP server goes to Claude, while a lone agent such as
    `universalaccessd` keeps its own row. Terminal (through root `login`) and VS Code
    attribution are unchanged (regression tests).
  - **Energy of reaped children (1).** `rusage` has no child-energy field, so the energy is
    estimated: credited child CPU time × the interval's energy per CPU-nanosecond. The ratio
    comes from processes started this interval if they ran ≥ 20 ms (the reaped processes'
    siblings: the next compiler, the next `dd`), else from all processes. The estimate is
    capped together with the CPU credit, so a long-dead root `login` subtree can't read as
    hundreds of watts. This is an approximation: each scan lands within about ±30 % of the
    long-lived reference.
  - **Exited work (3).** For each vanished process, `ProcessSampler` keeps an upper bound of
    its unseen work: its last-interval rate × this interval. It lists the bound against the
    nearest surviving ancestor (net of any reap credit), or for true orphans against the app
    the process belonged to. `exitWorkCredit` hands that out of the CPU remainder, but only
    the part above the System row's previous level, so System keeps its usual level and nothing
    moves when the remainder didn't rise. Credited amounts become "debt", so a reap that arrives
    a scan late isn't counted twice.
- `Sources/MacStatsCore/MemoryStats.swift`, `ProcessBreakdown.swift`, `SystemReaders.swift`
  - **Memory remainder (4).** Per-process footprints (Activity Monitor's Memory column) count
    compressed memory at its full, uncompressed size, but Memory Used counts the compressor's
    compressed size. On this Mac, 7.4 GB of data was compressed into 2.9 GB.
  - The row is therefore `memoryInUseAtFullSize` (Memory Used with the compressor at the size
    of what it holds, `vm_stat`'s "Pages stored in compressor") − Σ rows, clamped ≥ 0, shown as
    **"System & other"**. It covers the kernel and drivers (wired), macOS's own processes, other
    users and a ~1 GB part no process footprint carries. For comparison, `top` gave 2.17 GB for
    other users' processes, plus 1.62 GB wired.
  - Rows + this row = memory in use before compression (14.4 GB here), which is more than the
    header's Memory Used (9.9 GB). The footnote now says "Rows count compressed memory at full
    size", and the row's tooltip explains it. The per-app values were left alone: they match
    Activity Monitor.
- `Sources/MacStatsCore/SystemReaders.swift`, `NetworkThroughput.swift`
  - **Network (5).** `isCountedInterface` skips loopback, `utun*` (WireGuard/Tailscale/most
    VPNs, macOS tunnels), `ipsec*` and `bridge*` (Internet Sharing, Thunderbolt Bridge). Their
    traffic is already counted on the physical link underneath.
  - `formattedRate` uses 1000-based KB/MB, like Activity Monitor's network columns and Finder.
    The old 1024-based labels read 2.3 % low at the KB scale and 4.6 % low at the MB scale.
- `Sources/MacStatsCore/MetricsStore.swift`, `Sources/MacStatsApp/MacStatsApp.swift`
  - **Idle overhead (6).** `pausePublishing()` (at launch and on close) records samples into a
    bounded pending buffer without touching any `@Published` property. `resumePublishing()`
    runs in `setVisibility(.popoverOpen)` before the synchronous first tick, so the first frame
    still shows current values (the "instant open" behaviour of the 2026-09-29 polish pass).
  - Measured with a harness: the real `OverviewView` in a never-activated, off-screen panel,
    shown once and ordered out like a closed popover, doing the idle sampler's work every 2 s.
    Publishing cost **259 ms of CPU per tick**. The cost grows with the gap (472 ms at 5 s), so
    SwiftUI keeps animating the hidden view. Paused cost 1.44 ms; the reads alone cost 1.41 ms.
  - For the real app, the expected idle cost after an open is the never-opened level (0.47 s of
    CPU in 35 min ≈ 0.02 % of a core) instead of ~0.7–1.3 %. That still needs confirming by hand
    (see below).
- `Sources/MacStatsApp/MacStatsApp.swift` (scan glue): `NSRunningApplication.bundleIdentifier`
  costs ~120 µs a scan. It is cached per pid for the breakdown's life. Back-to-back scan cost:
  **0.41 ms before this round, 0.43 ms after** (0.55 ms without the cache). There are no new
  timers, and the only new state is a few per-process dictionaries, alive only while a breakdown
  is open.
- `Sources/MacStatsCore/CPUUsage.swift` (7): wrap-safe per-field tick deltas.
- `Sources/MacStatsApp/BreakdownView.swift`: CPU System tooltip now ends "…and processes that
  exited before they could be traced to an app". The Memory group row is named "System & other".
  "N% of one core" appears on app rows too.

**Item 6b, the possible stuck "open" mode, not changed.** A harness showed that a plain
`NSHostingView` panel fires `onAppear` once and never fires `onDisappear` on `orderOut` or
`close`. So MacStats' open/close tracking (`RootView.onAppear`/`onDisappear` →
`AppModel.setVisibility`) relies on MenuBarExtra's own appear/disappear calls. The only observed
failure was after a synthetic Accessibility click. A window-visibility override can't be tested
without clicking, and if `onAppear` were then skipped on reopen, the popover would show stale,
paused values, which is worse than the bug.

**Manual check (needs a person):** open and close the popover 5 times by clicking, and in
between also with Esc and by clicking elsewhere. Then run `ps -o time= -p $(pgrep -x MacStats)`
twice, 60 s apart. The CPU time should grow by ≤ 0.05 s. If it grows by ~9 s (15 % of a core),
the app is stuck in open mode: add a check in `AppModel.tick()` that the popover's `NSWindow` is
still `isVisible`, plus an occlusion observer that reopens. The same check confirms fix 6 in the
real app.

**Still open from the reviews (not in this round's scope or not cheap):**
- Open-popover cost (~12–17 % of a core while open, reviewer B O2). The 0.5 s sparkline slide is
  an approved design. Profile it on-screen first.
- The System row still absorbs whatever can't be attributed (B-C2).
- The first breakdown numbers cover only 0.5 s (A-C4).
- Dead code: `owningAppPID(for:ppid:appPIDs:)` in `Sources/MacStatsCore/ProcessBreakdown.swift`
  is only used by tests (superseded by the closure-based one in `ProcessScan.swift`).
- Trash size uses 1024-based MB while Finder uses 1000 (outside these sections).

## Review fixes (round 3): CPU/memory (2026-10-05, branch `review3/process`)

**Context.** After the round-1 fixes, two more independent reviewers scored v1.1.0 at commit
`164ce01` (reports `docs/reviews/2026-10-05-readings-accuracy-review-round2-A.md` and `-B.md`,
evidence in `docs/reviews/2026-10-05-readings-accuracy/round2-A/` and `round2-B/`; at the time of
writing these were uncommitted files in the main checkout at
`/Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats/`). CPU scored 8/10 from both,
Memory 8 (A) and 7 (B). The goal of this round: CPU and Memory ≥ 9/10 with no overhead
regression. Branch **`review3/process`** (from `fix/readings-accuracy` at `164ce01`); battery
findings were fixed in parallel on another branch and are not covered here.
**Tests:** `./Scripts/test.sh` → **227 tests in 31 suites pass** (221 before).

**Terms used below.**
- *Breakdown*: the drill-in screen you get by clicking the CPU, Memory or Battery card; it lists
  apps (rows) and, when you click an app, its processes (child rows).
- *Scan*: one pass of the breakdown's per-process reader (`AppModel.procScanTick` in
  `Sources/MacStatsApp/MacStatsApp.swift`, logic in `BreakdownScanner`,
  `Sources/MacStatsCore/ProcessScan.swift`). Runs every 1 s, only while a breakdown is open.
- *Tick*: the 0.5 s refresh of the overview cards while the popover is open (`AppModel.tick`).
- *CPU ticks*: the kernel's cumulative per-state CPU counters (user/system/idle/nice, 100 per
  second per core). Two readings give the whole Mac's busy %.
- *Footprint*: a process's physical footprint, the number in Activity Monitor's Memory column.
  It counts the process's compressed memory at its full, uncompressed size.
- *Memory Used*: Activity Monitor's figure = App Memory + Wired Memory + Compressed (the RAM the
  compressor occupies, i.e. compressed size).
- Finding IDs like *A-C1* mean report A (round 2), finding C1 in its tables (C = CPU, M = memory).
- *Exit credit*: CPU that the scan estimates for processes that ended between two scans
  (their last rate, capped by what the whole Mac did unseen); see `exitWorkCredit`.

**How it was checked.** Harnesses in a scratch dir (not in the repo) compiled the real
`Sources/MacStatsCore/*.swift` with the 26.5 SDK
(`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swiftc -O …`) and mirrored the
scan glue. A second harness compiled the real `Sources/MacStatsApp` views and rendered
`BreakdownView` into an off-screen window (never shown) to check the layout at 320 × 404.
Load: one orphaned `yes` for ~5 s, killed. Nothing was clicked; the installed app was not
restarted.

| # | Finding (reviewer) | Result | Evidence |
|---|---|---|---|
| 1 | Stale CPU ticks: the header sometimes covered the wrong interval, once 0 % over 25 % of rows (A-C1) | **Fixed** | `host_statistics(HOST_CPU_LOAD_INFO)` returned an unchanged reading 2 and 1 times in 40 reads at 3/s (rate limit). The new reader `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` (per-CPU counters, summed) gave identical sums tick for tick and 0 stale reads in 40 at 20/s and 40 at 50/s. |
| 2 | Exited/orphaned processes' CPU shown on the app's main process (A-C2) | **Fixed** | Orphaned `yes` (ppid 1, owned by Code) killed between scans: the expanded Code row now shows **"Exited processes 9.4 % of Mac = 75 % of one core"** and the Code main process stays idle; before, it read "Code 14106 — 79 % of one core". App total unchanged. |
| 3 | Memory rows don't reconcile with the header; "System & other" remainder unverifiable (A-M1, B-M1) | **Fixed** (row removed, header composition added) | Card parts vs `vm_stat` read right after: MacStats used 9.127 GiB = App 5.055 + Wired 2.016 + Compressed 2.056; `vm_stat` 9.128 = 5.056 + 2.016 + 2.056. |
| 4 | Rows on the whole-Mac scale: a process pegging a core reads "12%" (B-C1) | **Fixed** | Expanded CPU process rows show "100% of one core" under the name; CPU app rows have it in their tooltip and right-click menu. Rendered: fits 320 pt, no truncation. |
| 5 | Per-app scan on the main thread (B-C3) | **Fixed** | The whole scan now runs on one serial queue. Most of it was the running-apps list (8.6 ms of a 12.8 ms scan on a busy machine). The app grouping read off the main thread matched a main-thread read in 12 of 12 scans. |
| 6 | Other cheap Medium CPU/memory issues | **None left** | The only other Medium in the reports is battery (B1, other branch). Lows not changed: see below. |

### What changed, file by file
- `Sources/MacStatsCore/SystemReaders.swift`
  - `readCPUTicks()` now sums the per-CPU counters from `host_processor_info`
    (`sumCPULoad`, wrapping 32-bit sums so deltas stay exact). Why: macOS rate-limits
    `host_statistics` for apps that aren't part of the OS. Past a random budget of 2–10 calls per
    second it silently returns the previous reading. With a breakdown open, the tick and the scan
    read about 3 times a second, so a scan's header (and the card) sometimes covered the wrong
    interval. `host_statistics` is kept as the fallback if the per-CPU call fails.
  - Cost: ~90 µs per read against ~23 µs (median). At ≤ 3 reads/s while open that is +0.2 ms of
    CPU per second (0.02 % of one core); while closed (one read per 10 s) it's negligible.
- `Sources/MacStatsCore/ProcessScan.swift` (`BreakdownScanner.scan`)
  - If the ticks didn't move between two scans, the scan reports no header for that scan instead
    of 0 % (the store then falls back to the card's value). A safety net; the new reader makes it
    unlikely.
  - Exit credit (CPU estimated for processes that ended between two scans, see `exitWorkCredit`)
    no longer lands on a live process. It becomes a synthetic child row with pid
    `BreakdownGroup.exitedProcesses` (−3) inside the same app, shown as **"Exited processes"**,
    with no Quit/Force Quit. Reaped-child credit (measured exactly by the kernel for the parent)
    stays on the parent, as before.
  - The `memoryInUseBytes` parameter and the memory remainder row are gone.
- `Sources/MacStatsCore/MemoryStats.swift`
  - `MemorySample` now also carries `appBytes`, `wiredBytes`, `compressedBytes` (they add up to
    `usedBytes` exactly) and `compressedDataBytes` (what the compressor holds at full size,
    `vm_stat`'s "Pages stored in compressor").
  - `roundedParts` rounds the parts to 0.1 GB so they add up to the rounded header (largest
    remainder). Plain rounding can be 0.1–0.2 GB off: 6.16 + 1.66 + 2.66 = 10.48 would read
    6.2 + 1.7 + 2.7 = 10.6 under "10.5".
  - `memoryInUseAtFullSize` (only used by the removed row) is gone.
- `Sources/MacStatsCore/ProcessBreakdown.swift`: `addingMemoryRemainderRow` removed;
  `BreakdownGroup.exitedProcesses` added; `BreakdownMetric`, `ProcessUsage`, `AppUsage` are
  `Sendable` (they cross to the scan queue).
- `Sources/MacStatsApp/MemoryPartsCard.swift` (new): a one-row card under the Memory breakdown's
  header: **App Memory · Wired · Compressed**, each in GB, with tooltips (Compressed's says how
  much data the compressor holds and that the rows count it at full size). Same card style as
  `BatteryDetailsCard` (`CardBackground`, `Design.cardPadding`).
- `Sources/MacStatsApp/BreakdownView.swift`
  - Memory header reads "10.3 / 16.0 GB used". Footnote (two lines, memory only): "Rows count
    compressed memory at full size, so they can add up to more than Memory Used".
  - "System & other" row and its tooltip removed (`AppInfoCache` no longer needs the metric).
  - Process rows: the "Exited processes" row (no pid, no actions, tooltip); on CPU, a
    "N% of one core" line next to the bar. App rows on CPU: per-core figure in the tooltip.
- `Sources/MacStatsApp/MacStatsApp.swift`
  - The scan runs on `scanQueue` (one serial `DispatchQueue`), inside a queue-confined
    `BreakdownScanSession` that owns the `BreakdownScanner` and the bundle-id cache. Results are
    published on the main thread. A scan still running when the timer fires is skipped (not
    queued); a result is dropped if the breakdown closed or another opened meanwhile
    (`scanGeneration`). The first scan of a drill-in waits for its result (`scanQueue.sync`), so
    the first frame has rows.
  - Why the running-apps list moved too: reading `NSRunningApplication` properties asks
    LaunchServices again after each main run-loop turn, ~150 µs per app, the bulk of a scan.
    Apple's headers (`NSRunningApplication.h`) document `runningApplications` and
    `NSRunningApplication` as safe to read from background threads.

### Why Memory Used's parts, not a remainder row
Per-app memory must stay footprint, because that's what Activity Monitor's Memory column shows
and users compare with it. Footprints count compressed memory at full size, Memory Used counts
the compressor's RAM, so the rows can't add up to the header (Activity Monitor's don't either).
The old "System & other" row tried to close the gap with a remainder. Reviewer B showed that
~1.5 GB of its 5.3 GB was held by no process and no wired memory, so it was accounting slack
presented as if it were a process. Activity Monitor instead lists Memory Used's parts at the
bottom of its Memory tab. Those parts are exact kernel counters and add up to the header, so
MacStats now does the same. No other reconciliation that could be checked from user space was
found: other users' and root processes' footprints can't be read without root.

### Overhead, before vs after
- **Scan cost** (harness, ~430 processes, 60 running apps, medians of 12–16 scans at 1/s). The
  machine was busy during these runs (Spotlight media analysis, XProtect), so absolute numbers
  are high and noisy:

  | Run | CPU breakdown before → after | Memory breakdown before → after |
  |---|---|---|
  | 1 | 11.2 → 12.2 ms | 12.8 → 11.2 ms |
  | 2 | 10.5 → 12.0 ms | — |
  | 3 | 10.6 → 11.1 ms | — |
  | 4 | 9.6 → 10.6 ms | 11.4 → 8.6 ms |

  The difference is within the run-to-run noise. On a quiet machine earlier the same harness read
  3.0 ms (CPU) and 3.1 ms (memory) before the changes. The memory scan no longer reads the VM
  counters; every tick read costs +~65 µs (see above).
- **Main thread:** before, the whole scan ran on it (3–13 ms each second while drilled in). After,
  only the dispatch and publishing the result do.
- **Memory:** no new timers. New state: four `UInt64`s in `MemorySample`, at most one synthetic
  row per app, and the scan session (which holds what `AppModel` held before). The bundle-id
  cache is still pruned to the running apps every scan.

### Not changed (Low, noted for later)
- A-C3: the bundle-id cache is keyed by pid only. It is rebuilt from the running-apps list every
  scan, so a stale entry needs an app to quit and another to get its pid within one second.
- A-C4: a surviving child keeps pointing at its responsible app's pid after that app quits; if a
  new app reuses the pid, a long-lived orphan could be attributed to it. Possible fix: ignore a
  responsible pid whose start time is later than the child's (`ProcessAttributor`).
- B-C2: exit credit could also be capped by the exited process's own last share of the header.
- B-C5: `sudo` work and root helpers an app triggers land in System (Activity Monitor does the
  same).
- The UI changes were checked in an off-screen render, not in the running menu-bar app.
  **Manual check:** after installing (`./Scripts/bundle.sh && open ~/Applications/MacStats.app`),
  open the Memory breakdown and check the card's three values add up to the header; open the CPU
  breakdown, expand an app and check the "% of one core" lines.

## Review fixes (round 3): battery (2026-10-05, branch `review3/battery`)

**Context.** Two independent round-2 reviews of branch `fix/readings-accuracy` at `164ce01`
(`docs/reviews/2026-10-05-readings-accuracy-review-round2-A.md` and `-B.md`; at the time of
writing uncommitted files in the main checkout at
`/Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats/docs/reviews/`, evidence in
`docs/reviews/2026-10-05-readings-accuracy/round2-A|round2-B/`) both scored Battery 7/10. Goal:
≥ 9/10. This round touched only battery code (`Sources/MacStatsCore/Battery*.swift`, the battery
parts of `Sources/MacStatsApp/MacStatsApp.swift`, `Sources/MacStatsApp/BatteryDetailsCard.swift`)
and their tests. **Tests:** `./Scripts/test.sh` → **238 tests in 34 suites pass** (221 before).

**Terms.** *Raw charge*: `AppleRawCurrentCapacity / AppleRawMaxCapacity` from
`ioreg -rn AppleSmartBattery`; macOS shows ⌊raw⌋ + 1 % while charging. *powerd*: the macOS
power daemon. *Optimized Charging (OBC)*: macOS holding the charge at 80 % until shortly
before it expects you to unplug. *Powerlog*: macOS's world-readable battery history,
`/private/var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL` (+ `Archives/*.gz`), table
`PLBatteryAgent_EventBackward_Battery`, one row per gauge update (~1/min awake); copy before
querying.

### Live charge (the owner plugged in at 55 %, 22:02:43)
Logged every 30 s for 40 min: `ioreg -rn AppleSmartBattery`, `pmset -g batt`, and
`/Library/Preferences/com.apple.powerd.charging.plist` (scratch logger, not in the repo).
- **Charging stopped at 80 % shown / raw 79.0 % at ~22:42** (not at the 85 % limit). At the
  stop, macOS's `AvgTimeToFull` jumped from 64 to 1586 min: Optimized Charging's hold.
- **Charge-limit source found: powerd's policy file is live.** Empty while unplugged (as
  reviewer B saw); within ~20 s of plug-in it held two policies: `manualChargeLimit`
  `soclimit` 85 with `isEndOfCharge` = true, and `optimizedBatteryCharging` `soclimit` 80 with
  `isEndOfCharge` = false. Rewritten again at 22:08 and at the stop (same content).
- Checked and **not** a usable source: `ioreg -l` (no limit key anywhere; the gauge's
  `ChargerData.ChargingVoltage` tracks the charge, it isn't the limit), `pmset -g`,
  `pmset -g adapter`, `pmset -g log` (no limit events), IOPS power-source dictionary (no OBC
  key), `/Library/Preferences/com.apple.PowerManagement*.plist`. Useful side facts:
  `ChargerData.NotChargingReason` is `0x80` (128) with no adapter and has bit `0x1000000` set
  whenever charging is held by a limit or hold (all powerlog holds at raw 84.0 %, and this
  80 % stop); `~/Library/Preferences/com.apple.batteryui.charging.mac.plist` holds
  `com.apple.batteryui.charging.mac.prior.limit = 85` (last changed Sep 9; meaning not clear,
  not used). Powerlog table `PLBatteryAgent_EventBackward_ChargingLimit` logs OBC engagement
  but lags by minutes.
- **Time to full, out of sample** (the model was fitted on earlier charges): replaying this
  charge through the app's own `ChargeCurrent` + `minutesToTarget`
  (`LiveChargeTests` in `Tests/MacStatsCoreTests/ChargeCalibrationTests.swift`):

  | target | readings | mean error (bias) | mean abs error | worst |
  |---|---|---|---|---|
  | 80 % (where it stopped; what the app now targets) | 46 | +0.3 min | **1.1 min** | 3.9 min |
  | 85 % (the limit alone) | 47 | +8.5 min | 8.5 min | 12.9 min |
  | 100 % (round 2's "limit unknown" case) | 47 | +64.7 min | 64.7 min | 71.9 min |
  | macOS (`AvgTimeToFull`, to 100 %) | — | 139 → 64 min shown while 38 → 1 min was true | | |

  The stretch above raw 85 % is still unverified (no charge to 100 % while awake).

### 1. Time to full when the limit is unknown (B-B1, Medium): fixed
- `parsePowerdChargePolicy` (`Sources/MacStatsCore/BatteryCharging.swift`) returns the end
  limit (end-of-charge policies) and a **hold** (other policies below it, i.e. OBC's 80 %). The
  old parse took the minimum of all policies, which happened to be right today but would stay
  "80 %" while a charge ran past an unused hold.
- `ChargeLimitResolver` (same file, pure, tested in `ChargeLimitResolverTests`) decides the
  target: powerd's end limit if listed; "no limit" only after 60 s plugged in (before that the
  file can still be the empty unplugged one); else the **remembered** answer from the last
  plug-in (UserDefaults `batteryPowerdChargeLimit`, 100 = none, plus
  `batteryPowerdChargeLimitDate`; dropped after 30 days without confirmation); else where
  charging was last seen to stop (`batteryLearnedChargeLimit`, the fallback for macOS without
  the file); else **unknown**. A hold is the target until the charge passes it (then the hold
  wasn't used). Only the end limit is remembered.
- The app re-reads the file on every refresh during the first 2 minutes after plug-in, and on
  each percent/state change (a ~800-byte file; no new timer).
- Unknown target: the drill-in says **"Time to 100%"** and the card "… to 100%" instead of "to
  full". At the stop percent while still charging (the last minute): "Almost done".

### 2. Time left swings (A-B3, B-B2): improved, not eliminated
Tuned `BatteryEstimator` on this Mac's real history: 5 days of powerlog (14 on-battery sessions,
2 666 gauge readings), drain per interval from the coulomb counter `PassedCharge` (whole mAh),
intervals over 180 s (sleep) skipped as the app does. Each reading's expected draw was compared
with the drain that actually followed (next 60 min, next 120 min, rest of the session); swing =
|ln| change of the expected draw over 10 awake minutes. Scripts were in the session scratch dir
(`replay.py`, `grid*.py`); the Python mirror matches the Swift code on the embedded session
(0.113 / 0.135 both).

| | mean abs log error (60 / 120 / rest) | mean abs error at 120 min | swing per 10 min (mean / p90) |
|---|---|---|---|
| before (5 / 30 min, 3 h, weight 0.6) | 37.7 / 36.4 / 34.2 % | 31.5 % | 21.6 % / 52 % |
| **after** | **35.8 / 31.3 / 32.1 %** | **27.9 %** | **16.4 % / 38 %** |

New constants: short 10 min, recent 60 min, typical 12 h, prior 20 min (unchanged); short weight
**0.8 when the load rose, 0.6 when it fell**, the latter phased in over the first 10 min of a
session. The gain shows on each half of the history separately (constants chosen on all of it; 0.364 → 0.333 and
0.364 → 0.341 error; 0.22 → 0.17 swing). Trusting the long-run average much more scores better
on this history (~31 % / 12 %) but read 45–57 % pessimistic for a light half hour after heavy
use, so the search was restricted to settings within ±25 % of synthetic load changes after
30 min. Honesty checks (pinned in `Tests/MacStatsCoreTests/TimeLeftReplayTests.swift`): a 15 W
render right after unplugging is within 9 % after 10 min (was 20 %); a 4 → 12 W step reaches
85 % of the step in 30 min (was 83 %); a light 1.8 W session on a 5 W Mac reads −21 % after
30 min (was −19 %); 4 W after a 12 W build reads −24 % (was −17 %). Reviewer B's live window
replayed: ends at 7 h 49 m vs 7 h 21 m measured (+6 %; was 8 h 17 m, +13 %); its range is
5 h 27 m – 7 h 49 m (was 5 h 44 m – 8 h 17 m), so swings right after launch remain.
The next-hour drain of real use is largely unpredictable (error floor ~30 %).

### 3. Health 98 % for a minute after launch (A-B2): fixed
`RecentMax` can be seeded; the app saves its last 10 `NominalChargeCapacity` readings
(UserDefaults `batteryNominalCapacityRecent`) with the drain average (plug/unplug, every
10 min on battery, quit/SIGTERM) and seeds the next launch.

### 4. Average label (B-B4): fixed
"Avg awake since unplugged" / "Avg awake since MacStats started".

### 5. Other battery findings
- A-B1 (Medium, time to full validated in-sample only): answered by the live out-of-sample
  charge above (1.1 min); above raw 85 % still unvalidated.
- A-B4 / B-B5 (Low, remaining-energy voltage model near empty): not changed; needs a logged
  full drain.

**To verify by hand (needs a person):** plug in with the Battery drill-in open and check the row
reads "Time to 80%" (or "85%") within ~20 s; on a later plug-in where charging runs past 80 %,
check it switches to "Time to 85%".

## Review fixes (round 3 polish) (2026-10-05, branch `fix/readings-accuracy`)

**Context.** Two independent reviews of MacStats' readings (round 3) scored them 8/10:
`docs/reviews/2026-10-05-readings-accuracy-review-round3-A.md` ("A") and `…-round3-B.md` ("B").
Finding IDs below are `<report>-<ID>` (e.g. A-B3 = report A, Battery issue 3). This pass fixed
only the cheap labelling/edge items. Terms: **limit** = the user's manual charge limit (here
85 %); **hold** = Optimized Battery Charging pausing the charge below it (here 80 %), both read
from powerd's file `/Library/Preferences/com.apple.powerd.charging.plist`; **gauge interval** =
the ~1 minute between two battery fuel-gauge updates.

| # | Finding | Result | Where |
|---|---|---|---|
| 1 | Held at 80 % by Optimized Charging, the drill-in said "Charge limit 80%" (limit is 85 %) (A-B3, B-B2) | **Fixed.** Now two rows: "Optimized Charging — Held at 80%" and "Charge limit — 85%". | `BatterySample.chargeHoldPercent`, `BatteryDetailsCard.swift` |
| 1b | The fallback limit learner stored the hold as a limit (`batteryLearnedChargeLimit = 80`) (A-B4) | **Fixed.** A stop at or below powerd's listed hold isn't learned. The value already stored on the owner's Mac was left alone: it is used only if powerd's file is never readable, and is forgotten the next time a charge runs past 80 %. | `learnedChargeLimit(…, hold:)` |
| 2 | Hold releases, charging resumes at 80 %: "Almost done" while ~10 min to 85 % remain (B-B3) | **Fixed.** While charging at or above the hold, the target is the end limit, or 100 % with none. Cost: in the one minute between showing 80 % and stopping at a hold, it shows time to 85 % instead of "Almost done". | `chargeStop()` |
| 2b | Hold-vs-limit-vs-percent decision lived untested in the app (B-B7) | **Fixed.** Pure `chargeStop(end:hold:state:percent:) -> ChargeStop` in `Sources/MacStatsCore/BatteryCharging.swift`, tested in `ChargeStopTests` (hold, hold released, held, limit, past the limit, no limit, unknown, on battery). `ChargeLimitResolver.resolve` now returns only the end of charge. | |
| 3 | Time left shown to the minute ("15h 55m") though ~30 % uncertain (A-B1) | **Fixed.** `formatTimeLeft`: exact under 15 min, 5-min steps under 2 h, 15-min steps under 6 h, then "about N h". Time to full (`formatTimeToFull`): exact under 1 h, 5-min steps above. Used by the Battery card line and drill-in; the menu-bar item is a static icon. "2h 0m" now reads "2h". | `Sources/MacStatsCore/DurationFormat.swift`, `DurationFormatTests` |
| 4 | First-ever launch on battery: one gauge interval read "66h 51m" (A-B5) | **Fixed.** With no learned typical drain (or one under 20 min of history) and no macOS figure, time left is "Calculating…" until the session has 2 min of data (about two gauge intervals). | `BatteryEstimator.minutesLeft`, test `aFirstEverLaunchWaitsForTwoMinutesOfData` |
| 5 | Memory footnote said rows "can add up to more than Memory Used"; they can also add up to less (A-M1, B-M1) | **Fixed.** "Rows are each app's footprint (as in Activity Monitor); they don't add up to Memory Used" (2 lines, fits). | `BreakdownView.swift` footnote |
| 6 | CPU app rows showed only the whole-Mac share (52 %) vs Activity Monitor's 415 % (B-C2) | **Fixed.** "418% of one core" beside each CPU app row's bar, caption2 tertiary, in a fixed 88 pt column so all bars stay the same length. | `BreakdownView.swift` `AppRow` |

**How it was checked.** `swift build` (SDK 26.5) and `./Scripts/test.sh`: **255 tests pass**
(244 before). The UI changes were rendered off-screen (SwiftUI `ImageRenderer`, never shown on
screen; a scratch copy of `Sources/MacStatsApp` with the list made non-lazy so it renders) at
320 × 404: the CPU list with a 52 % / "418% of one core" row fits with no truncation (rows
~38 pt, was ~36); the held Battery drill-in shows both rows; the Memory footnote fits in two
lines. Nothing was clicked and the installed app was not rebuilt or restarted. No new timers.

**To verify by hand (needs a person):** with Optimized Charging holding at 80 %, open Battery →
it should read "Optimized Charging  Held at 80%" and "Charge limit  85%"; when charging resumes
from 80 %, the row should read "Time to 85%" with minutes, not "Almost done".

**Still open from round 3 (not in this pass):** time to 100 % unvalidated above raw 85 % (A-B2,
B-B1, Medium); remaining-energy model 1.5–4 % optimistic (B-B4); "Power, last min" falls back
to one instant reading after a gauge pause (B-B5); health readings saved only on plug/unplug
(B-B6); reaped-child CPU shown on the parent row (A-C1); accessory agents as app rows (A-C2).

---

## Where this leaves things (2026-10-05, end of session)
- Branch `fix/readings-accuracy`, v1.1.0, **installed locally, not pushed, no GitHub release**.
  To ship: merge to `main`, push, `./Scripts/package-release.sh`, then
  `gh release create v1.1.0 dist/MacStats.app.zip --title "MacStats 1.1.0" --notes "..."`.
- Open items worth doing next: log one awake charge to 100 % (limit off) and add it as a
  calibration test for `minutesToTarget` above 85 %; some background agents (`universalaccessd`,
  `loginwindow`, `ChatGPTHelper`) still appear as their own 0 % rows in the CPU breakdown
  (filter to `activationPolicy == .regular` or group them under "Other processes"); the popover-open
  CPU cost of MacStats itself was never measured on screen (needs a human to open it and watch
  Activity Monitor).
