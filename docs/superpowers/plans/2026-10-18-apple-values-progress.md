# Apple-values audit — progress (2026-10-18)

**Goal (owner):** every reading MacStats shows should use Apple's own value wherever macOS
exposes one (readable without entitlements or sudo), not a MacStats calculation. Started from
the Health bug: MacStats showed 97 % (`NominalChargeCapacity / DesignCapacity` = 4429 / 4563)
while System Settings → Battery → Maximum Capacity said 99 %.

**Where:** branch `fix/battery-health` (off `feat/stability-tour`), worktree
`/Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats/.claude/worktrees/battery-health`.
Do NOT touch `.claude/worktrees/sparkle-updates` (branch `feat/sparkle-updates`): a separate
workflow runs there.

## Done

- Health = macOS's "Maximum Capacity" from `system_profiler SPPowerDataType -json`
  (`readMaximumCapacityPercent`, `Sources/MacStatsCore/BatteryTelemetry.swift`), read off the main
  thread at launch and hourly; gauge-peak fallback. Commit `986064e`. 375 tests pass. Installed.

- Trash size printed in Finder's units: `ByteCountFormatter` `.file` (1000-based) instead of
  dividing by 1024 (a Trash Finder calls "1.5 GB" read "1.4 GB"), `Sources/MacStatsApp/OverviewView.swift`.
- Trash size no longer silently low: Finder answers `missing value` for a folder whose size it
  hasn't computed yet, which the AppleScript counted as 0; it now retries ~2 s, else the read is
  "unknown" (`Sources/MacStatsApp/TrashActions.swift`).
- 375 tests pass (`./Scripts/test.sh`); reinstalled with `./Scripts/bundle.sh`.

## Findings (three read-only audits, live on the M3, 2026-10-18)

Verdicts: KEEP = already Apple's number (or Apple's raw sensor with no Apple screen to match);
DESIGN CHOICE = MacStats' own on purpose; SWITCH = changed.

| Reading | Source | Verdict |
|---|---|---|
| Battery percent, state, cycles, adapter W | IOPS (`IOPSCopyPowerSourcesInfo`) / `AppleSmartBattery` registry | KEEP (= `pmset`, `system_profiler`) |
| Health | `system_profiler` "Maximum Capacity" | SWITCH (done) |
| Charge limit / hold | `/Library/Preferences/com.apple.powerd.charging.plist` (powerd's file) | KEEP |
| Time to 85 % / full | own: measured current + taper to powerd's limit | KEEP. Apple's `Time to Full Charge` / `AvgTimeToFull` / `pmset` count to **100 %**: live they said ~1 h (64→72→79→53 min) while charging stopped at 85 % 5 min later |
| Time left on battery | own steady estimate | DESIGN CHOICE (earlier decision). Apple's IOPS `Time to Empty` is free to read but swings 3 h ↔ 13 h with the last minute's load. Open question for the owner: show it as a tooltip? |
| Power now / temperature | `PowerTelemetryData` system load (Apple's sensor, 1-min average) / registry `Temperature` | KEEP (no Apple screen shows them) |
| CPU % | `host_processor_info` ticks, = `top` / Activity Monitor | KEEP |
| Memory used / parts / pressure | `host_statistics64` App + Wired + Compressed; `kern.memorystatus_vm_pressure_level` | KEEP (= Activity Monitor; Compressed matched `top` exactly) |
| Network | `IFMIB_IFALLDATA` 64-bit byte counters | KEEP (= `netstat -ib`) |
| Chip temperature | private HID `PMU tdie*` sensors | KEEP: macOS shows no CPU temperature anywhere, so there's no Apple number |
| Trash | Finder AppleScript size | SWITCH (units + undercount, done) |
| Per-app CPU, memory | `proc_pid_rusage` CPU time / physical footprint | KEEP (matched `top`/`footprint` within 0.5) |
| Per-app watts | `ri_energy_nj` (kernel-measured CPU energy) | KEEP. Activity Monitor's "Energy Impact" isn't readable without Apple entitlements (only `top`, a setuid tool) |
| Exited processes' CPU/energy | own estimate | PROPOSAL, not done: the kernel's per-app "coalition" counters (`syscall 459`, no root needed) count exited helpers exactly, but their struct isn't in public headers and adopting them rewrites the breakdown's accounting, so it needs the owner's OK first |

Optional polish noted, not done: Apple's held-at-limit wording ("Charged to 85% Limit", from
`ChargerData.NotChargingReason` bit 0x1000000) instead of "Plugged in, not charging"; dead code
`directorySize(at:)` in `Sources/MacStatsCore/DiskUtils.swift` (tests only).

## Next steps

- Owner decisions: time-left tooltip with macOS's figure? coalition counters for exited processes?
- Merge: see the handoff for the Sparkle session (merge `fix/battery-health` after `feat/sparkle-updates`).
