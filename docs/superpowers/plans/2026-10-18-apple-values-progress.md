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

## In progress

- Three read-only audits (battery; overview cards CPU/memory/network/temperature/trash; per-app
  breakdown CPU/memory/energy) comparing each reading to Apple's own value. Findings and the
  fixes made from them go below.

## Findings

(pending)

## Next steps

1. Apply SWITCH verdicts in the worktree, add tests, `./Scripts/test.sh`.
2. `./Scripts/bundle.sh && open ~/Applications/MacStats.app` (reinstall for the owner's test).
3. Update the `CLAUDE.md` status line for `fix/battery-health`.
