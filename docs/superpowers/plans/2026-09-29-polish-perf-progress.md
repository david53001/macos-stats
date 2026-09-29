# MacStats polish + performance — progress note (2026-09-29)

Branch: `feat/polish-perf` (off `feat/temp-alerts-trash`). Approved by the user in chat (no separate spec).
Repo: `/Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats`. Build: `swift build`; tests: `./Scripts/test.sh`;
install + run: `./Scripts/bundle.sh && open ~/Applications/MacStats.app`.

## Goal
Make MacStats feel smoother and more "Apple", while using less RAM/CPU:
1. **Instant open** — numbers are real on the first frame, and the graph already shows the last ~60 s (the idle
   10 s alert sampler also records CPU / memory / network history). The store is no longer wiped on close.
2. **Apple-native graphs without Swift Charts** — the user approved dropping Swift Charts (was a "locked decision"),
   on condition the graphs still look like Apple's (area gradient + line, same colors). Fixed 60 s *time* axis (newest
   at the right edge; nothing stretches), smooth monotone curves, "now" dot, eased network scale, short slide per update.
3. **Faster numbers, same cost** — 0.5 s cadence while open (rates still averaged over a 1 s trailing window), rolling
   digits (`.contentTransition(.numericText())`); temp every 2 s with a cached sensor client, battery every 10 s.
4. **Squircles & layout** — continuous-corner (squircle) inset cards on the existing blurred material (keep the colors),
   concentric radii, hover highlight, identical fixed height for overview & breakdown with a slide transition.
5. **Placement ("where it opens and how it opens")** — *changed from the first plan:* we KEEP `MenuBarExtra`.
   Findings (2026-09-29): the blurred background is drawn by the window server for the private `MenuBarExtraWindow`
   (no `NSVisualEffectView`/backdrop layer in its view or layer tree), so a hand-built `NSPanel` couldn't reproduce
   it exactly; the position (right edge aligned under the icon, small gap) already matches Apple's own Battery panel;
   and Apple's Tahoe menu-bar panels appear *instantly* with complete content (screen-recorded). So "how it opens"
   = instant and fully populated on the first frame (data work) with no resizing (fixed height). Hover pre-warm is
   done via a tracking area on the `NSStatusBarButton` (`Sources/MacStatsApp/StatusItemHover.swift`, committed).
6. **Less RAM** — measured before: 46 MB footprint idle, but only ~9 MB live (24 MB freed-but-unreturned malloc);
   peak 121 MB while open. Fixes: cached small app icons, `malloc_zone_pressure_relief` after close, timer tolerance.
7. **Launch at login** — already built (`Sources/MacStatsApp/LoginItem.swift`), committed in `ed6f9a5`, verified
   (`defaults read com.macstats.MacStats didRegisterLoginItem` → 1).

## Status
"Agent A/B" are sub-agents working in separate git worktrees, each committing to its own branch. If this session died
before merging, find their work with `git worktree list` and `git branch`, then merge into `feat/polish-perf`.

- [x] Base scaffolding committed: `SamplePoint` (Core), time-stamped histories in `MetricsStore`, `Design.swift` shared
      geometry, `@main` moved to `MacStatsMain.swift`, `AppModel.prewarm()` stub, placeholder `Sparkline` (no Charts).
- [ ] Agent A — data pipeline & perf (Core + `AppModel`).
- [ ] Agent B — visuals (Sparkline, cards, overview/breakdown, transitions, icon cache, Force Quit via NSAlert).
- [x] Lead — hover pre-warm hook (`StatusItemHover.swift`, wired in `MacStatsMain.swift`); keep `MenuBarExtra`.
- [ ] Merge A and B (worktree branches), bundle, screenshot/screen-record the open, measure RAM vs the 46 MB baseline.
- [ ] Update `CLAUDE.md` / `README.md` status + the Swift Charts locked decision.

## How to check the UI without clicking
`osascript -e 'tell application "System Events" to tell process "MacStats" to click menu bar item 1 of menu bar 2'`
then `screencapture -x out.png`. RAM: `footprint -p $(pgrep -x MacStats)`.
