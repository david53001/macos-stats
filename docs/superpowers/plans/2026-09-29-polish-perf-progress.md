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
5. **Placement ("where it opens and how it opens")** — replace `MenuBarExtra` with our own `NSStatusItem` + `NSPanel`:
   consistent position under the icon, clamped to the screen, a quick native-feeling open/close animation, the
   same material as before, hover on the icon pre-warms a sample (`AppModel.prewarm()`).
6. **Less RAM** — measured before: 46 MB footprint idle, but only ~9 MB live (24 MB freed-but-unreturned malloc);
   peak 121 MB while open. Fixes: cached small app icons, `malloc_zone_pressure_relief` after close, timer tolerance.
7. **Launch at login** — already built (`Sources/MacStatsApp/LoginItem.swift`), committed in `ed6f9a5`, verified
   (`defaults read com.macstats.MacStats didRegisterLoginItem` → 1).

## Status
- [x] Base scaffolding committed: `SamplePoint` (Core), time-stamped histories in `MetricsStore`, `Design.swift` shared
      geometry, `@main` moved to `MacStatsMain.swift`, `AppModel.prewarm()` stub, placeholder `Sparkline` (no Charts).
- [ ] Agent A — data pipeline & perf (Core + `AppModel`).
- [ ] Agent B — visuals (Sparkline, cards, overview/breakdown, transitions, icon cache, Force Quit via NSAlert).
- [ ] Agent C — panel shell (`NSStatusItem` + `NSPanel`, placement, open animation, hover prewarm, dismissal).
- [ ] Merge, remove `RootView`'s `onAppear/onDisappear` (the panel drives visibility), bundle, screenshot, measure RAM.
- [ ] Update `CLAUDE.md` / `README.md` status + the Swift Charts locked decision.

## How to check the UI without clicking
`osascript -e 'tell application "System Events" to tell process "MacStats" to click menu bar item 1 of menu bar 2'`
then `screencapture -x out.png`. RAM: `footprint -p $(pgrep -x MacStats)`.
