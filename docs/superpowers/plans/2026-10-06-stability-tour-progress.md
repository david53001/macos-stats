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

## Review round 1 (2026-10-06) — fixed, verified, committed
**Scores:** reviewer A **7.3** (Stability 8.0, Interaction 7.5, Intuitiveness 7.5, Copy 7.5, Visual 8.0, Tour 8.5,
Code 8.0, **Resource cost 5.5**); reviewer B **7.3** (**Stability 6.4**, Interaction 7.2, Intuitiveness 7.6, Copy 7.6,
Visual 8.6, Tour 8.8, Code 7.4, Resource 7.4). Bar: both > 9.0 and no area < 8.5. Reports:
`docs/reviews/2026-10-06-stability-tour-review-r1-A.md`, `docs/reviews/2026-10-06-stability-tour-review-r1-B.md`.

### Fixed (commit → finding)
| Commit | Finding (severity) | Fix | Evidence |
|---|---|---|---|
| `478bde3` | A X1/C1, B K1 (High): panel "open" mode (0.5 s ticks + slides, ~28 % of a core) while the panel is off screen | `AppModel.setPanelAppeared` + `panelWindowChanged`: open = SwiftUI appeared **and** window `isVisible && occlusionState.contains(.visible)`; `RootView.PanelWindowObserver` (occlusion + key notifications); each 0.5 s tick re-checks the window | Probe `docs/research/2026-10-06-probes/visibility/`: `onDisappear` never fires on `orderOut`/`close`; the occlusion notification fires within ~20 ms of every show/hide. Not verified in the real `MenuBarExtra` (no install allowed): owner check below |
| `70c97d7`, `0bd7598` | B S1/C2 (High) Battery list mis-sorted 84 %; B S2/C1 + A (Medium) a middle row blocks a clear leader | New climbing pass (a row passes the run of lower rows above it up to the highest it clearly beats); a lead must clear **both** margins (max, not sum); abs margins = 2 printed steps (CPU 0.2 pp, energy 0.02 W, was 0.3 / 0.05); a 1.5× lead of ≥ 1 pp / 0.05 W moves on one reading | Property test `steadyInputsConvergeToSorted` (300 random lists × 3 rules); reviewer B's probe: CPU mis-sorted scans 8/18 → 2/18 and 2/23, Battery 16/19 → 2/19 and 2/19 (`docs/research/2026-10-06-probes/r1-fixes/reviewB-probe-*.txt`) |
| `07acc95` | B S3 (Medium), A S2 (Low): child rows come and go, Exited row toggles, a row moved under a resting pointer | While frozen, ended apps/processes stay as dimmed "Ended" placeholders (`MetricsStore.isEnded`); the Exited row stays (at 0) once shown; Memory drops it | Tests `endedProcessesKeepTheirPlaceWhileFrozen`, `exitedRowStaysOnceItAppeared`, `memoryHasNoExitedRow`; B's probe: row under a resting pointer changed 0/0/0 (was 2 + 1); Exited toggles 0–1 (was 4–9); render `r1-fixes/out/breakdown-ended-child-*.png` |
| `07acc95` | B I2 (Low) menu close re-sorts under a still pointer; A I2 (Low) list appears under a still pointer | `MetricsStore.breakdownPointerProbe`: the view's `PointerProbe` NSView answers from `window.mouseLocationOutsideOfEventStream`, read once a scan | Test `pointerProbeFreezesWithoutAHoverEvent`; probe `r1-fixes`: inside = true under the real pointer, false away |
| `07acc95` | A I1, B I1 (Medium): rows mouse-only | App rows are plain-style `Button`s, Expanded/Collapsed value, Quit / Force Quit `accessibilityActions`; process rows have Quit; non-expandable rows drop the button trait | Build; synthetic click on the row Button expands it (r1-fixes probe) |
| `07acc95` | A V1/D1 (Medium) footnote + hint ~2:1 contrast | `.secondary` | `tour-render/out/breakdown-hint-cpu-light.png` vs the round-1 capture |
| `07acc95` | A S3 (Low) held row text up to 11 % off | Hold band capped: min(10 %, 2 pp) CPU, min(10 %, 0.2 W) energy | Test `relativeBandIsCapped`; B's probe shown-vs-exact max 0.28 pp |
| `ed4e0b2` | A S1, B S4 (Medium/Low) CPU card ~1 change/s | Band 0.75 → 1.25 (error ≤ 1.25 pp) | Same live series replayed (`r1-fixes/card-band.swift`): 56.9 → 41.4 changes/min, flip-backs 9 → 4; a 1 s minimum gap was rejected (lags real jumps by up to 8.7 pp) |
| `a748f58`, `3abb4b0` | A R1 (Medium) "Click the card" but the overlay swallows the click | The dim's hit shape excludes the cutout (`.onHover` must come **before** `contentShape(_, eoFill: true)` or it re-covers the hole); `RootView.endTourForClick` ends the tour, then drills in (or opens Settings for the gear) | Probe `r1-fixes`: cutout click reaches the CPU card, a dim click does nothing; the 4-variant table shows why |
| `a748f58` | A D1 (Medium) quit hint only on 3 drill-ins | Shows until a row's menu has been opened once (`TourKey.breakdownMenuUsed`), at most 10 drill-ins | `TourRulesTests.breakdownHint` |
| `a748f58`, `9b2b08a`, `1aea3c6` | Copy (Low): "pressure normal", "Internet speed", "see which apps.", straight ’, no °C label, raw pids, "Exited processes" | "OK / running low / very low" + tooltip; "Network activity"; "…which apps use it."; U+2019 everywhere; CPU card tooltip names the temperature; pid in tooltip/menu only; "Ended processes" | `TourCatalogLintTests`; render fit check (bodies 2 lines) |
| `a748f58` | B R3 (Low) light dim subtle | 0.25 → 0.30 | `tour-render/out/step1-light.png` |
| `a732ac0` | A R2 (Low) fixed 2.5 s first-run delay | `StatusItemHover.openPanelWhenFound()` clicks as soon as `attach` finds the button | Build (first-run flow is an owner check) |
| `1aea3c6` | B I3 (Low) an app down to one process stays "expanded"; A C4 (Low) duplicate tooltip helpers | Collapse when the expanded app has ≤ 1 process; one `View.tooltip(_:)` in `Design.swift` | Build + tests |

**Re-measured** (after all fixes): `./Scripts/test.sh` **346/346**; repo stability probe (`run.sh 90 Code`): top-8
order changes 7.3/min, target child-set changes 0, frozen slot changes 0, scan 7.45 ms/s, probe process 0.67 % of a
core; tour render probe: all 12 step measurements inner 2/2/2/2 px, outer 6/6/6/6 px, bodies 2 lines, footnotes fit.
Open-overview render cost (tour-render `--cost`): 12.7 % tour off / 13.5 % step 1 (unchanged; see rejected X2).

### Rejected or deferred (with the reason)
- **A X2 / B K2 (Medium/Low, pre-existing): the open overview's continuous sparkline slide costs ~10–13 % of a core
  in the probe.** Tried `.drawingGroup()` before the slide offset: 12.7 → 11.5 %, within run-to-run noise, so
  reverted. Sliding less often or not at all changes the owner-approved motion; left for the owner to decide.
- **A S4 / B I4 (Low): while frozen, a newly heavy app joins at the bottom.** By design: nothing may move under a
  resting pointer; it takes its place ≤ 1 s after the pointer leaves.
- **A S5 (Low): card (2 s window) vs breakdown header (4 s window).** Accepted; the header matches its rows, which
  must add up to it.
- **B C4 (Low): hold step chosen from the new value near 9.95 %.** Near that boundary the 10 % relative band
  (≈ 1 pp) dominates either step's 0.75 × step, so the hold applies evenly; no change.
- **A C3 / B C5 (Low): zero-size buttons for the tour's arrow/Esc shortcuts → `onKeyPress`.** `onKeyPress` needs
  keyboard focus inside the overlay, which a non-activating menu-bar panel doesn't reliably give; the buttons work
  regardless of focus.
- **A C2 / B C3 (Low): extract the breakdown display state from `MetricsStore`.** Worthwhile refactor, but not
  needed for any finding; deferred to keep this round's diff small.
- **B R2 (Low): 2 pt gap between card and ring.** A 4 pt cutout inset would exceed half the 6 pt card gap, so the
  ring would sit closer to the neighbouring card than to its own.
- **B T4 (Low): step 1 title doesn't say "CPU".** The highlighted card's own label says CPU right above it; the
  4-word title limit leaves no better wording.
- **B D4, A V2, A V3, A D2, B R1, B R4, A R3 (Low):** "N apps using almost nothing" row, hiding the no-battery
  card, sparse Settings, a Network drill-in note, a "Try it" stop (the cutout click now does that), auto-open
  surprise, callout over the next card: design trade-offs, left as is.

### Owner checks this round adds (need `./Scripts/bundle.sh`, the owner's OK)
- Open the panel, then close it every way (icon, click elsewhere, Esc, switch Space, lock the screen, display sleep):
  `ps -o pcpu= -p $(pgrep -x MacStats)` should drop to ~0 within a second each time.
- With the tour on step 1, click the highlighted CPU card: the tour ends and the CPU breakdown opens.
- Right-click a busy row, wait 5 s without moving the pointer, close the menu: nothing re-sorts.
- VoiceOver on a breakdown row: "Expanded/Collapsed", actions Quit / Force Quit.

## Next
Review round 2 (`/reviewer`, two independent reviewers) on HEAD of `feat/stability-tour`, using the probes:
`docs/research/2026-10-06-probes/{stability,tour-render,r1-fixes,visibility}/`.
