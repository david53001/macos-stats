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

## Next
- Stability fixes (research doc Part 3 item 1), copy/affordance fixes (items 2–8), tour + intro (Part 4).
