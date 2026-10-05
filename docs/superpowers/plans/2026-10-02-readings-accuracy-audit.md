# Readings accuracy audit: what MacStats shows vs what the Mac is really doing (2026-10-02)

**Status:** investigation only. Nothing is fixed yet. This file lists what is wrong, the
evidence for it, and the proposed fixes, ordered by priority. It is written so a fresh session can
start fixing from here.

**Trigger:** a video render (`ffmpeg`, started from a Claude Code session in Terminal) was using
about 6–8 of the 8 CPU cores. MacStats' CPU breakdown showed **JVoice** as the top app at
"100%", and the render did not appear anywhere.

**Setup:** M3 MacBook (8 cores, 16 GB, 16 KB pages), macOS 26. Installed MacStats **v1.0.1**
(`~/Applications/MacStats.app`, built 2026-10-01). Code measured: branch `feat/polish-perf` at
`82e2251`.

---

## Terms

- **% of one core vs % of machine.** `top`, `ps` and Activity Monitor show per-process CPU where
  **100% = one core fully busy**, so an 8-core Mac can reach 800%. The MacStats CPU *card* and the
  breakdown *header* ("98% used") are **% of the whole machine** (max 100%).
- **Breakdown.** The drill-in screen you get by clicking the CPU, Memory or Battery card. It lists
  apps, and each app's number is the sum over its processes.
- **Grouping / owning app.** To decide which app a process belongs to, MacStats walks up the
  process's **parent chain** (each process records the pid (process id) of the process that
  started it, its *ppid*) until it reaches a pid that is a running GUI app (an
  `NSWorkspace.runningApplications` entry). Code: `owningAppPID` in
  `Sources/MacStatsCore/ProcessBreakdown.swift`. A process whose chain never reaches an app is
  **dropped** from the breakdown.
- **Physical footprint.** The memory a process is responsible for. This is the Activity Monitor
  "Memory" column (already used since v1.0.1).
- **Activity Monitor "Memory Used"** = App Memory + Wired + Compressed, where App Memory =
  anonymous (non-file) pages minus purgeable pages. File cache is **not** counted as used.

---

## Summary table

| Reading | Verdict | MacStats said | Reality | Section |
|---|---|---|---|---|
| CPU card / breakdown header (whole machine %) | ✅ correct | 98.0% | `top`: 98.5% busy | §6 |
| Per-app CPU, apps whose processes are direct descendants | ✅ correct (fixed in v1.0.1) | `yes` 100% | `top` 99.5% | §6 |
| **Per-app CPU, anything run from Terminal** | ❌ **completely missing** | Terminal **5.8%** | `ffmpeg` **775%** under Terminal | §1 |
| **CPU breakdown display** | ❌ misleading | JVoice "100%", full bar | JVoice = 1 of 8 cores, ~12% of the machine | §2 |
| Per-app CPU, short-lived processes | ⚠️ undercounts | — | up to 1 s per process lost | §3 |
| **Memory card "used"** | ❌ **~1.1 GB too high** | **9.14 GB** | Activity Monitor formula **8.05 GB** | §4 |
| **Per-app memory** | ❌ same grouping bug as CPU | 1.85 GB shown | +3.94 GB in dropped processes (incl. ffmpeg 915 MB) | §1 |
| Battery % | ✅ correct | 70% | `pmset`: 70% | §6 |
| Battery health | ⚠️ off by 1 | 100% | System Settings: **99%** | §5 |
| **Per-app battery power** | ❌ same grouping bug + first-interval 0 W | — | — | §1, §5 |
| Network speed | ⚠️ not measured; 2 code-level risks | — | — | §5 |
| CPU temperature | ❔ not checked (needs `sudo powermetrics`) | — | — | — |

**So:** the overall CPU number and battery % are right. The per-app lists (CPU, Memory and
Battery) are wrong whenever work runs inside Terminal, and the memory card is about 1 GB high.

---

## 1. (Critical) Everything started from Terminal is invisible in every breakdown

### What happens
`readRawProcesses()` (`Sources/MacStatsCore/ProcessReader.swift`) keeps **only the current user's
processes** (`bsd.pbi_uid == uid`). The ppid map that `owningAppPID` walks is built from that
filtered list (`procScanTick` in `Sources/MacStatsApp/MacStatsApp.swift`). Every Terminal tab
looks like this:

```
Terminal (1299, user)  ←  login (1546, **root**)  ←  -zsh (1547, user)  ←  claude  ←  zsh  ←  python build.py  ←  ffmpeg
```

`login` is owned by **root**, so it isn't in the map. The walk from `ffmpeg` stops at `login`,
never reaches Terminal, and returns nil, so the process is **dropped**. That covers every shell,
every Claude Code session, every build and every render started in Terminal. Terminal itself shows
only its own window-drawing CPU (about 5%).

The same breakage hits anything whose chain passes through another user's process, and anything
started by `launchd` (macOS's process launcher, pid 1) on an app's behalf (XPC services, i.e. helper processes macOS runs for an app, such as `ANECompilerService`, Safari
WebContent). The last case was already listed as "by design" in
`docs/superpowers/plans/2026-10-01-process-accuracy.md`.

### Evidence (live, during the real render, 2026-10-02 ~19:15)
A scratch harness that runs MacStats' **own code** (`readRawProcesses`, `owningAppPID`,
`aggregate`, `cpuBusyPercent`, compiled straight from `Sources/MacStatsCore`, with the same 1 s scan
as `procScanTick`) was run side by side with `top`:

```
MacStats logic:   system card: 98% used   sum of all own processes: 770%   not-in-any-app: 764%
                  Terminal 5.8%  ·  WindowManager 0.2%  ·  Google Chrome 0.0%  ·  …
top:              ffmpeg 775.0% (ppid 13802 = python build.py)  ·  Terminal 5.1%  ·  WindowServer 4.0%
```

Controlled repro: 4 × `yes > /dev/null` started from Terminal for 6 s. `top` showed four `yes` at
about 99% each. MacStats logic showed Terminal at 3.7% and **620% unattributed**.

Memory, the same moment: **333 of 393** of the user's processes are dropped, totalling **3.94 GB**,
against **1.85 GB** shown. The biggest dropped ones were `ffmpeg` 915 MB and two Claude Code sessions
(343 MB and 314 MB).

Reading a root process's ppid with `proc_pidinfo(PROC_PIDTBSDINFO)` **fails** (returns 0 bytes),
which is why the obvious "just don't filter by uid" fix isn't enough on its own.

### Why JVoice looked like the culprit
With the render invisible, the top visible app wins. JVoice had just launched (19:07:55;
screenshot at 19:08:46) and was loading its Whisper model, using one core fully (36 s of CPU
time in its first ~100 s, then 0%). So the "JVoice 100%" was real, but it meant **one core**,
not the machine (§2).

### Proposed fix
1. **Attribute by "responsible process"** instead of only the parent chain. macOS records, for
   every process, which app is responsible for it (this is how Activity Monitor and the
   privacy-permission prompts attribute work). The function is
   `responsibility_get_pid_responsible_for_pid(pid_t) -> pid_t`, exported by `libSystem` but not
   in a public header: declare it via `@_silgen_name` or a small C shim. `CAppleSensors` already
   exists for this kind of private API. For processes in a Terminal tab it should return
   Terminal's pid, and for app XPC helpers the app. **Verify both on-device**; this is expected
   behaviour, not yet tested here. Fall back to the ppid walk if it returns ≤ 0.
2. Build the ppid map from **all** processes, not just the user's: use
   `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL)` (`kinfo_proc.kp_eproc.e_ppid`), which `ps` uses
   and which works for root processes. Keep the uid filter only for what gets **counted**.
3. Add an **"Other processes"** row for user processes that still map to no app, so the rows add
   up to the header. Decide whether it should be clickable, and whether it should hide Quit /
   Force Quit.
4. Apply the same attribution to the Memory and Battery (energy) breakdowns. They share
   `procScanTick`, so fixing the grouping fixes all three.
5. Tests: add a `owningAppPID`/attribution test with a non-user intermediate parent
   (`app ← root-login ← zsh ← child`) and assert the child maps to the app.

---

## 2. (High) The CPU breakdown mixes two scales and the bar is relative

- The **header** (`liveTotal` in `Sources/MacStatsApp/BreakdownView.swift`) is % of the
  **machine** (0–100).
- Each **row** (`valueText`) is % of **one core** (0–800 on this Mac). This matches Activity
  Monitor, but sitting right under a machine-wide header it reads as "this app is using all of my
  CPU".
- The **bar** (`fraction`) is the app's value divided by the **top row's** value, so the top app
  always has a full bar, even at 1% of the machine.

Result in the screenshot: header "100% used", JVoice "100%" with a full green bar, so JVoice looked
like it was using 100% of the Mac when it was using about 12%.

**Proposed fix (pick one, then apply to both header and rows):**
- Show rows as % of the machine (`cpuPercent / activeProcessorCount`), and make the bar the share
  of the machine (`value / 100`). Rows then sum to the header (with the "Other" row from §1).
  **Recommended.**
- Or keep per-core rows and change the header to the same scale (for example "620% of 800%"),
  with bars scaled to `100 × cores`.

---

## 3. (Medium) Short-lived processes lose CPU time between scans

Per-app CPU is the difference in each pid's cumulative CPU time between two scans, 1 s apart
(`breakdownScanInterval`, `Sources/MacStatsCore/RefreshScheduler.swift`). A process that **exits**
before the next scan loses all its CPU since the last scan. One that starts and exits between
two scans is never seen. The render ran one `ffmpeg` per clip (each a few seconds long), so
roughly 10–30% of its CPU fell in these gaps, even after §1 is fixed.

**Proposed fix:** also track `ri_child_user_time + ri_child_system_time` from
`proc_pid_rusage(RUSAGE_INFO_V6)`, which is already called per process. When a child exits and
is reaped, the kernel adds its total CPU time to the parent's `ri_child_*`. So the increase in a
surviving parent's child time covers children that exited. Subtract the last cumulative value already
seen for each child that disappeared, so its earlier intervals aren't counted twice. (These fields
may be in Mach ticks like `pti_total_*`; check against `getrusage(RUSAGE_CHILDREN)` the way
`cpuTimeIsInNanoseconds` does.) Lower priority than §1 and §2.

---

## 4. (High) Memory card "used" is about 1.1 GB too high

`memorySample` (`Sources/MacStatsCore/MemoryStats.swift`) computes
`used = (active + wired + compressed) × pageSize` and says it "approximates Activity Monitor".
It doesn't:

- **`active` includes file-backed pages** (cached files that macOS frees instantly when needed),
  which Activity Monitor does **not** count as used.
- It **leaves out inactive anonymous pages** (real app memory that is temporarily inactive),
  which Activity Monitor **does** count.

Measured at the same moment, from the same `host_statistics64(HOST_VM_INFO64)` read:

| Formula | Value |
|---|---|
| MacStats: active + wired + compressed | **9.14 GB** |
| Activity Monitor: (internal − purgeable) + wired + compressed | **8.05 GB** (app memory 5.02 GB) |
| `top` "PhysMem used" (everything but free, includes cache) | 15 GB |

The error moves in both directions with workload, since it is file cache in and inactive app
memory out. Today it was +1.1 GB (+14%).

**Proposed fix:** `used = (internal − purgeable + wired + compressed) × pageSize`.
- `internal` = `vm.page_pageable_internal_count` (sysctl) or `stats.internal_page_count`.
- `purgeable` = `vm_statistics64.purgeable_count`.
- `compressed` = `compressor_page_count` (pages the compressor *occupies*, which is what Activity
  Monitor shows as "Compressed").

Add both to `VMRaw`, update `memorySample`, and update its unit test. Then check by eye against
Activity Monitor → Memory tab → "Memory Used" (this audit compared against the formula, not
Activity Monitor's screen).

---

## 5. Smaller issues

- **Battery health shows 100%, System Settings shows 99%.** `healthPercent`
  (`Sources/MacStatsCore/BatteryTelemetry.swift`) is `NominalChargeCapacity / DesignCapacity`
  **rounded**: 4542 / 4563 = 99.54% → 100. `system_profiler SPPowerDataType` reports "Maximum
  Capacity: 99%", so Apple appears to truncate. Fix: use `floor` instead of `.rounded()`. Check
  again on a second reading where the fraction is below .5, to confirm the formula and not just the
  rounding.
- **Per-app battery power** (Battery screen app list) uses the same grouping as §1, so renders
  and builds started in Terminal draw power that no app is charged for. It also still has the
  known "new process reads 0 W for its first interval" issue (previous audit,
  `2026-10-01-process-accuracy.md`). Fix it like CPU bug 3 there: baseline 0 for pids not seen
  last scan.
- **Network: 32-bit counters.** `readNetCounters` (`Sources/MacStatsCore/SystemReaders.swift`)
  reads `if_data.ifi_ibytes/ifi_obytes`, which are `u_int32_t` (SDK `net/if_var.h:170`), so each
  interface's counter wraps every 4 GiB. `networkThroughput` then clamps that sample to 0. Today
  that costs one dropped sample per 4 GiB, but on fast downloads it means a blip to 0. Fix:
  64-bit counters via `sysctl` `NET_RT_IFLIST2` (`if_msghdr2.ifm_data` is `if_data64`).
- **Network: tunnels may double count.** All non-loopback interfaces are summed, including
  `utun*` (VPN / Tailscale / sing-box tunnels) and `bridge0`. Traffic through a VPN is counted
  once on the tunnel and again on `en0`, so the speed reads up to 2× high while a VPN is on.
  **Not measured** (no VPN was active, utun traffic was ~KB). To verify: turn on Tailscale, run a
  download, and compare MacStats to `nettop -m route` or `netstat -ib` deltas on `en0` only.
  Likely fix: skip `utun*`, `ipsec*`, `bridge*`, `llw*`, `awdl*`, `anpi*`, `ap*`.
- **"Apps" that aren't apps.** The breakdown listed `chronod` and "Google Chrome Helper" as
  separate apps, because `runningApplications` includes some background agents. Consider
  filtering to `activationPolicy == .regular` (Dock apps), or grouping helpers by bundle prefix.
- **Not a reading bug, noticed once:** MacStats itself appeared at 30.9% CPU in `ps` at one point
  (possibly while a breakdown was open, scanning ~400 processes per second). Not investigated.

---

## 6. Checked and correct

| Reading | MacStats code | Check | Result |
|---|---|---|---|
| CPU card (machine %) | `cpuBusyPercent`, `HOST_CPU_LOAD_INFO` | same 3 s window as `top -l 2 -s 3` | 98.0% vs 98.5% (98.65% user+sys) ✅ |
| Per-process CPU (single process) | `pti_total_*` → ns (v1.0.1 fix) | `yes` vs `top` | 100% vs 99.5% ✅ |
| Battery % | `parseBattery` (IOPS = IOKit power-sources API, current/max) | `pmset -g batt` | 70% vs 70% ✅ |
| Cycle count | `CycleCount` | `system_profiler SPPowerDataType` | 127 vs 127 ✅ |
| Time left | own estimator (`BatteryEstimator`) | macOS: 2:31 | Different on purpose (smoothed). Not a bug. |

---

## How to reproduce

All measurements compiled MacStats' own `Sources/MacStatsCore` files into a throwaway binary.
**Important:** the default SDK (MacOSX27.0) doesn't match the installed Swift 6.3 compiler, so pass
`-sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.

```bash
cd ~/Desktop/Home/Projects/Code/MacStats
mkdir -p /tmp/ms-harness && cat > /tmp/ms-harness/main.swift <<'EOF'
import AppKit
// Replicates AppModel.procScanTick (1 s scans) and prints what the CPU breakdown would show.
var prev: [Int32: UInt64] = [:]; var last: Date? = nil; var prevTicks = readCPUTicks()
for scan in 0..<4 {
    let now = Date(); let raw = readRawProcesses()
    let appPIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.processIdentifier > 0 ? Int32($0.processIdentifier) : nil })
    let ppid = Dictionary(raw.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
    let el = last.map { now.timeIntervalSince($0) } ?? 0
    var usages: [ProcessUsage] = []; var orphan = 0.0
    for p in raw {
        let cpu = last != nil ? processCPUPercent(previousCPUTimeNs: prev[p.pid] ?? 0, currentCPUTimeNs: p.cpuTimeNs, elapsedSeconds: el) : 0
        guard let a = owningAppPID(for: p.pid, ppid: ppid, appPIDs: appPIDs) else { orphan += cpu; continue }
        usages.append(ProcessUsage(pid: p.pid, appPID: a, cpuPercent: cpu, memoryBytes: p.memoryBytes))
    }
    prev = Dictionary(raw.map { ($0.pid, $0.cpuTimeNs) }, uniquingKeysWith: { a, _ in a }); last = now
    let t = readCPUTicks(); let sys = cpuBusyPercent(previous: prevTicks, current: t); prevTicks = t
    if scan > 0 {
        print(String(format: "card %.0f%%  not-in-any-app %.0f%%", sys, orphan))
        for app in aggregate(usages, by: .cpu).prefix(5) {
            print(" ", NSRunningApplication(processIdentifier: app.appPID)?.localizedName ?? "?", String(format: "%.1f%%", app.cpuPercent))
        }
    }
    Thread.sleep(forTimeInterval: 1.0)
}
EOF
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -O -o /tmp/ms-harness/h \
  Sources/MacStatsCore/{ProcessReader,ProcessBreakdown,CPUUsage,SystemReaders,MemoryStats,NetworkThroughput,BatteryParse}.swift \
  /tmp/ms-harness/main.swift
# Load from Terminal (4 cores, 6 s), then compare:
for i in 1 2 3 4; do (yes > /dev/null & P=$!; sleep 6; kill $P) & done; sleep 0.5
/tmp/ms-harness/h & top -l 3 -s 1 -o cpu -n 6 -stats pid,command,cpu,ppid | tail -7; wait
```

Expected **before** the fix: `top` shows four `yes` at ~99%, the harness shows Terminal at a few
% and ~400% "not-in-any-app". **After** the fix: Terminal (or an "Other" row) at ~400%.

Memory check: `vm_stat` plus `sysctl vm.page_pageable_internal_count vm.page_purgeable_count`,
then compute both formulas in §4.

## Suggested order of work
1. §1 attribution (responsible pid + full ppid map + "Other" row) → fixes CPU, Memory and
   Battery lists together.
2. §2 one scale for header, rows and bars.
3. §4 memory formula.
4. §5 battery health rounding, energy first-interval baseline, 64-bit network counters.
5. §3 child CPU time for short-lived processes.
6. Verify each with the harness above and `./Scripts/test.sh`; reinstall with
   `./Scripts/bundle.sh`; bump the version and add a Status line in `CLAUDE.md`.
