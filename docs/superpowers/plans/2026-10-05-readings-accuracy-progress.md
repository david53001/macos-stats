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
- [ ] Workflow running (run ID `wf_cbc02384-581`, launched from the main Claude Code session).
  Implementation agents work on branches `readings/process-memory` and `readings/battery`
  (in temporary git worktrees), which get merged into `fix/readings-accuracy`. If the session
  dies mid-run, check `git branch` for those branches and continue from whatever got merged.
  The finalize step appends the results below.
- [x] Verify round 1 battery fixes (`fix-r2`): `BatteryEstimator` averages are now
  bias-corrected EMAs (the first gauge interval no longer counts as a whole time constant:
  a 9.5 W unplug spike then 1.8 W read −66 % at 10 min, now −20 %; −50 % at 30 min, now −4 %);
  the charge limit is learned only when charging stops (charging → held), not from a full Mac
  drifting to 95–99 % on AC; "Almost full" instead of "Calculating…" while charging at 100 %.
  **Still open (needs the Mac plugged in):** time to full above 80 % divides by the smoothed
  measured current, which keeps falling in the constant-voltage phase, so it likely reads short.
  Check: log `ioreg -rn AppleSmartBattery` `Amperage` + percent every 30 s from ~75 % to 100 %
  and compare with `minutesToTarget` in `Sources/MacStatsCore/BatteryCharging.swift`.
