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

- Owner decisions (2026-10-18): (1) keep MacStats' steady times and show macOS's own figure in
  the row tooltips (done: `BatterySample.macOSTimeToEmptyMinutes` / `macOSTimeToFullMinutes`,
  `Sources/MacStatsApp/BatteryDetailsCard.swift`); (2) use coalition counters with a safe
  fallback (done, see below).
- Charge limit at the stop: macOS reports only "not charging", so MacStats said "Plugged in, not
  charging" at the owner's 85 % limit. Now it says "Charged to 85% limit" / card "at 85% limit"
  (`BatterySample.heldAtLimitPercent`, `Sources/MacStatsCore/BatteryParse.swift`). The limit itself was
  already detected from powerd's file (`manualChargeLimit` 85).
- Exited processes' CPU/energy are now exact from the kernel's coalition counters
  (`docs/design/breakdown-stability.md` rule 4a). Live headless probe (scratch, not in repo): a
  shell restarting 0.3 s `yes` processes: app total equal to the old estimate (15.8 %), but the
  ~12 % now shows on "Finished processes" (was credited to the reaping shell). Rows always equalled
  the header (the old estimate overshot it in 3 of 11 scans: 34.8 % vs 24.0 %). Energy is measured
  (~5.1 W vs the estimate's 4.9 W; in one burst the estimate read 15.2 W vs 10.9 W measured). 388 tests pass.

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
| Exited processes' CPU/energy | was own estimate | SWITCH (done, owner OK'd): kernel coalition counters via `coalition_info_resource_usage`, with layout/consistency guards and the old estimate as fallback |

Optional polish noted, not done: Apple's held-at-limit wording ("Charged to 85% Limit", from
`ChargerData.NotChargingReason` bit 0x1000000) instead of "Plugged in, not charging"; dead code
`directorySize(at:)` in `Sources/MacStatsCore/DiskUtils.swift` (tests only).

## Next steps

- Merge: see the handoff for the Sparkle session (merge `fix/battery-health` after `feat/sparkle-updates`).
