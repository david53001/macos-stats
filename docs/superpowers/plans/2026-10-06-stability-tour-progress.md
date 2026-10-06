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
- [ ] A1: pure helpers (`DisplayHold.swift`, `StableRanking.swift`, `stickyUpperBound`, `BreakdownFormat.swift`) + tests
- [ ] A2: 4 s trailing window in `BreakdownScanner`; `breakdownScanInterval` = 2 s; tests
- [ ] A3: `MetricsStore` stable order, freeze, pin and held row values; tests
- [ ] A4: held card values; `rateWindowSeconds` = 2 s; tests
- [ ] A5: views (`BreakdownView` freeze/pin/held text/energy scale/reorder animation; cards read held values)
- [ ] A6: headless stability probe `docs/research/2026-10-06-probes/stability/` + results; `CLAUDE.md` Status bullet

### Part B: Intuitiveness + tour (agent 2, only after Part A). Plan section "PART B"
- [ ] B1: `Tour.swift`, `TourLayout.swift` + `TourStateTests`, `TourRulesTests`, `TourLayoutTests`, `TourCatalogLintTests`
- [ ] B2: copy, affordance and layout fixes (exact string table in the plan); Trash permission state
- [ ] B3: `TourController`, audience classified before `AppModel()`, permission prompts after the intro, reopen opens the panel
- [ ] B4: anchors, `TourOverlay` (dim + centred squircle cutout + accent ring + callout), welcome card, chip, `?` button, Settings Help
- [ ] B5: render probe `docs/research/2026-10-06-probes/tour-render/` with captures + `out/insets.txt` (equal insets ≤ 1 px)
- [ ] B6: cost check (static + runtime) + `CLAUDE.md` Status bullet

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

## Next
Part A, task A1 (plan section "A1. Pure helpers + tests").
