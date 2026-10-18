# Handoff: merging `fix/battery-health` after the Sparkle work (2026-10-18)

Paste this into the session working on `feat/sparkle-updates` once its workflow is done.

---

Another session finished an accuracy fix for MacStats (the native Swift macOS menu-bar monitor in
`/Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats`). When your Sparkle work is
done, reviewed and committed, merge it in as described below, then push. Don't change the fix's
behaviour while merging.

**Where the fix is:** local branch `fix/battery-health` (not pushed), worktree
`/Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats/.claude/worktrees/battery-health`.
It branches off `feat/stability-tour` (HEAD `9a29b2c`), **not** off `main`. Its own commits:

| Commit | What |
|---|---|
| `986064e` | Battery Health = macOS's "Maximum Capacity" (System Settings said 99 %, MacStats said 97 %). New `parseMaximumCapacityPercent` + `readMaximumCapacityPercent` in `Sources/MacStatsCore/BatteryTelemetry.swift` (runs `system_profiler SPPowerDataType -json`, ~0.15 s); `BatteryTelemetry.reportedHealthPercent` overrides the old `NominalChargeCapacity / DesignCapacity` math; `AppModel.readMacOSHealthIfDue()` in `Sources/MacStatsApp/MacStatsApp.swift` reads it off the main thread at launch and hourly. 2 tests in `Tests/MacStatsCoreTests/BatteryParseTests.swift`. |
| `ee64f39` | Trash size in Finder's 1000-based units (`ByteCountFormatter` `.file`, `Sources/MacStatsApp/OverviewView.swift` `trashValue`), and Finder `missing value` folder sizes retried ~2 s instead of counting as 0 (`Sources/MacStatsApp/TrashActions.swift` `trashSize()`). |
| `cd3d417` | Battery: at the user's charge limit the status reads "Charged to 85% limit" / card "at 85% limit" (macOS itself only reports "not charging"; `BatterySample.heldAtLimitPercent` in `Sources/MacStatsCore/BatteryParse.swift`); the time rows' tooltips show macOS's own estimate (`macOSTimeToEmptyMinutes` / `macOSTimeToFullMinutes`, `Sources/MacStatsApp/BatteryDetailsCard.swift`). |
| `220fb79` | Per-app breakdown: CPU/energy of processes that exited between scans is exact, from the kernel's per-app "coalition" counters (`readCoalitionID` / `readCoalitionUsage` in `Sources/MacStatsCore/ProcessReader.swift`, `CoalitionTracker` in the new `Sources/MacStatsCore/CoalitionWork.swift`, wired into `BreakdownScanner.scan` in `ProcessScan.swift`), with guards that fall back to the old estimate. **Depends on `feat/stability-tour`'s breakdown code**: it can't be cherry-picked onto the Sparkle branch alone. Design note: `docs/design/breakdown-stability.md` rule 4a. |
| `1c3e71f`, `526b6de` and later docs commits | Docs: `CLAUDE.md` status line, `docs/superpowers/plans/2026-10-18-apple-values-progress.md` (audit of every reading vs Apple's own values), this handoff. |

**The catch:** `feat/sparkle-updates` branches from `ca35be1` (main era) and lacks the 139
unreleased `feat/stability-tour` commits. `git merge fix/battery-health` would bring all of
stability-tour in too; a trial merge conflicts in `CLAUDE.md`, `Resources/Info.plist`,
`MacStatsApp.swift`, `MacStatsMain.swift`, `RootView.swift`. Even cherry-picking only the fix
conflicts (the surrounding code differs), but those conflicts are small and local.

**Pick the route with the owner (ask in one short question if unsure):**

- **Route A, ship only the fix with Sparkle (recommended if stability-tour isn't being released yet):**
  on `feat/sparkle-updates`, run `git cherry-pick 986064e ee64f39 cd3d417`. The coalition
  commit `220fb79` is left out (it needs stability-tour's breakdown code) and ships with Route B
  later. Resolve by hand, keeping
  Sparkle's code and adding just the fix's lines:
  - `BatteryTelemetry.swift`: add the `reportedHealthPercent` property, the `if let reported`
    line at the top of `healthPercent`, and the two new functions.
  - `MacStatsApp.swift`: add the `macOSHealthPercent` / `lastHealthRead` / `healthReadInterval`
    properties, `readMacOSHealthIfDue()`, and in the battery refresh, just before the telemetry
    is published:
    `if telemetry != nil { readMacOSHealthIfDue() }; telemetry?.reportedHealthPercent = macOSHealthPercent`.
    If that branch has no `nominalPeak`, put it next to wherever `setBatteryTelemetry` is called.
  - `OverviewView.swift` / `TrashActions.swift`: apply the same two edits to that branch's
    versions.
  - Tests: keep the two new tests (`reportedHealthWinsOverTheGauge`,
    `parsesSystemProfilerMaximumCapacity`). Drop expectations that don't exist on that branch.
  - Skip the docs commits. Instead add one line to that branch's `CLAUDE.md` Status.
- **Route B, everything ships together:** merge `feat/stability-tour` into the release branch
  first (the owner's call: its review loop was paused at 8.4/10, see `CLAUDE.md`), then
  `git merge fix/battery-health` (it then only adds the commits above).

**Verify before pushing:** `./Scripts/test.sh` must be green (388 tests on `fix/battery-health`) (it pins the 26.5 SDK via
`Scripts/sdk-env.sh`; don't use bare `swift test`). Check live that the health matches macOS:
`system_profiler SPPowerDataType | grep "Maximum Capacity"` should equal the app's Battery →
Health row.

**Push:** the repo `david53001/macos-stats` is public. Use a normal push only: no force-push and
no history rewrite. A release still follows CLAUDE.md "Publishing an update" (bump
`CFBundleShortVersionString`, package, `gh release create`), plus whatever Sparkle's appcast
step needs.

**Don't:** reinstall over `~/Applications/MacStats.app` while the owner is testing the
battery-health build that is installed there now (from `fix/battery-health`), unless they say so.
Don't delete the `battery-health` worktree or branch; the owner decides that after the merge.
