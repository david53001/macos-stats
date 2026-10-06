# Stability + guided tour — progress (2026-10-06, branch `feat/stability-tour`)

Baseline commit: `1ed61cf`. Owner's request: (1) stop values/rows jumping (e.g. CPU breakdown re-sorts
under the pointer so VS Code can't be expanded), (2)+(4) make the app understandable in ~30 s, grounded in
UX research, (3) a skippable guided tour + intro like BetterScreenshot (TourKit) / JVoice (WelcomeWindow),
highlight perfectly concentric around the squircle cards, (5) review to > 9/10, no RAM/CPU regression.

## Done
- **UX research + audit (parts 2 and 4)** — `docs/research/2026-10-06-ux-psychology.md` (research with
  sources, audit of every string/clickable/alignment at `1ed61cf`, ranked change list with exact strings,
  tour/intro sketch incl. highlight geometry: ring outset 4 pt, radius 12 pt). Screenshots + off-screen
  probe source: `docs/research/2026-10-06-ux-audit/`. No source edits.
- **Jumpiness diagnosis (part 1)** — `docs/research/2026-10-06-stability-diagnosis.md`: every jitter source
  with code locations, live headless measurements (top-8 CPU rows re-sorted on every 1 s scan; VS Code's
  top-5 children changed 28–41×/min), and the fix design: 2 s scans + 4 s trailing window, rank margin +
  dwell (`stableRanking`), freeze order while pointing / context menu open, pin the expanded app, display
  holds (`heldValue`), sticky energy bar scale; list of pure functions + tests for `MacStatsCore`. No source edits.

## Next
- Stability fixes: implement `docs/research/2026-10-06-stability-diagnosis.md` section 8 (order of work); copy/affordance fixes (`docs/research/2026-10-06-ux-psychology.md` Part 3 items 2–8); tour + intro (same doc, Part 4).
