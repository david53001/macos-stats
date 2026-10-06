# Stability + guided tour: progress (2026-10-06, branch `feat/stability-tour`)

**Repo:** `/Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats` (native Swift macOS menu-bar system
monitor; build/test/SDK notes in `CLAUDE.md`). **Baseline commit before this work:** `1ed61cf`.
**The plan to follow:** `docs/superpowers/plans/2026-10-06-stability-tour-plan.md`. It defines the terms
(breakdown, scan, hold, freeze, pin, cutout, ring…), the decisions D1–D10 and the exact tasks. Read it first.

## The owner's request (dictated, paraphrased)
1. Things jump around. In the CPU breakdown, VS Code reads 2 %, then drops, then reads 2 % again. Rows re-sort
   under the pointer, so expanding VS Code fails ("the expansion goes away"). The same jumpiness is on the cards,
   rows and numbers everywhere.
2. How intuitive is the app? Is the text clear, is the layout clean and centred, and how does a first-time user
   know where things are?
3. A skippable guided tour plus an intro, like BetterScreenshot (TourKit) and JVoice (WelcomeWindow). The
   highlight must sit perfectly centred around the squircle cards.
4. Research the psychology of how people use apps, and implement the findings.
5. Review with `/reviewer` until the score is above 9/10. Verify the bugs are gone, make sure MacStats's own RAM
   and CPU use don't go up, and document everything. All of it in the background, with no windows in front of the
   owner.

## Hard rules (summary; the full list is in the plan, "Ground rules")
- Background only. Probe windows go at `desktopWindow + 1` with `orderBack`. Never activate the app, click, or
  open the real popover. Run every probe under a kill timeout.
- Run one build or test run at a time. Tests: `./Scripts/test.sh`. For a bare build:
  `export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk; swift build`.
- No install, push or release. End commits with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- No new work while the popover is closed, no extra per-process scans, and the tour costs nothing when it isn't
  shown.

## Done
- **UX research + audit**, commit `936ee2c`. `docs/research/2026-10-06-ux-psychology.md` holds the research
  with sources, an audit of every string, clickable element and alignment at `1ed61cf`, and a ranked change list
  with exact strings. Screenshots and the off-screen probe source are in `docs/research/2026-10-06-ux-audit/`.
- **Tour research + design**, commit `5048151`. `docs/research/2026-10-06-tour-design.md` covers how
  BetterScreenshot and JVoice do it, then the MacStats design: an in-panel overlay, the geometry, the copy, the
  persistence keys, the tests and the `MenuBarExtra` pitfalls.
- **Jumpiness diagnosis**, commit `7942c9f`. `docs/research/2026-10-06-stability-diagnosis.md` lists every
  jitter source with code locations and live headless measurements, and gives the fix design.
- **Implementation plan + this note**, written 2026-10-06: `docs/superpowers/plans/2026-10-06-stability-tour-plan.md`.

## Checklist

### Part A: Stability (agent 1). Plan section "PART A"
- [x] A1: pure helpers (`DisplayHold.swift`, `StableRanking.swift`, `stickyUpperBound`, `BreakdownFormat.swift`) + tests — commit `bae65e6`
- [x] A2: 4 s trailing window in `BreakdownScanner`; `breakdownScanInterval` = 2 s; tests — commit `4adc84b`
- [x] A3: `MetricsStore` stable order, freeze, pin and held row values; tests — commit `83e52e4`
- [x] A4: held card values; `rateWindowSeconds` = 2 s; tests — commit `fed3fdd` (note: `cpuTemperature()` no longer rounds, so the store's 1 °C hold has something to hold; the card still shows whole degrees)
- [x] A5: views (`BreakdownView` freeze/pin/held text/energy scale/reorder animation; cards read held values) — commit `e95b290`. Off-screen render check (overview dark, CPU/memory/energy breakdowns, expanded CPU row, light + dark) looked right; that throwaway render probe lived in the scratchpad (not committed).
- [x] A6: headless stability probe `docs/research/2026-10-06-probes/stability/` + results; `CLAUDE.md` Status bullet — commit `d9c5623` (+ docs commit)

### Part B: Intuitiveness + tour (agent 2, only after Part A). Plan section "PART B"
- [x] B1: `Tour.swift`, `TourLayout.swift` + `TourStateTests`, `TourRulesTests`, `TourLayoutTests`, `TourCatalogLintTests` — commit `439f918` (27 tests). Notes: the welcome's 1st close returns `.none` (phase off, interruptions 1; it shows again on the next open); `deferPermissionPrompts` also takes `answered` (a paused tour or an answer this run), so a relaunch mid-tour still reads the Trash; `shouldOfferTour` takes `version` (default `TourCatalog.version`) so the bump re-offer is testable; Title Case lint allows minor words ("Take the Tour"). Layout fixtures are placeholders until B5 measures them.
- [x] B2: copy, affordance and layout fixes; Trash permission state — commits `1a3d174`, `4030cf5`
- [x] B3: `TourController`, audience classified before `AppModel()`, permission prompts after the intro, reopen opens the panel — commit `a8be945` (one commit with B4: they don't build apart)
- [x] B4: anchors, `TourOverlay` (dim + centred squircle cutout + accent ring + callout), welcome card, chip, `?` button, Settings Help — commit `a8be945`
- [x] B5: render probe `docs/research/2026-10-06-probes/tour-render/` with captures + `out/insets.txt` (equal insets ≤ 1 px) — commit `a1cd36e`; every step light + dark: inner 2/2/2/2 px, outer 6/6/6/6 px
- [x] B6: cost check (static + runtime) + `CLAUDE.md` Status bullet — see "Part B results" below

### After both parts (orchestrator)
- [ ] `/reviewer` until the score is > 9/10, fixes and re-review; final verification; docs

## Commands
```bash
cd /Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats
./Scripts/test.sh                                   # all tests (255 at 1ed61cf)
./Scripts/test.sh --filter StableRankingTests       # one suite
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk; swift build
./docs/research/2026-10-06-probes/stability/run.sh 90 Code      # after A6: headless stability numbers
./docs/research/2026-10-06-probes/tour-render/run.sh            # after B5: captures + insets.txt
pgrep -fl probe                                     # kill anything you started before finishing
```

## Decisions the owner may want to change (defaults chosen; details in the plan, "Decisions")
- D1: while an app is expanded, only that app is **pinned** (the rest still re-ranks, slowly). The alternative
  freezes the whole list.
- D2: breakdown scans every **2 s** with a 4 s average. The alternative is 1 s scans with a 5-scan average.
- D4: MacStats **opens its own panel** on a new user's first launch and when relaunched. The welcome is a card
  inside the panel, not a separate window.
- D5: **5 tour steps** (CPU, Memory, Network, Battery, footer); no Trash step.
- D6: ring in the **system accent** colour. D7: the existing-user chip shows on up to **3** opens.
- D8: CPU rows show **one number**; "% of one core" moves to the tooltip and the right-click menu.
- D10: for new users, the notification and Finder prompts come **after** the welcome card explains them.

## Owner manual checks (after the owner OKs `./Scripts/bundle.sh`)
The full steps are in the plan, "Owner manual checks":
- Esc on a tour step skips the tour without closing the panel.
- Esc goes back from a breakdown or Settings.
- Return/→ = Next, ← = Back.
- Relaunching from Spotlight opens the panel.
- The new-user flow (back up the defaults first).
- Closed-popover CPU and footprint vs v1.1.0.

## Part A results (probe, per minute; before = `1ed61cf`, 2 runs; after = `e95b290`, 4 runs, 90 s each)
| Metric | Before | After | Limit |
|---|---|---|---|
| top-8 order changes | 60.0, 59.1 | 10.9, 10.0, 14.5, 10.0 | ≤ 15 |
| slot changes | 311.6, 275.8 | 22.7, 30.9, 41.8, 30.0 | ≤ 40 |
| row text changes | 360.9, 391.4 | 66.4, 68.2, 121.8, 80.0 | ≤ 130 |
| expanded app's top-5 set changes | 26.0, 26.0 | 0, 1.8, 1.8, 0 | ≤ 2 |
| slot changes while pointing (20 s) | 98, 94 | 0, 0, 0, 0 | 0 |
| CPU / network ↓ / memory card | 87–91 / 45–49 / 19–25 | 39–65 / 11–23 / 5–20 | ≤ 75 / 30 / 16 |
| scan ms per second (whole scan) | 14.5, 14.9 | 6.4–7.7 | ≤ before |
| probe process CPU (% of one core) | 1.09–1.11 | 0.56–0.69 | ≤ before |
| max \|rows + System − header\| (pp) | 0 | 0.8–1.1 | ≤ 2 |

Run 3 (busiest Mac, 16.8 % mean, `top` running inside it) went just over two limits (slot changes 41.8, memory card
20.0); the other three runs meet every limit. Details, the scan-cost split and the `top` spot-check: the probe's
`README.md`. Static check: `git diff 1ed61cf -- Sources | grep -nE "Timer|asyncAfter|addObserver|DispatchSource|onReceive"`
shows only the two `NSMenu` tracking `onReceive`s in `BreakdownView` (alive only while a breakdown is shown). No
closed-popover path changed apart from `rateWindowSeconds` (no effect at the 10 s idle spacing).

Small deviations from the plan's letter (all in the commits):
- `cpuTemperature()` no longer rounds (the 1 °C hold needs the unrounded average; the card still shows whole degrees).
- `heldTimeLeft` returns the raw minutes when a value passes (`formatTimeLeft` rounds as before), so the wording
  at each length is unchanged ("6h" vs "about 6h").
- `stickyUpperBound` grows when the peak overflows the scale (not when it is within the 1.25 headroom), so it has a
  real hysteresis band.
- Held values are kept for every app's processes (not only the visible ones): simpler, and ~500 doubles while a
  breakdown is open.
- The scan-cost limit "≤ ~3 ms/s" excluded the running-apps list; with it, the whole scan is 6.4–7.7 ms/s against
  14.5–14.9 before (same probe), and the comparable part is 2.1–2.6 against 4.2.

## Part B results
Tests 338/338 green (`./Scripts/test.sh`), `swift build` green.

**Centring** (`docs/research/2026-10-06-probes/tour-render/out/insets.txt`): on all 5 steps plus the no-battery
footer, light and dark, the clear gap between card and ring is 2 px on every side and the ring's outer edge (the
cutout edge) is 6 px = 3 pt on every side (2× capture). Cutouts: CPU (5,33,310,73), Memory (5,106,310,73),
Network (5,179,310,73), Battery (5,252,310,73), footer (231,369,84,30), radius 11. Callout 304 × 108 at y 112 / 185 /
258 (below) and 138 / 255 (above). These rects are the `TourLayoutTests` fixtures.

**Cost.** Static: `git diff 0a4dc66 -- Sources | grep -nE "Timer|asyncAfter|addObserver|DispatchSource|onReceive|NotificationCenter"`
shows only the one-shot `asyncAfter(2.5 s)` in `MacStatsApp.init` (only while a new user's welcome is pending) and
the event-driven `applicationShouldHandleReopen`. `TourOverlay` exists only `if tour.isActive && overview showing`;
`.tourAnchor` attaches `anchorPreference` only while `tourActive`; `OverviewView` takes `offersTour` + closures and
never observes `TourController` (only `RootView` does); `panelOpened()` reads at most 5 keys (existing user: audience,
seen, resume, offerShows, offerDismissed; 3 once the tour is seen) and writes only when the chip shows (≤ 3 times) or
the state changes. Runtime (probe `--cost` / `--no-tour`, % of one core, 20 s each): tour off 14.1 / 15.0, without
`.tourHost` 15.2 / 15.1 (same within noise), tour on step 1 16.3 / 15.2 (only while shown).

**Deviations from the plan's letter** (all in commits `1a3d174`…`a1cd36e`):
- Breakdown footnote trailing padding is `Design.cardPadding` (12), not `cardPadding − panelInset` (4): with 4 it
  ended at 308 pt while the header's trailing text ends at 300 pt; 12 lines them up (the plan's stated intent).
  Footnotes still fit one line: scale 1.00 / 0.88 / 0.91 / 1.00 (CPU, Memory, Battery, hint), ≥ 0.8 required.
- Next / Done / Show Me Around use `SubtleButtonStyle(prominent: true)` (accent fill, 24 pt, continuous 6 pt
  corners) instead of `.borderedProminent`: the system button is 16 pt (small), 20 pt (regular) or 27 pt (large),
  never the 24 pt of the Back / No Thanks button beside it, so the pair didn't line up.
- The chip is 20 pt tall (`SubtleButtonStyle(height: 20)`, caption text) and sits on the title's baseline as an
  overlay, so the title never moves.
- The notification and Finder prompts fire when the intro **ends** (No Thanks, or the tour's Done / Skip / 2nd
  close), not at Show Me Around: the Finder prompt is a window of its own and would close the panel mid-tour.
- The callout is masked by the dim's even-odd shape, so its shadow never darkens the hole (the probe caught it:
  light-mode T = 0 px on Battery and footer before the fix).
- The callout body always reserves 2 lines, so every step's callout is the same height (108 pt) and never jumps.
- The welcome's first close returns `.none` (not `.paused`), with `interruptions` = 1; `deferPermissionPrompts` and
  `shouldShowWelcome` take `answered`; `shouldOfferTour` takes `version` (default `TourCatalog.version`).
- `?` and the gear share a fixed 16 pt icon width (`Design.footerIconWidth`), so the pair reads as one group.

**Owner manual checks** (agents can't do these without driving the real menu bar; build with
`./Scripts/bundle.sh`, which the owner runs or OKs) — in addition to the list above:
- The dim blocks hover and clicks on the cards under it (no highlight under the dim).
- Trash "Allow…" opens System Settings → Privacy & Security → Automation (only shows after a refused prompt).
- The first open after installing this build shows the "Take the Tour" chip (the owner is classified `existing`).

## Review round 1 (in progress, 2026-10-06)
Scores: reviewer A 7.3 (lowest: Resource cost 5.5), reviewer B 7.3 (lowest: Stability 6.4). Bar: both > 9.0 and
no area < 8.5. Reports: `docs/reviews/2026-10-06-stability-tour-review-r1-A.md`, `…-r1-B.md`.
Fix commits so far: `478bde3` (panel open/closed follows its window), `70c97d7` (ranking), `07acc95` (frozen
placeholders, sticky Exited row, pointer probe, a11y rows, contrast), `a748f58` (tour click-through, hint),
`9b2b08a` (copy), `a732ac0` (first-run open). Next: re-run the render probe and the stability probes, then
write this section in full (what was fixed, what was rejected and why).

## Next
Finish "Review round 1" above, then review round 2.
