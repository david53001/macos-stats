# Per-app CPU % and Memory accuracy fix (2026-10-01, v1.0.1)

Fixes the per-app numbers in the CPU and Memory breakdowns so they match Activity Monitor.
Branches `fix/process-memory-footprint` (7db5dd9) and `fix/process-cpu-percent` (f0a43a2),
merged into `feat/polish-perf` and `main`, released as **v1.0.1**.

## Terms
- **RSS (resident set size)** — all memory pages a process has in RAM, *including* shared
  system-framework pages that every app maps. Overstates per-app use.
- **Physical footprint** — memory the process itself is responsible for (incl. compressed
  pages). This is Activity Monitor's "Memory" column and what `footprint <pid>` / `top`'s MEM print.
- **Mach absolute-time units** — the kernel's clock ticks. 1 tick = `numer/denom` ns from
  `mach_timebase_info`: 1/1 on Intel, **125/3 on Apple Silicon** (24 MHz).

## Bugs and fixes (all in `Sources/MacStatsCore/ProcessReader.swift` unless noted)
1. **Memory used RSS.** `memoryBytes` was `pti_resident_size`. Now `ri_phys_footprint` from
   `proc_pid_rusage(RUSAGE_INFO_V6)` — the same call already used for energy, so it's one call
   per process for both; falls back to RSS only if that call fails.
2. **CPU time was not in nanoseconds on Apple Silicon.** `pti_total_user + pti_total_system`
   is in Mach ticks, but `processCPUPercent` treated it as ns → per-app CPU % was ~41.7× too low
   (a process using a full core showed 2.4 %). Now converted with `machTicksToNanoseconds`
   (timebase cached once, overflow-safe). Intel is unaffected (1/1).
3. **New processes showed 0 % for their first interval** (`Sources/MacStatsApp/MacStatsApp.swift`,
   `procScanTick`). Their baseline was their own current CPU time; a pid missing from the previous
   scan is new, so its baseline is now 0.

The system-wide CPU % card was checked against `top` and was already correct.

## Verification (M3 MacBook, macOS 26)
Memory (MB) — new reader vs ground truth:

| Process | Old (RSS) | New (footprint) | `footprint` | `top` MEM |
|---|---|---|---|---|
| BetterScreenshot | 143.2 | 129.3 | 129 | 129M |
| MacStats | 84.9 | 26.4 | 27 | 26M |
| Finder | 72.2 | 48.3 | 48 | 48M |
| Chrome Helper (Renderer) | 138.3 | 53.0 | 53 | 53M |
| JVoice | 73.3 | 38.3 | 38 | 38M |

CPU % (two `yes > /dev/null` loads, sampled 2 s apart):

| Process | Old % | New % | `top` % | `ps %cpu` |
|---|---|---|---|---|
| `yes` #1 | 2.40 | 100.0 | 91.7 | 100.0 |
| Chrome Helper | 0.09 | 3.7 | 3.4 | – |
| System CPU card | – | 29.5 | 29.8 | – |

New tests in `Tests/MacStatsCoreTests/ProcessReaderSmokeTests.swift`:
`memoryIsPhysicalFootprint` (vs `task_info(TASK_VM_INFO).phys_footprint`),
`machTicksConvertToNanoseconds`, `cpuTimeIsInNanoseconds` (vs `getrusage`).
`./Scripts/test.sh` → 117 tests, all pass.

## Known, not fixed
- Per-app battery power (Battery screen, `ri_energy_nj` deltas) has the same "new process
  baseline = its own current value" issue as bug 3 — new processes read 0 W for one interval.
- System CPU tick counters are 32-bit; on an 8-core Mac they wrap after ~62 days of uptime,
  giving one bad (0 %) sample.
- PID reuse between scans isn't detected (rare).
- Helpers launched by launchd rather than the app (e.g. Safari WebContent) aren't grouped
  under their app — grouping is by parent pid, by design.
