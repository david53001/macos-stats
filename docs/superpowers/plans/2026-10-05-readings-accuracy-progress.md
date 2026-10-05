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
  **Still open (needs the Mac plugged in):** time to full above 80 % divides by the smoothed
  measured current, which keeps falling in the constant-voltage phase, so it likely reads short.
  Check: log `ioreg -rn AppleSmartBattery` `Amperage` + percent every 30 s from ~75 % to 100 %
  and compare with `minutesToTarget` in `Sources/MacStatsCore/BatteryCharging.swift`.
- [ ] **Independent accuracy review** (user's bar: ≥ 8/10, aim for 9 if cheap; if below, fix and
  re-review). Two reviewers with the same brief write
  `docs/reviews/2026-10-05-readings-accuracy-review-A.md` and `-B.md`. The brief is
  `docs/reviews/2026-10-05-readings-accuracy/reviewer-brief.md` (fill in `{REPORT}` and a
  scratch dir). If the reports are missing after a session cut-off, launch fresh general-purpose
  subagents with that brief.

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
