# Process attribution, expandable breakdown, one CPU scale, memory formula (2026-10-05)

**Branch:** `readings/process-memory` (based on `fix/readings-accuracy` at `42ddd09`), to be
merged into `fix/readings-accuracy`. Implements audit
`docs/superpowers/plans/2026-10-02-readings-accuracy-audit.md` §1, §2, §3, §4 and the energy
part of §5, plus the user's "expandable app rows" request. Battery readings are a separate
branch (`readings/battery`).

## Build note (environment, not code)
On 2026-10-04 the Command Line Tools update made `MacOSX.sdk` point to **MacOSX27.0.sdk**, whose
SwiftUI needs a `SwiftUIMacros` compiler plugin that the CLT doesn't ship. Every `@State` then
fails with *"plugin for module 'SwiftUIMacros' not found"*, even on unchanged code. Workaround:

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./Scripts/test.sh
```

`Scripts/*.sh` were not changed. `bundle.sh`, `install.sh` and `package-release.sh` need the same
variable until the CLT ships the plugin.

## What changed

| Area | Change | Code |
|---|---|---|
| Attribution | Per process, then per ancestor: the **responsible app** wins (`responsibility_get_pid_responsible_for_pid`, looked up with `dlsym`, so it falls back to the parent chain if missing). Otherwise the process itself if it is an app, otherwise its parent. A parent chain that passes a root process (a Terminal tab's `login`) uses the full `KERN_PROC_ALL` table, fetched lazily. Owners are cached per pid + start time and dropped when the set of running apps changes. | `Sources/MacStatsCore/ProcessScan.swift` (`owningAppPID(for:parent:responsible:appPIDs:)`, `ProcessAttributor`) |
| Other / System rows | User processes no app owns go to **Other processes** (`BreakdownGroup.otherProcesses = -1`) instead of being dropped. CPU also gets a **System** row (`-2`): the whole-machine CPU over the same interval minus the rows, so the rows add up to the header. | `ProcessBreakdown.swift` (`addingSystemRow`), `ProcessScan.swift` (`BreakdownScanner`) |
| One CPU scale | `ProcessUsage.cpuPercent` is now a **share of the whole Mac** (Activity Monitor's figure ÷ cores). Bars are value/100 for CPU and value/RAM for memory. The CPU header comes from the scan's own interval (`MetricsStore.breakdownTotalCPU`). Footer: "Share of the whole Mac (all N cores)". The process context menu shows the Activity Monitor figure. | `ProcessScan.swift`, `MetricsStore.swift`, `Sources/MacStatsApp/BreakdownView.swift` |
| Interval usage | A new pid counts from 0 for CPU **and energy**: energy used to read 0 W for a new process's first interval. A pid merely missed by the last scan (started earlier) gets no baseline, rather than its whole lifetime at once. Reused pids are told apart by `ri_proc_start_abstime`. **Exited children:** the growth of a surviving parent's `ri_child_*` time (Mach ticks, converted), minus what was already counted for its vanished descendants, is credited to the parent. A child not yet reaped carries its "debt" to the next scan. | `ProcessScan.swift` (`ProcessSampler`) |
| Reader | `PROC_UID_ONLY` + `PROC_PIDT_SHORTBSDINFO` + one `rusage_info_v6` read per process. Task info is used only as a fallback. New fields: `childCPUTimeNs` and `startTime`. New helpers: `readAllParentPIDs`, `responsiblePID(for:)`, `processName` (full 32-char name; argv[0] when the name is version-like, e.g. Claude Code's "2.1.289"), `startTimeOfOwnProcess`. | `Sources/MacStatsCore/ProcessReader.swift` |
| Expandable rows | Click an app with 2+ processes to expand it (accordion, one at a time). Each process row shows its name, pid, own value and a thin bar. The top 5 show first, then "n more…" adds 25 at a time. The list is flattened so the `LazyVStack` builds only the visible rows. Names are read only for the rows shown and cached per pid + start time (`AppInfoCache.name(ofProcess:startTime:)`). Process right-click: Quit (SIGTERM) / Force Quit (NSAlert, then SIGKILL) for that pid only, after re-checking that the pid is ours with the same start time. | `BreakdownView.swift`, `ProcessActions.swift` |
| First rescan | 0.3 s → 0.5 s (0.3 s windows were mostly noise for bursty apps). | `RefreshScheduler.swift` |
| Memory card | used = (internal − purgeable) + wired + compressor-occupied pages (Activity Monitor's "Memory Used"). | `MemoryStats.swift`, `SystemReaders.swift` |

No new timers. All new per-process work runs inside the existing breakdown scan, and the
scanner (with its caches) exists only while a breakdown is open (`AppModel.scanner`).

## Verification (2026-10-05, M3, 8 cores)
- `swift build` green; `./Scripts/test.sh`: **146 tests pass** (with the SDKROOT above).
- Harnesses in `/private/tmp/claude-501/-Users-davidghermansteinberg-Desktop-Home-Projects-Code-MacStats/8ced4f77-8947-4754-9fe0-dff151720539/scratchpad/impl-process-memory/`.
  They are scratch files and may be gone; to rebuild them, compile `Sources/MacStatsCore/*.swift`
  plus a `main.swift` with `swiftc -sdk …/MacOSX26.5.sdk -O`.
  - **4 × `yes` under `script → login (root) → sh`** (the same structure as a Terminal tab).
    The old code drops all four and their shell. The new code puts them under Code: by
    responsible pid, and also by the full-table walk with the responsible pid disabled.
    Breakdown: header 51.2 %, Code 50.2 % (= 402 % of one core), each `yes` 12.5 %, rows sum
    = header. `KERN_PROC_ALL` fetched 0 times.
  - **Short-lived children** (one `yes` alive 0.2 s at a time, for 7 s): Code reads 12.4–13.1 %
    (one core) every scan, mostly credited to the parent shell. Without the credit it would show
    ~0.5–2 %.
  - Memory card 10.3 GiB vs `vm_stat` (anonymous − purgeable + wired + compressor) 10.36 GiB.
    Memory rows: Other processes 2.6 GB (mediaanalysisd 99 MB, …), Code 2.2 GB, Chrome 1.9 GB.
  - **Scan cost** (thread CPU time, 1 Hz, 3 alternating runs): before ~6.8 ms/scan steady,
    after ~5.6 ms steady; the first scan is ~7.6 ms (responsibility lookups, then cached).
- UI checked with an off-screen `ImageRenderer` render of a scratch copy of `BreakdownView`
  (ScrollView swapped for VStack, one row pre-expanded). It was **not** clicked through in the
  running app.

## Not done / follow-ups
- **Idle overhead** (CPU investigation): with the popover closed, MacStats spends ~50–190 ms
  every 10 s re-rendering the closed popover's SwiftUI views after each idle `store.record`.
  Not touched here (it's in the idle sampling path the battery branch also edits). Proposed
  fix: buffer idle samples without publishing, and publish once on open.
- Memory rows + Other don't add up to Memory Used, and can't: kernel, root processes,
  compression. There's a footer note for this; there's no System row for memory on purpose.
- Children reaped by launchd (orphans) are still uncounted. Energy has no child credit, because
  rusage has no child-energy field.
