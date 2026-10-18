# Live probe: the "Open MacStats at login?" card

Written 2026-10-18 (review round 3 of `docs/sparkle-updates/README.md`). It drives the **real**
`MenuBarExtra` panel of a throwaway MacStats copy and logs what the card does, so the app-side
glue (open/close detection, which screen the panel opens on, keyboard) is checked, not only the
pure rules in MacStatsCore.

## What it does

`probe.sh <src-worktree> <out-dir> <scenarios.swift> [seed-script]`:

1. copies the worktree (no `.git`, `docs`, `.build`, `dist`) to `<out-dir>/work`;
2. adds `Probe.swift` (the harness) and the scenarios file, both compiled only with `-DPROBE`;
3. gives the copy bundle id `com.macstats.MacStats.probe`, a dead update feed and no update
   checks, so it never touches the real app's defaults or the real feed;
4. stubs Finder (no Automation prompt) and **the login-item service**: `LaunchAtLogin` never
   calls `SMAppService` (the script refuses to build if a real call is left), so pressing Return
   on the card can't register a login item on the Mac; `Probe.loginResult` says what the stub
   reports (`.enabled`, `.requiresApproval`, `.notFound` = the error card);
5. builds it (`Scripts/bundle.sh release` into the work folder; about a minute), seeds
   `launchAtLoginPromptUses = 4`, runs the scenario in light then dark appearance, prints both
   logs, and deletes the copy, its defaults, caches and Launch Services entry.

The harness clicks the app's own `NSStatusBarButton` (`performClick`) to open and close the
panel, and synthesizes clicks and keys into the panel window. Snapshots are `cacheDisplay`
renders (no Screen Recording permission needed), so materials are flat, not real Liquid Glass.

If the **screen is locked** (a run while the owner is away), macOS posts no occlusion change for
the panel, so the app would never hear of the open/close; the harness then posts the window's
`didChangeOcclusionStateNotification` itself after each toggle (it notes this in the log). The
app's own observer code still runs; that macOS posts the notification on an unlocked screen was
checked by the earlier unlocked runs (review rounds 1-3). With the screen locked the panel is
never key, and a click on the dim doesn't register (round 2 verified it unlocked; the dim's code
is unchanged).

## Run it

```bash
R=/Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats/.claude/worktrees/sparkle-updates   # or any worktree
P=$R/docs/research/2026-10-18-probes/login-prompt
bash $P/probe.sh $R /tmp/macstats-probe $P/ProbeScenarios-screens.swift
```

On the integration branch (`integrate/stability-tour-sparkle`, which has the guided tour) use
`ProbeScenarios-tour.swift` (only in that branch's copy of this folder): the guided-tour part
(chip, tour started, tour resumed + skipped: no card, tour opens not uses), then the same M1 and
Return parts, plus **M1 guard**: with the card up, Settings is forced under it from code and Esc
must still answer the card (the Settings/breakdown back buttons drop their Esc while the card is
up). The new-user run: `PROBE_SCENARIO=welcome bash $P/probe.sh $R /tmp/macstats-probe-welcome
$P/ProbeScenarios-tour.swift $P/seed-welcome.sh` (welcome card first, the card only after it).

## Log columns

`uses` / `asked` / `quick` = the three defaults keys (`launchAtLoginPromptUses`, `…Asked`,
`…QuickDismissals`); `showing` = the card is up (open) or due (closed); `visible` / `key` = the panel
window; `frame` = its size (must always be 320x404); `breakdown`, `screen` = what the panel shows;
`answer` = the card was answered; `login` = the stubbed status (0 off, 1 on, 2 needs approval,
3 not found); `tour` / `chip` on the integration branch.

## Scenarios (`ProbeScenarios-screens.swift` after `Probe.run`'s basic part)

- **basic**: the 5th real use makes the card due; a click on the dim and two 0.3 s glances are
  quick dismissals (the 3rd counts as asked); a click on CPU with no card opens the breakdown;
  a settled card + Esc = No Thanks; a 1.6 s look counts as asked.
- **M1 (round-3 review)**: open, go to Settings (footer gear), make the card due, close there;
  the reopen must be on the overview with the card, and Esc must answer it. Same from the CPU
  breakdown.
- **Return**: Return on the question with the stub reporting enabled (confirmation, gone by itself
  after 1.6 s), needs approval (One more step; Return again = Open Login Items, stubbed), and an
  error (Couldn't turn it on; Return = Done).

## Results 2026-10-18, `feat/sparkle-updates` (screen locked, light and dark identical)

`results-sparkle/probe-light.log`, `probe-dark.log`; `light-S2-reopened.png` (reopen after a
close from Settings: overview, card over Memory + Network); `return-results.png` (Settings before
the close, then the three Return results, light, and the approval card dark).

```
S1-navigated | … showing=n … screen=settings          <- on Settings, card not due yet
closedS1     | … asked=n showing=Y … screen=overview  <- the close reset the screen
openS2       | … showing=Y … screen=overview          <- reopen: overview, card up
S2-after-esc | … asked=Y showing=n … screen=overview  <- Esc = No Thanks
openB2       | … showing=Y … breakdown=nil screen=overview   (same from the CPU breakdown)
B2-after-esc | … asked=Y showing=n
R1-after-return | asked=Y showing=Y answer=accepted login=1   -> R1-later showing=n (auto)
R2-after-return | asked=Y showing=Y login=2 -> Return: "stub: openSystemSettingsLoginItems", showing=n
R3-after-return | asked=Y showing=Y login=3 -> Return (Done): showing=n
```

Frame 320x404 on every line. Not checked here: the dim click (screen locked, see above).

## Results 2026-10-18, `integrate/stability-tour-sparkle` (screen locked, light and dark identical)

`results-integration/probe-{light,dark}.log`, `welcome-{light,dark}.log`;
`light-G1-settings-under-card.png`, `light-T7-settings.png` (GENERAL ends with "Guided tour"),
`dark-S2-reopened.png`.

```
openT1-chip  | uses=3 showing=n chip=Y   -> closedT1-chip uses=4      (chip: no card, a use)
openT2-tour  | tour=Y                    -> closedT2 uses=4           (tour: not a use)
T3-after-skip| showing=n                 -> closedT3 uses=4           (resumed + skipped: no card)
closedT4     | uses=5 showing=Y                                       (5th real use: due)
openS2       | showing=Y screen=overview -> S2-after-esc asked=Y showing=n   (M1, Settings)
openB2       | showing=Y screen=overview -> B2-after-esc asked=Y showing=n   (M1, breakdown)
G1-settings-under-card | showing=Y screen=settings
G1-after-esc | asked=Y showing=n screen=settings                      (Esc answered the card; Settings stayed)
R1/R2/R3     | as on feat/sparkle-updates
welcome: openW1/openW2 tour=Y showing=n (blocked); openW3 showing=Y; closedW3 asked=Y
```
