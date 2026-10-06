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

## Review round 2 (2026-10-06) — fixed, verified, committed
**Scores:** reviewer A **7.9** (Stability **7.2**, Interaction 7.8, Intuitiveness 7.8, Copy 8.2, Visual 8.6, Tour 8.9,
Code 7.8, Resource 8.6); reviewer B **7.8** (Stability 7.3, Interaction 8.0, Intuitiveness 7.8, Copy 8.0, Visual 7.8,
Tour 8.6, Code 7.8, Resource 8.0). Bar: both > 9.0 and no area < 8.5. Reports:
`docs/reviews/2026-10-06-stability-tour-review-r2-A.md`, `docs/reviews/2026-10-06-stability-tour-review-r2-B.md`.

Terms: **mis-sorted pair** = a row printed > 25 % and > 2 printed steps above the row directly above it (both
reviewers' measure). **Still pointer** = the pointer rests on the list from the moment it opens (the clicked card
sits where the list appears) and never moves.

### Fixed (commits `5a83125` core + breakdown UI, `7b4d51c` tour, `68a87df` probes)
| Finding (severity) | Verified? | Fix | Evidence |
|---|---|---|---|
| A S1/I2 (Medium): the order froze at the noisy 0.5 s first scan under a still pointer | Yes: still-pointer probe 44/75 scans mis-sorted at `66141b1` | `BreakdownPointer(inside, moved)`: the view's `PointerProbe` records the pointer when the list appears; an unmoved pointer doesn't freeze. The first scan after "Measuring…" is provisional: the first unfrozen scan after it sorts and holds afresh | Tests `aPointerStillRestingFromTheClickDoesNotFreeze`, `theShortFirstWindowIsResortedAtTheNextScan`, `…StaysFrozenUnderAPointerThatMoved`; probe still pointer 44/75 → 4/75 → **0/75** |
| A C1, B C1 (Medium): ~15 parallel breakdown fields, 100-line `setBreakdown` | Yes | `Sources/MacStatsCore/BreakdownDisplay.swift`: one value type (per-app row struct with its processes, freeze state, `apply`, `isFrozen`); `MetricsStore` replaces it to reset; `setBreakdown` is ~15 lines | All store tests unchanged in intent and green |
| A S3, B S1 (Medium): the pinned expanded app kept its index forever (most mis-sorts) | Yes: 30 of 31 CPU mis-sorted scans were next to it | Pin removed (`setBreakdownPinnedApp`, `stableRanking(pinned:)`): the freeze already holds the list while pointing; otherwise the expanded app re-ranks with the `.snappy` slide | Probe CPU 31/65 → 0/65 |
| B S2 (Medium): 25 % hysteresis left visible mis-sorts | Yes, plus a cause the reviewers didn't name: ranking used exact values while the text shows held ones (e.g. "0.03 W above 0.05 W" for 3 scans) | Rows **rank by their printed (held) values** with one reading (the hold already needs two scans); margins 15 % and **1.5 printed steps** (CPU 0.15 pp, energy 0.015 W), so a 2-step gap climbs and a 1-step one doesn't | Energy 16/65 → 0/65 mis-sorted scans; tests `noSwapWithinTheMargin`, `energyRowsSortAtTheirPrintedPrecision` |
| B S3 (Medium), A S2/S4 (Low): text changes/flips | Yes | Rows: `HeldReading`, a change shows after two scans in the same direction unless ≥ 2× the hold. Cards: `cardDwellSeconds` = 2 s dwell for CPU and network text unless the reading jumps (CPU ≥ 2 pp; network ×2 and ≥ 10 KB/s); network band 1.5 → 2 steps | Fixed-series replay (`r2-fixes/row-hold-replay.txt`): row changes −27…−56 %, flip-backs −7…−65 %. Live: CPU card 34.8 → 26.8–31.6/min, network ↓/↑ 20.8/21.6 → 6.8–16/8.4–15.6/min |
| B S4 (Low): memory hold unquantised | Yes | `heldMemory` measures from the *printed* figure | Test `memoryIsMeasuredFromThePrintedFigure` |
| A I1 (Low–Medium): quitting the expanded app while pointing collapsed it | Yes (`processes: []` placeholder) | An app that ended while frozen keeps its processes as "Ended" placeholders; collapses after the unfreeze | Test `anEndedAppKeepsItsProcessesWhileFrozen` |
| A U2, B U3 (Low): CPU bars on a 100 % scale | Yes | CPU bars use the sticky 1-2-5 scale above the top row, like energy (`breakdownBarScale`, was `breakdownEnergyScale`) | Test `cpuBarsFollowTheTopRow`; capture `tour-render/out/r2-breakdown-cpu-expanded-light.png` |
| A U4 (Low): "0.00 W" rows | Yes | "<0.01 W" below 0.005 W | Test `energyBelowTheLastDigitSaysSo` |
| B U2 (Medium): child names truncated alike | Yes | `processDisplayName`: "Google Chrome Helper (Renderer)" under Chrome reads "Helper (Renderer)"; the full name is in the tooltip and menu | Test `processNamesDropTheirAppsName`; `r2-breakdown-memory-expanded-dark.png` |
| B U1 (Medium): Battery details card ~45 % of the panel | Yes | Two label-value pairs per line; status moved to the header ("64% · On battery"); Health and Cycles split | `r2-breakdown-energy-expanded-light.png`: 3 detail lines, 6 list rows visible with an app expanded |
| A U1, A/B copy (Low): jargon | Yes | Memory parts "Apps / Kept by macOS / Compressed" (tooltips name Activity Monitor's terms); footnotes "Each app’s share of the whole Mac" (cores → tooltip), "Processor power only, not the screen" (GPU gone; detail in tooltip); memory tour body "How much memory is in use…"; CPU card tooltip reworded; Settings Help "What each card shows" + button, caption dropped | Lint + fit: footnote scales 1.00 / 0.88 / 0.99 |
| A I3 (Low): live process count in the tooltip | Yes | "Click to show its processes · Right-click to quit" | Build |
| B I1 (Low): non-expandable rows highlight on hover | Yes | Hover fill only on rows a click expands; process rows have none | Build |
| A T1 (Low): callout shadow darkens the strip above the highlight | Yes | The callout is masked to its own side of the edge facing the highlight | Render probe `strip near=0.702 far=0.702` (light), `0.602/0.602` (dark) on every step |
| A T2 (Low): Esc on the welcome = No Thanks | Yes | Shortcut removed (closing the panel asks again next time) | Build |
| B R1 (Low): clicking the highlighted card ended the tour | Yes | The tour stays on its step, hidden, and comes back with the overview | Build; owner check below |
| B I2/C4 (Low): tour pause/resume on `onAppear`/`onDisappear` | Yes | `AppModel.setVisibility` calls `tour.panelOpened()` / `panelClosed()` on its window-aware transitions | Build |
| A/B C2 (Low): review history in comments | Partly | Removed from `StableRanking`, `MetricsStore`, `TourOverlay` | — |

Accuracy trade-offs, all display-only (stored readings, graphs, bars and alerts stay exact): the CPU card can show a
value up to ~2 pp off for ≤ 2 s (was ≤ 1.25 pp at any time); a row's text can trail by up to twice its hold for one
2 s scan.

**Measured** (`docs/research/2026-10-06-probes/r2-fixes/README.md`, 150 s runs on live processes): mis-sorted scans
still pointer 44/75 → 0/75, CPU 31/65 → 0/65, energy 16/65 → 0/65, memory 0 → 0; rows moved while pointing 0; expanded
app auto-collapses 0; top-8 order changes ≈ 2 → ≈ 10 a minute (the list now follows the printed numbers); probe
process 1.01 → 0.93–1.00 % of a core. Tour render probe: centring unchanged (2 px gap, 6 px ring edge, every step,
light + dark), `failures=0`. `./Scripts/test.sh` **356/356**; `swift build` green.

### Rejected or deferred (with the reason)
- **A S1 alt. / B S6 (Low): let the freeze lapse after a few seconds without movement, or re-sort on a huge lead.**
  A pointer that *moved* onto the list and rests there is usually about to click; rows moving under it was the
  owner's original bug. The "unmoved since it appeared" rule covers the common case reviewer A measured.
- **B S5 (Low): derive the System row as header − the other shown rows.** It would tie System's text to every
  other row's hold (more changes on a row people read) and fake a number. The header stays the measured whole-Mac
  figure; the rows are each within their hold. Honest note: on a busy Mac (28 % mean CPU) the shown rows' sum was
  up to 3.9 pp from the header (1.2 pp at 11 %). If a reviewer flags it again, consider showing the header as the
  rounded sum of shown rows.
- **B P1 (Medium): install this branch and verify the closed-panel CPU live.** The hard rules forbid installing and
  driving the menu bar. Read-only check now: the installed copy (built 17:49, before `478bde3`) uses **33.7 % of a
  core, 80 MB, 64 min of CPU in 4 h** with its panel closed. Owner check below.
- **A C3 (Low): `PointerProbe` installs its closure in `updateNSView`.** Kept: `beginBreakdown`/`clearBreakdown`
  reset the closure, so it must be re-installed by the live view.
- **A U3 (Low): label for "45 °C".** The card's tooltip now says "The °C is the chip’s temperature."; no glyph
  added (the meta line is plain text in every card).
- **A C4 / B C5, B U4, A/B V1, B V2, A T3, A I2 (Low):** as in round 1 (`onKeyPress` needs focus the panel doesn't
  reliably give; no-battery card; sparse Settings; corner gap would crowd the neighbouring card; first-launch
  prompt timing is explained on the welcome card; a new app joins at the bottom only while you point at the list).
- **A resource (Low): the tour's 4–6 MB not returned 20 s after skipping, in the probe.** The app's
  `malloc_zone_pressure_relief` 1.5 s after close isn't in the probe; owner check below.
- `docs/research/2026-10-06-probes/r1-fixes/main.swift` targets the round-1 API (`breakdownPointerProbe` → `Bool`)
  and no longer builds; kept as the round-1 record (its README says so). The repo stability probe was updated.

### Owner checks this round adds (need `./Scripts/bundle.sh`, the owner's OK)
- **Closed-panel cost (most important):** install, open and close the panel a few times (also: click another app
  while it's open), then `ps -o pcpu,rss,cputime -p $(pgrep -x MacStats)`: expect < 0.5 % closed.
- Click the CPU card and leave the pointer still for 30 s while a busy app starts: the list keeps sorting. Then
  move the pointer onto the list: it stops moving.
- Expand an app, keep the pointer on the list, quit that app from its menu: its rows stay dimmed ("Ended") until
  the pointer leaves.
- Tour step 1, click the CPU card, go back: the tour is still on step 1.

## Review round 3 (2026-10-06) — fixed, verified, committed
**Scores:** reviewer A **7.9** (Stability **7.5**, Interaction 8.0, Intuitiveness 8.0, Copy 8.2, Visual 7.8, Tour 8.8,
Code 8.0, Resource 8.3); reviewer B **7.9** (Stability **7.4**, Interaction 7.6, Intuitiveness 8.0, Copy 8.2, Visual
8.5, Tour 8.8, Code 7.8, Resource 8.6). Bar: both > 9.0 and no area < 8.5. Reports:
`docs/reviews/2026-10-06-stability-tour-review-r3-A.md`, `docs/reviews/2026-10-06-stability-tour-review-r3-B.md`.

Terms: **inversion** = a row printed with a lower number directly above a row printed with a higher one (any
printed difference, reviewer B's measure). **Window** = the span a breakdown row's number is averaged over.
**Replay** = recorded live scan results fed offline through the real `MetricsStore`, so rules compare on
identical data (`docs/research/2026-10-06-probes/r3-fixes/replay/`).

### Fixed (commits `7ddbe85`, `2ab7c67`, `c34b3f3`, `2448ddd`, probes `79abf40`)
| Finding (severity) | Verified? | Fix | Evidence |
|---|---|---|---|
| A S1, B S1 (Medium): re-sort from scratch 2.5 s after opening | Yes (B's runs: top row changed at 2.5 s in 3/3) | "Measuring…" until the first full 2 s scan (`breakdownFirstRescanDelay` and the provisional/fresh state removed; text "Takes about two seconds") | Live still pointer: top row changed only at 48 s and 60 s (the busy `yes`), not at 2 s/2.5 s |
| B S3 (Medium): CPU list inversions in 20/45 scans; A S2 (Medium): reorders with the pointer away | Yes (replay: 83/149 inversion scans on the 4 s window) | Rows average **8 s** (CPU) and an **inversion timeout**: a row printed above the row over it on two published scans passes it (`BreakdownDisplay.rank`, `stableRanking(promoted:)`), for app and process rows | Replay 4 s → final: reorders 5.1 → 3.6/min, inversion scans 83 → 10 of 149, expanded app moves 4.7 → 2.8/min. Live: inversion scans 20/45 → 1/49, reorders 6–15 → 3.1/min. The timeout alone on 4 s doubled reorders (15/min), so the window carries it |
| B S2 (Medium): Battery top rows swap every 4 s at idle | Yes (CPU energy counters move in lumps) | Battery rows average **16 s** (`energyWindowSeconds`) | Replay: 8 s window 6.7 reorders/min, 36/149 inversion scans; 16 s 0 and 0. Live: 15 → 0.6/min, 1/49 |
| B I1 (Medium): frozen expanded app gains a process → row inserted, rows below shift | Yes (synthetic) | While frozen, processes new to a listed app (incl. a first "Finished processes" row) wait for the unfreeze | `run.sh synthetic`: before == after in both cases; test `aFrozenAppGainsNoRows` |
| A S2 (part), A I1 (Low): resting pointer + right-click | Yes | A context menu opened over an unmoved pointer counts as pointing (`BreakdownDisplay.engaged`) | Test `aMenuOpenedWithoutMovingCountsAsPointing` |
| A V1 (Medium): "102.5 / 128.0…" cut off | Yes | Memory card drops decimals from 100 GB of RAM | `tour-render/out/overview-128gb-{light,dark}.png`: "102 / 128 GB" |
| A V2, B V2 (Low): callout slices a card's text; 3 pt sliver of the neighbour card | Yes | `calloutGap` 6 → 3 (callout starts at the neighbour's edge); its far edge stretches ≤ 40 pt to the next anchored card edge (`TourLayout.callout(edges:)`), content centred | Render probe steps 1–5 light/dark: callouts 109–249, 182–322, 255–372, 109–249, 255–366 (whole cards); centring unchanged (2 px gap, 6 px ring edge), `failures=0`; test `calloutMeetsCardEdges` |
| B D1 (Low): header 23 % vs card 27 % | Yes | The header's hold starts from the card's value; the first rows cover 2 s like the card | Test `theHeaderStartsFromTheCardValue` |
| B I2 (Low): "Process" rows | Yes | Names read in the scan for new processes only (`ProcessUsage.name`, cached by pid + start time) | Real-scan render `tour-render/out/r2-breakdown-*-expanded-*.png`: no "Process" rows; scan p50 17.6 ms (B: ~17) |
| A S3, B S5 (Low): CPU card ~40 changes/min | Yes | Dwell bypass at 3 pp (was 2) | Replay of the recorded 0.5 s series: 21.9 → 18.5/min, max error 2.0 → 3.0 pp; live 16–21/min |
| A C1 (Low): `before:` always empty | Yes | Parameter and its two-reading tests removed | Tests |
| A T1, B T1/T2/T3, A T2/T4, B T4 (Low): copy | Yes | Memory step "The dot turns yellow or red when your Mac runs short. Click to see which apps use it."; CPU step "The number is right now, the graph shows the last minute. …"; welcome "…live in your menu bar, under this icon." / "You can skip it any time."; drill-in time left in the card's wording ("4h", "About 6h"); "Finished processes" | `TourCatalogLintTests` (2-line fit) |
| A D1, B D3 (Low): bare "47 °C" | Yes | Card meta "Chip 47 °C" | Render `overview-light.png` |
| B C4 (Low): `.help` vs `.tooltip` | Yes | Finished-processes row uses `.tooltip` | Build |

Display-only accuracy trade-offs: breakdown rows (and the CPU header) are 8 s / 16 s averages (was 4 s); the CPU
card can be up to 3 pp off for ≤ 2 s (was 2 pp). Stored readings, graphs and alerts stay exact. Cost: the longer
windows hold 4 / 8 intervals of ~500 entries while that breakdown is open (~100–200 KB, freed on close); scan time
unchanged; nothing new runs while the panel is closed or the tour is off.

**Measured:** `./Scripts/test.sh` **359/359**; `swift build` green; live probe `docs/research/2026-10-06-probes/r3-fixes/`
(`after-run2.txt`, `cost.txt`, README table); tour render probe `failures=0`.

### Rejected or deferred (with the reason)
- **A R1, B P1 (Low): install the branch and verify the closed-panel CPU live.** The hard rules forbid installing
  `~/Applications/MacStats.app` and driving the menu bar. Owner check (unchanged): after `./Scripts/bundle.sh`, open
  and close the panel, then `ps -o pcpu,rss,cputime -p $(pgrep -x MacStats)`: expect < 0.5 % closed.
- **A S2 alt. (Medium): hold the expanded app's row and process order while expanded.** Round 2 removed exactly
  that pin (30 of 31 mis-sorted scans sat next to it). The longer window cut expanded-app moves 4.7 → 2.8/min (0.6
  on a second recording) without hiding a real change.
- **A I1 alt.: freeze for 1 s after any reorder.** Scans are 2 s apart, so it would never apply; the menu
  engagement covers the right-click case.
- **A I2 (Low, unverified): stale hover highlight after a reorder under an unmoved pointer.** Needs the real panel
  to check; reorders under an unmoved pointer are now rare (top row: 2 changes in 95 s, both from a real load jump).
- **A D2, B I3/D2 (Low): Quit only by right-click; no hover on non-expandable rows.** Round 2's reviewer asked to
  remove that hover (a click there does nothing). The hint footnote and every row's tooltip name the right-click.
- **A V3, B V1 (Low): Settings half empty.** Milestone 4 (menu-bar display, alert thresholds) fills it; padding it now
  would be speculative UI.
- **A S4 (Low): rows vs header sum.** As round 2: the header is the measured whole-Mac figure.
- **A T3 (Low): several "Helper" rows.** Activity Monitor does the same; pid is in the tooltip and menu.
- **B R1 (Low): only 1 pt between card and ring.** As round 1: a wider inset crosses the middle of the 6 pt gap.
- **A C3 / B C3, A C4, B C5 (Low):** `CardDisplay` extraction, `onKeyPress`, research citations in comments: as in
  rounds 1–2.

## Review round 4 (2026-10-06/07) — fixed, verified, committed
**Scores:** reviewer A **8.3** (Stability 8.6, Interaction 8.0, Intuitiveness 7.8, Copy 8.0, Visual 8.4, Tour 8.7,
Code 8.3, Resource 8.0); reviewer B **8.1** (Stability 8.0, Interaction 8.2, **Intuitiveness 7.5**, Copy 8.2, Visual
8.4, Tour 8.8, Code 8.3, Resource 8.2). Bar: both > 9.0 and no area < 8.5. Reports:
`docs/reviews/2026-10-06-stability-tour-review-r4-A.md`, `docs/reviews/2026-10-06-stability-tour-review-r4-B.md`.

Terms: **macOS agent** = a running "app" that is part of macOS (not a regular Dock app, installed under
`/System/` or `/usr/` but not `/usr/local/`: loginwindow, Dock, WindowManager, universalaccessd…). **Reorder
dwell** = apart from a big jump, a list reorders at most once per `breakdownReorderDwell` (5 s). **Fast attack**
= the breakdown window restarts when an app used ¾ of a core more over the latest scan than over the rest of the
window. Probe folder for this round: `docs/research/2026-10-06-probes/r4-fixes/` (README defines the measures).

### Fixed (commits `a4ecd46`, `d586de9`, `7cd1b91`, `7643496`, `60f7a76`, `bdb38e9`, `21e6fc1`, probes `a888153`)
| Finding (severity) | Verified? | Fix | Evidence |
|---|---|---|---|
| A I1/U1/T1/V2, B D1 (Medium): macOS agents listed as apps with internal names, blank icons and Quit/Force Quit (Force Quit on loginwindow = logout) | Yes: 30 such agents on this Mac (`NSWorkspace` lists them as accessory/background apps) | `isMacOSAgent` (ProcessScan.swift): not an attribution anchor, so their processes go to "Other processes" (tooltip now "macOS helpers and background tasks…"). Finder/Mail/System Settings (regular) and third-party menu-bar apps stay apps. `canQuitProcess`: loginwindow's process row has no Quit / Force Quit ("Part of macOS: quitting it would log you out") | Tests `macOSAgentsAreNotApps`, `macOSAgentsAreTheSystemsNonRegularApps`, `loginwindowCantBeQuit`; real-scan captures `r4-fixes/out/breakdown-cpu-light.png`, `breakdown-energy-dark.png`: only real apps + Other + System |
| A S1 (Medium): expanded app's visible process rows changed on 41/53 scans | Yes, and the cause: short-lived processes (a build's, a terminal's) ranked in at their place and vanished a scan later | A process new to a listed app joins below its known ones for one scan, then climbs like any row (a big lead at once) | Replay under `load.sh`: top-5 child changes 24.9 → 10.9/min, first 14 rows' slot changes 69.3 → 28.6/min; test `aNewProcessJoinsBelowItsAppsKnownOnesForOneScan` |
| B S1 (Medium): close, bursty apps reorder 15–23/min with the pointer away | Yes: synthetic 23.7 / 14.2 reorders/min | Reorder dwell 5 s for apps and each app's processes (`BreakdownDisplay.rank`); a jump (> 1.5× and > 1 pp / 0.05 W) still moves at once and doesn't restart the dwell | Synthetic: 23.7 → 14.3 (CV 0.6), 14.2 → 9.4 (CV 0.3) reorders/min; trade-off: inversion scans 46 → 68 % / 33 → 55 %, longest 1 → 3 scans. Live: 2.5/min, 0/49 inversion scans. Test `theListReordersAtMostOncePerDwell` |
| A S2 (Low): rows take 8 s to reach a new load | Yes (3.1 / 6.2 / 9.4 / 12 %) | Fast attack per app (`BreakdownScanner`, `breakdownFastAttackCores` 0.75). A first version on the machine total never fired live: a one-core `yes` raised the header by only ~⅔ of a core | Replay: burst row 12 % at +2 s (was 3.1), header 28 % (was 16 %), Battery 3.9 W at +2 s (was 0.48 W); row text changes 17.0 vs 17.2/min, inversions 2/149 either way. Test `aNewLoadRestartsTheWindow` |
| A I2 (Low): while frozen, a new Memory app joined above the group rows | Yes (`StableRanking.swift:53`) | Frozen: new keys after every kept key | Tests `groupsStayLastForMemory`, property test `frozenKeepsTheShownRowsAsAPrefix` (all metrics, 50 random runs each) |
| A V1/R1, B V1 (Low): stretched callout with empty bands | Yes | `calloutStretch` and `TourLayout.callout(edges:)` removed: the callout has its content's height (108 pt) | `r4-fixes/out/step1-light.png`, `step4-dark.png`; render probe `failures=0`, centring unchanged (inner 2/2/2/2 px, outer 6/6/6/6 px every step, light + dark) |
| B V2 (Low): two callouts overlap during a step change | Yes | Each step's callout has its own identity: the old fades out (0.1 s), the new fades in (0.15 s after 0.12 s) while the hole glides | `r4-fixes/out/glide-step1to2-light.png` (0.06 / 0.12 / 0.2 / 0.3 / 0.5 s): never two callouts |
| A T2/R2, B T1 (Low): step 1 comma splice | Yes | "The number is now, and the graph is the last minute. Click to see which apps use it." | Lint + fit (2 lines) |
| B I1 (Low): ended expanded app can't collapse; its "N more…" adds dead rows | Yes | It can collapse (not expand); ended apps get no "more" row (`BreakdownList.rows(ended:)`) | Build |
| B I3/C4 (Low): occlusion treated as a panel close | Yes | Close = SwiftUI hid the content or the window is ordered out (`isVisible`): only then `tour.panelClosed()` + `exitBreakdown()`. Occlusion still stops every timer incl. breakdown scans; uncovered with a breakdown open, it scans afresh | Build; owner check below |
| A T3 (Low): "% of one core" on every CPU row tooltip | Yes | Right-click menu only (the footnote tooltip already says so) | Build |
| B T3/C3 (Low): "Exited" vs "Finished" | Yes | Code comments say "Finished processes" | — |

Accuracy: unchanged (stored readings, graphs, bars and alerts exact; grouping only moves macOS agents into Other
processes; fast attack makes rows/header *more* current). Cost (`r4-fixes/cost.txt`): CPU scan p50 17.1 ms (was
17.6); open overview 11.9–12.1 % tour off (was 12.0–12.2); nothing new runs while the panel is closed or the tour
is off (no new timers or observers). `./Scripts/test.sh` **366/366**; `swift build` green.

### Rejected or deferred (with the reason)
- **A P2, B R1 (Medium, verification): install the branch and confirm the closed-panel CPU is ~0.** The hard rules
  forbid installing `~/Applications/MacStats.app` and driving the menu bar; a second, uninstalled copy would put
  another icon and panel in front of the owner. Owner check (unchanged, most important).
- **B T2 (Low): keep the stripped child name only when unique.** Identical full names are the norm (VS Code runs
  ~10 "Code Helper"), so un-stripping can't make them unique; it would only bring back round 2's truncation
  ("Google Chrome He…(Renderer)") and mix "Code Helper" with "Helper (GPU)". Full name + pid are in the tooltip.
- **B S3 (Low): let a ≥ 3 pp card move bypass the dwell only once per 2 s.** It would let the card sit > 3 pp off
  for up to 2 s; both reviewers count "never ≥ 3 pp off" as a strength.
- **A S3, B S2 (Low): frozen order vs live numbers.** By design: nothing moves under the pointer.
- **B S4 (Low): first ~10 s settle.** The dwell now limits it to one reorder per 5 s; no extra rule.
- **B S5 (Low): held text vs exact value.** Within each hold's documented bound; unchanged.
- **B I2 (Low): pin the expanded app's position.** Round 2 removed that pin (30 of 31 mis-sorts sat next to it);
  the dwell limits its moves (0.4/min in the replay).
- **A U2, B D2 (Low): Quit only on right-click.** As rounds 2–3 (hint footnote + tooltips; Activity Monitor does
  the same).
- **A U3 (Low): flat Memory graph.** Steady memory is a flat line; rescaling would exaggerate noise.
- **A V3 (Low): "AccessibilityVisualsAg…" truncates.** Gone with the agent fix.
- **A R3 (Low): "under this icon".** The panel hangs directly under the menu-bar icon the welcome shows.
- **A P1 (Low): open-overview cost vs 1ed61cf.** Pre-existing (rounds 1–3); the probe can't build at 1ed61cf
  (no tour API). Unchanged this round.
- **A C2 / B C1, C2 (Low):** comment history trimmed where touched; `CardDisplay` extraction deferred as before.
- **A I3, B I4:** right-click menus, scrolling and hover need the real panel: owner checks.

### Owner checks this round adds (need `./Scripts/bundle.sh`, the owner's OK)
- Lock the screen with the panel open on a CPU breakdown, unlock: the breakdown is still there ("Measuring…" for
  about 2 s); the tour, if running, is still on its step.
- CPU breakdown: loginwindow, Dock, WindowManager are no longer rows; expand "Other processes" and right-click
  loginwindow: no Quit / Force Quit.

## Review round 5 (2026-10-07) — fixed, verified, committed
**Scores:** reviewer A **8.1** (Stability 8.0, Interaction 8.0, Intuitiveness 8.0, Copy 8.3, Visual 8.5, Tour 9.0,
**Code 7.5**, Resource 8.0); reviewer B **8.2** (Stability 7.8, Interaction 8.2, Intuitiveness 8.4, Copy 8.2, Visual
8.7, Tour 8.9, Code 7.8, Resource 8.7). Bar: both > 9.0 and no area < 8.5. Reports:
`docs/reviews/2026-10-06-stability-tour-review-r5-A.md`, `docs/reviews/2026-10-06-stability-tour-review-r5-B.md`.

Terms: **partial freeze** = with the pointer on a known app's rows, only the apps down to and including that app keep
their places; the apps below still re-sort (never past it). **Fast release** = the breakdown window also restarts
when an app used ≥ ¾ of a core *less* over the latest scan than over the rest of the window. **Promotion floor** =
process rows printed under 0.5 % (0.05 W) pass a neighbour only by the ranking margins, not by the inversion timeout.
All rules, constants and tests are now in one place: **`docs/design/breakdown-stability.md`**. Probe folder for this
round: `docs/research/2026-10-06-probes/r5-fixes/` (README defines the measures and has the exact commands).

### Fixed (commits `e277f5d`, `f4263a0`, `486d45e`, `70a1d77`, `a3abcc7`, probes `5b8306a`)
| Finding (severity) | Verified? | Fix | Evidence |
|---|---|---|---|
| A S1 (Medium): rows and header take ~8 s to come down after a load ends | Yes: "Falls still average" (`ProcessScan.swift`) | Fast release (`BreakdownScanner`, same `breakdownFastAttackCores`) | Replay: header 30 → **12** % 2 s after a one-core load stops (card 32 → 17 %); without it 30 → 25 → 23 %. Test `aLoadThatEndsRestartsTheWindow` |
| B S1 (Medium), A S3 (Low–Med): expanded app's visible process rows reshuffle every ~6 s; "Finished processes" jumps to the top | Yes | Process rows: own dwell `breakdownProcessReorderDwell` 10 s; `RankHysteresis.promotionFloor` (0.5 % / 0.05 W); "Finished processes" always the app's last row and hidden while it prints 0 (unless frozen) | Replay under a bursty load: visible top-5 order changes 10.1 → **5.1**/min, set changes 0.8/min, Finished in the top 2: 13 → **0** scans, first 14 rows' slot changes 33.0 → 17.2/min. Trade-off: child inversion scans 67 → 79/149 (CPU), 35 → 25 (Battery). Tests `processRowsReorderAtMostOncePerTheirDwell`, `tinyProcessRowsDontSwapByTheInversionTimeout`, `exitedRowIsAlwaysLast`, `exitedRowShowsOnlyWhileItHasSomethingToShow` |
| A S2 (Low–Med), B S2 (Low): a resting pointer freezes the whole order | Yes | Partial freeze (`BreakdownFreeze.through`, `BreakdownPointer.app` from the rows' hover events, `RowHover`); unknown row / menu / unfreeze delay still freeze all | Tests `aPointerOnAnAppFreezesOnlyDownToIt`, property test `frozenKeepsTheShownRowsAsAPrefix` (random partial freezes, 3 metrics); replay: 135 frozen scans, 0 rows at or above the pointer moved |
| A C1 (Medium), B C1/C3 (Medium/Low): stabiliser hard to maintain; `apply` 90 lines; inline hold literals | Yes | Design note `docs/design/breakdown-stability.md` (23 rules: constant + test each); `apply` split into `ListRanking` (order + lagging + dwell, no `inout` pairs) and `processRows`; `RowHold` names the hold bands next to `RankHysteresis`; history prose out of the constants' docs | Build + 373 tests |
| B I1 (Low): an ended expanded app's "N more…" vanished while frozen (rows below jumped ~25 pt) | Yes | Kept, disabled and dimmed, until the unfreeze (`BreakdownList`, moved to MacStatsCore and tested) | `r5-fixes/out/r5-breakdown-cpu-expanded-app-ended-light.png`: BetterScreenshot row stays at the same y; test `anEndedAppKeepsItsMoreRowDisabled` |
| B I2 (Low): ended process placeholders printed the full name | Yes | `processDisplayName` as for live rows | Same capture ("Helper (Renderer)") |
| A I1, B I3 (Low): scroll without pointer motion doesn't freeze | Yes | `PointerProbe` local monitor (only while a breakdown is shown): scroll or click in the list = moved; a scroll forgets the hovered row until the next hover (full freeze) | Build; needs the real panel to see live |
| A T2 (Low): Memory footnote at 0.88× | Yes (and Battery's at 0.91×) | "Per app, as in Activity Monitor", "Processor power, not the screen" | Render probe fit: all footnotes and the hint 1.00 (`r5-fixes/out/insets.txt`) |
| A D1 (Low): expanding isn't taught | Yes | Hint "Click to expand · Right-click to quit" (fits at 1.00) | `r5-fixes/out/r5-breakdown-cpu-hint-light.png` |
| A T1 (Low): "Finished processes 0.0 %" | Yes | Hidden while it prints 0 (see B S1 row) | Replay: 0 scans printing 0 |
| B T1, T2 (Low): step 1 and welcome copy | Yes | "The number is right now; the graph shows the last minute. Click to see which apps use it." / "…live in your menu bar. Click its icon any time." | Lint + fit (2 lines); `r5-fixes/out/step1-light.png`, `welcome-light.png` |
| B T3 (Low): "pid" on row tooltips | Yes | Tooltip = full name; pid only in the menu header | Build |
| B V1 (Low): offer chip 3 pt above the CPU card | Yes | Chip 18 pt (gap ≈ 4 pt) | `r5-fixes/out/chip-light.png` |
| A S5 (Low): Network ↑ jitter | Yes | The card's ↑ line holds 20 % (↓ stays 15 %) | Test `rateHoldsSmallWobble` |
| A C3, C4, C5; B C4, C5 (Low) | Yes | Probe closure set once in `makeNSView`; unreadable process names cached as nil; `BreakdownList` in Core; `noThanks` folded into `skip` (`engaged` documented as per-breakdown); old stability probe marked superseded by `r5-fixes` (agents, pointer probe, child order, flattened rows, inversions) | — |

Accuracy: unchanged (stored readings, graphs, bars and alerts exact; fast release makes rows/header *more* current;
the ↑ card hold is display-only, ≤ 20 % of the shown value). Cost: no new timers; nothing new runs while the panel is
closed; the scroll/click monitor and row hover handlers exist only while a breakdown is shown; scan work unchanged
(the release check reuses the attack's per-app sums). `./Scripts/test.sh` **373/373**; `swift build` green; render
probe `failures=0` (centring unchanged: inner 2/2/2/2 px, outer 6/6/6/6 px every step, light + dark).

### Rejected or deferred (with the reason)
- **A R1 / B side note (Medium, operational): install HEAD and check the closed-panel CPU live.** The hard rules for
  this work forbid installing `~/Applications/MacStats.app` and driving the real menu bar; running a second,
  uninstalled copy would put another icon (and, as a "new user", an auto-opening welcome panel) in front of the
  owner. The fix itself (window-aware open/closed) was verified off-screen in round 1 (`probes/visibility/`).
  **Owner check, most important:** `./Scripts/bundle.sh && open ~/Applications/MacStats.app`, open and close the
  panel, then `ps -o %cpu,time,rss -p $(pgrep -f MacStats.app/Contents/MacOS)`: expect < 0.5 % with the panel closed.
- **A C1 alt.: merge the dwell and the inversion timeout into one "lead for N s" rule.** Would change every measured
  trade-off at once; both are now one small tested function (`ListRanking.rank`). Recorded under "Considered and not
  done" in the design note.
- **A S2 alt.: let a row > 2× the one above pass while frozen.** It would move rows under the pointer; the partial
  freeze re-sorts only below it.
- **A I2 (Low): keep an app expanded when it drops to one process.** Its one process row would repeat the app row;
  it collapses only while the pointer is away (frozen lists keep it).
- **A D2 (Low): Memory's "Other processes" (largest) pinned last.** By design: the list answers "which app"; the
  group is an aggregate of macOS helpers (as in rounds 3–4).
- **A S4 (Low): CPU card 20–26 changes/min.** Both reviewers count "never ≥ 3 pp off, a load in ~2 s" as a strength;
  a 3 s dwell would trade that away.
- **A TR1, TR2; B D1, D2/V3, V2 (Low):** continuous-corner apex offset is the shape's nature; two accidental closes
  ending the tour is fine since `?` replays it; Quit by right-click (hint + tooltips, as Activity Monitor); Settings
  space waits for Milestone 4; the dim strength was tuned in round 1.
- **A I3, B I4 (unverifiable off-screen):** NSMenu right-click, trackpad scrolling, hover in the real panel and the
  tour hole click-through: owner checks below.

### Owner checks this round adds (need `./Scripts/bundle.sh`, the owner's OK)
- CPU breakdown, pointer resting on the 2nd row while something below gets busy: rows below re-sort, nothing at or
  above the pointer moves.
- Scroll the list with a trackpad without moving the pointer: the order stops changing.
- Quit a busy app (or stop a `yes`): its row and the header drop within ~2 s, like the card.

## Next
Review round 6 (`/reviewer`, two independent reviewers) on HEAD of `feat/stability-tour`. Probes:
```bash
cat docs/design/breakdown-stability.md                              # the rules, constants, tests
cat docs/research/2026-10-06-probes/r5-fixes/README.md              # record/replay + render commands
OUT=$PWD/docs/research/2026-10-06-probes/r5-fixes/out docs/research/2026-10-06-probes/tour-render/run.sh
```

## Older "Next" (round 5 setup, kept for the probe commands)
Review round 5 (`/reviewer`, two independent reviewers) on HEAD of `feat/stability-tour`. Probes:
```bash
docs/research/2026-10-06-probes/r3-fixes/run.sh stability 100   # live, reviewer B's measures
docs/research/2026-10-06-probes/r3-fixes/run.sh synthetic
docs/research/2026-10-06-probes/tour-render/run.sh               # tour captures + insets, 128 GB overview
docs/research/2026-10-06-probes/tour-render/run.sh --breakdowns  # real-scan breakdowns
# round 4 record/replay + synthetic contention: docs/research/2026-10-06-probes/r4-fixes/README.md
```
