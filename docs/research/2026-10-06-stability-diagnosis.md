# MacStats "jumpiness": diagnosis and fix design

Date: 2026-10-06 · Branch: `feat/stability-tour` (baseline commit `1ed61cf`) · Research only: no source code
was changed for this document.

**Who this is for:** whoever implements the stability fixes in MacStats (the native Swift macOS menu-bar
system monitor in this repo; build/test notes are in `CLAUDE.md`). It explains *why* each number and list in
the popover jitters, with code locations and live measurements, then gives a concrete fix design that keeps
the audited accuracy (Activity Monitor / `top` / `vm_stat` parity) and does not raise MacStats's own CPU or
RAM use. It complements `docs/research/2026-10-06-ux-psychology.md` (Part 1.5 and Part 3 item 1 give the
research reasons; this document gives the mechanism and the numbers).

The owner's report: in the CPU breakdown VS Code reads 2 %, drops, then 2 % again, constantly; trying to
expand VS Code fails because the row re-sorts and the expansion "goes away"; the same jumpiness is on the
cards, rows and numbers everywhere.

---

## Terms

| Term | Meaning here |
|------|--------------|
| **Popover** | The panel that opens from the menu-bar icon (`MenuBarExtra(.window)`). |
| **Overview / cards** | The first screen: CPU, Memory, Network, Battery cards + Trash row (`Sources/MacStatsApp/OverviewView.swift`, `StatCard.swift`). |
| **Breakdown / drill-in** | The per-app list you get by clicking the CPU, Memory or Battery card (`Sources/MacStatsApp/BreakdownView.swift`). |
| **Scan** | One per-process read of every user process (`readRawProcesses`, `Sources/MacStatsCore/ProcessReader.swift`), only while a breakdown is open. |
| **Tick** | One overview sample (CPU ticks, network counters, VM stats), every 0.5 s while the popover is open (`AppModel.tick`, `Sources/MacStatsApp/MacStatsApp.swift`). |
| **Window** | The time span a rate is averaged over. CPU % of a process = CPU-time used during the window ÷ (window length × cores). |
| **pp** | Percentage points of the *whole Mac* (the breakdown's scale: 100 % = all 8 cores). 1 pp = 8 % "of one core" on this 8-core M3. |
| **Re-sort / rank swap** | Two rows changing places between updates. |
| **Hysteresis** | A deadband: a change is only acted on when it is clearly bigger than the noise, so a value sitting on a boundary doesn't flip back and forth. |
| **Dwell** | A change must hold for two readings in a row before it is acted on. |
| **Display hold** | Display-only hysteresis: the *shown* number keeps its old value until the new reading moves far enough from it. The stored reading stays exact. |
| **Freeze** | Row order (not values) is held fixed while the user is pointing at the list. |

---

## 1. Summary

1. **The breakdown re-sorts on every scan (once a second) with no tolerance.** `sortedRows` /
   `ranksBefore` (`Sources/MacStatsCore/ProcessBreakdown.swift:169-180`) sort by the raw value each scan, and
   each value is a fresh **1-second** average (`breakdownScanInterval = 1.0`,
   `Sources/MacStatsCore/RefreshScheduler.swift:43`). Bursty apps such as VS Code (measured 0.2–7.3 pp per
   scan, mean ~1.4 pp) cross their neighbours' values all the time. Measured: **the top-8 order changed on
   every single scan** (59 of 59 per minute, four runs) and **~5 of the 8 visible row slots showed a
   different app each second**.
2. **The click lands on whatever row is under the pointer when the mouse button goes up.** The row the user
   aimed at has often moved by then (VS Code changed position 13–34 times a minute). Expansion is an accordion
   (`expanded = expanded == app.appPID ? nil : app.appPID`, `BreakdownView.swift:158`), so a click on the app
   that slid in **collapses VS Code and opens the other app**: that's the expansion "going away". When VS Code
   itself changes rank, its whole block (up to 5 child rows + "N more…") moves too, so even a successful
   expansion slides out from under the pointer.
3. **Inside an expanded app, which 5 processes are shown changes about every other second.** Children are
   re-sorted every scan and cut at `prefix(5)` (`BreakdownList.rows`, `BreakdownView.swift:276-290`): the
   VS Code top-5 *set* changed 28–41 times a minute.
4. **Numbers change more often than anyone can read them.** Value text on the 8 visible rows changed
   ~364–386 times a minute (about 6 of 8 rows every second); "% of one core" just as often. The overview
   ticks every 0.5 s on 1-second windows: CPU text changed 80–91 times a minute, network 50–103, memory 22–30.
5. **Things the user points at move under the pointer.** Row hover highlights, tooltips (`.help`) and the
   right-click menu all belong to whichever app currently occupies that slot. **Risk:** a right-click → Quit
   aimed at one app can hit the app that just slid into that slot (Quit doesn't confirm; Force Quit does,
   with the name).

The fix (section 4): average breakdown rows over a **4-second trailing window**, re-rank only with a
**margin + dwell**, **freeze order while the pointer is in the list or a context menu is open**, **pin the
expanded app**, rank children the same way, apply **display holds** to text, and give the Battery breakdown's
bars a **sticky scale**. Simulated on the same live data: top-8 order changes drop from 59/min to 5–13/min
(0 while pointing), VS Code's child set from 28–41/min to 0–1/min, row text changes by ~70–75 %. All
logic is pure and unit-testable in `MacStatsCore`; nothing runs while the popover is closed, and the
recommended 2-second scan cadence halves the breakdown's own CPU cost.

---

## 2. How it works today (the data path)

| Stage | Where | Cadence / window |
|---|---|---|
| Overview tick: CPU ticks, net counters, VM stats | `AppModel.sample` (`MacStatsApp.swift`) | every 0.5 s while open (`refreshInterval(.popoverOpen)`); CPU and network are averaged over a trailing **1 s** (`rateWindowSeconds = 1.0`, `RefreshScheduler.swift:54`); memory is instantaneous |
| Temperature | `CPUTemperatureReader.read` → `cpuTemperature` (`CPUTemperature.swift`) | every 2 s; average of the `tdie` die sensors, rounded to 1 °C |
| Battery | `AppModel.refreshBattery` | every 10 s while open + on IOPS change notifications; the gauge itself updates every ~20–85 s |
| Breakdown scan | `AppModel.procScanTick` → `BreakdownScanSession.scan` → `BreakdownScanner.scan` (`ProcessScan.swift:322-429`) | first rescan after 0.5 s, then **every 1.0 s**; each scan's CPU/energy covers only the time since the previous scan (≈ 1 s) |
| Ranking | `aggregate` → `sortedRows` (`ProcessBreakdown.swift:137-180`) | full re-sort every scan, exact comparison, ties by pid |
| Publish | `MetricsStore.setBreakdown` (`MetricsStore.swift:176`) | replaces `breakdown` wholesale; not wrapped in an animation, so moved rows teleport |
| List | `BreakdownView.list` → `BreakdownList.rows` (`BreakdownView.swift:123-147, 276-290`) | `ScrollView` + `LazyVStack`, every app (no top-N cut), expanded app's first 5 processes + "N more…" |
| Row value text | `formattedValue` (`BreakdownView.swift:295-306`) | CPU: one decimal under 9.95 %, else integer; memory MB / GB; watts 2 decimals under 1 W |

Nothing in this path has memory of the previous order or of the previously *shown* value; every update is
independent, so every bit of measurement noise reaches the screen.

---

## 3. Every jitter source, one by one

### 3.1 Breakdown (CPU) — the owner's main complaint

| # | Symptom | Cause (code) | Severity |
|---|---|---|---|
| B1 | Rows swap places every second | 1-s per-scan values (`breakdownScanInterval`) + exact re-sort every scan (`sortedRows`). Light apps sit within 0.1–1 pp of each other and their 1-s values swing by several pp. | High |
| B2 | Clicking to expand VS Code opens/closes a different app | `.onTapGesture` on whichever row occupies the slot at mouse-up + accordion toggle (`BreakdownView.swift:155-161`). Aiming takes ~0.3–1 s; the slot's app changes ~5 times out of 8 per second. | High |
| B3 | Expanded block slides away | The expanded app's rank changes like any other; its children move with it; `LazyVStack` keeps the scroll offset, so the content moves past a still pointer. | High |
| B4 | Expanded app's process list churns | Children re-sorted every scan (`aggregate` sorts `processes`) + `prefix(visible)` cut (top-5 set changed 28–41 /min). The "N more…" count changes when processes come and go. | High |
| B5 | Numbers flicker | 1-s window; one-decimal text below 10 % (0.1 pp ≈ 0.8 % of one core is far below the noise); `contentTransition(.interpolate)` + 0.25 s animation on every change draws the eye to each flip (`AppRow`, `BreakdownView.swift:365-369`). | Medium |
| B6 | "% of one core" flickers | `oneCore(...)` = value × 8, integer: each 0.125 pp of noise is a visible change (`BreakdownView.swift:181-183`). | Medium |
| B7 | Header "N% used" jumps on entering, then wobbles | Before the second scan it shows the card's 1-s value (`cpuTotal` falls back to `store.cpuPercent`), then switches to the scan-interval total (`breakdownTotalCPU`), which is a different 1-s span. | Low |
| B8 | "System" and "Other processes" rows move a lot | System = whole-Mac total − rows (`addingSystemRow`), so it carries the noise of every row plus WindowServer/kernel bursts; both rank with the apps. | Medium |
| B9 | "Exited processes" child row blinks in and out | Exit credit exists only in the scan where a process vanished (`exitWorkCredit`, `ProcessScan.swift:445`). | Low |
| B10 | Hover highlight / tooltip / right-click on the wrong app | Hover is per-row `@State hovering` set only by `onHover` events; SwiftUI sends those on pointer movement, so when rows reorder under a still pointer the highlight stays with the row that moved (or disappears). `.help` and `.contextMenu` belong to the row identity, not the slot. Right-click → **Quit** has no confirmation. | High (wrong-target action) |
| B11 | Rows teleport | `setBreakdown` isn't animated, so reorders are instant jumps; meanwhile bars (`UsageBar`, 0.3 s) and values (0.25 s) *are* animated, which makes a teleported row look like a glitch. | Low |

### 3.2 Breakdown (Memory)

Rows are instantaneous physical footprints (no window), so ranks only swap between apps within a few MB of
each other: today 0–29 order changes per minute depending on the run (two near-equal apps can trade places
every second). Value text ("%.0f MB") changed 23–45 times a minute. Same B2/B3/B10 interaction risks when it
happens. Group rows are already pinned last (`sortedRows`, memory case).

### 3.3 Breakdown (Battery / energy)

- Same 1-s window as CPU, and energy is even burstier than CPU time.
- **Bars rescale every second:** `barScale = store.breakdown.first?.value(for: .energy)` (`BreakdownView.swift:70`)
  — every bar is relative to the *current top row*, so whenever the top value changes, every bar on screen
  changes length at once, even rows whose value didn't move.

### 3.4 Overview cards

| Card / value | Cause | Measured (text changes per minute, max 118) |
|---|---|---|
| CPU "N%" | 1-s window re-evaluated every 0.5 s (successive windows overlap by half), integer rounding with no deadband | 80–91 |
| Memory "X.X / 16.0 GB" | instantaneous used bytes; 0.1 GB steps; memory wanders by tens of MB, so a value near a boundary flips | 22–30 |
| Network "↓ N KB/s" and "↑ …" | 1-s window every 0.5 s on bursty traffic; integer KB/s, and a format switch at 999.5 KB/s ↔ 1.0 MB/s | 50–103 |
| CPU temperature "N°C" | 2-s reads of a noisy average, rounded to 1 °C (`cpuTemperature`), then `Int(t)` | not measured (the probe can't link the sensor shim); the die average moves ±1 °C between reads, so it flips at .5 boundaries |
| Battery "time left" | changes only on a gauge reading (~1/min); `formatTimeLeft` rounds to 5 min under 2 h, 15 min under 6 h (`DurationFormat.swift`), so an estimate near a step boundary flips ("1h 35m" ↔ "1h 40m") once a minute | low rate, but every flip is a visible "the estimate changed its mind" |
| Battery "time to full" | minute precision under 1 h; can tick *up* by a minute when the charge-current average (`ChargeCurrent`, τ = 5 min) dips | low rate, odd direction |
| Sparklines | slide every 0.5 s by design (`Sparkline.swift`) | intended; graphs are glanced at, not read |

### 3.5 Not causes (checked)

- Row identity is stable: app rows are keyed `"a\(appPID)"`, processes `"p\(pid)"` (`BreakdownList.Row`), and
  `expanded` is keyed by app pid, so the expansion state itself survives re-sorts and doesn't reset. The
  problem is the *click target* and the *position*, not lost state.
- There's no top-N cut on apps (the whole list scrolls); the only cut is the 5-child prefix (B4).
- `BreakdownView` keeps its `@State` across updates (stable `if let metric` branch in `RootView`).

---

## 4. Measurements (live, headless)

**Probe:** a throwaway `main.swift` in a scratch directory outside the repo (deliberately not committed; to
repeat the measurement, rewrite it from this description), compiled together with the real
`Sources/MacStatsCore/*.swift` minus `AppleSensorReader.swift` (it needs the `CAppleSensors` C shim), from the
repo root:

```bash
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -O -o <dir>/probe \
  $(ls Sources/MacStatsCore/*.swift | grep -v AppleSensorReader) <dir>/main.swift
(<dir>/probe 90 & PID=$!; (sleep 130; kill $PID) & wait $PID)
```

It copies the app's `BreakdownScanSession` exactly (running-apps anchors, clocks, `readRawProcesses`,
`BreakdownScanner.scan`) and the overview's rate-window logic. It scans at the app's cadence (0.5 s, then every
1 s), ticks the cards at 0.5 s, then replays the recorded values through the proposed logic. No UI, no window.
Four runs of 60–90 s on this M3 (8 cores) with VS Code open; the Mac was fairly busy (whole-Mac CPU mean
13–17 %, range 7–45 %, other agent sessions running), which is the hard case. Mean scan cost 4.2–5.5 ms.
"Visible" = the top 8 rows. Ranges are min–max across runs.

### 4.1 CPU breakdown

| Per minute | Today (1 s, strict sort) | Window only (3 s, strict sort) | A: 3 s window + margin 15 % + 0.2 pp | C: 5 s window (1 s scans) + margin 25 % + 0.3 pp + dwell | **D: 2 s scans, 4 s window, margin 25 % + 0.3 pp + dwell** |
|---|---|---|---|---|---|
| Top-8 order changed | **59 of 59** | 53–56 | 19–31 | 7–18 | **5–13 of 29** |
| Row slots showing a different app | 283–320 | 183–205 | 63–93 | 17–48 | **14–33** |
| VS Code row moved | 13–34 | 18–21 | 15–17 | 5–11 | **5–9** |
| VS Code value text changed | 52–55 | 47–50 | 39–41 | 12–23 | **15–19** (9 with a 15 % band) |
| Value text changes, top 8 | 364–386 | 285–308 | 228–256 | 113–138 | **89–109** (78 with a 15 % band) |
| VS Code top-5 children: set changed | 28–41 | — | 0–1 | 0–1 | **0** |
| Largest out-of-order gap shown (pp) | 0 | 0 | 0.9 | 2.5–4.1 | 3.7–3.8 (one reading, during a spike) |

Takeaways: the window alone barely helps (real swings, not just sampling noise, reorder the list); the
margin + dwell is what stops the swapping; nothing short of **freezing while pointing** makes the slot under
the pointer constant (the residual 5–13 changes a minute are real load changes on a busy Mac). "Largest
out-of-order gap" is the accuracy price of hysteresis: with dwell a sudden spike reaches its rank one scan
late (2 s); section 5.2 adds a "big jumps move at once" rule to cap it.

With the windowed header computed over the same window, the shown rows still add up to the shown header
within 0.6–1.6 pp (display rounding/holds only; the underlying sums are exact).

### 4.2 Memory breakdown and cards

| Per minute | Today | Proposed |
|---|---|---|
| Memory breakdown, top-8 order changed | 0–29 | 0.7–1 (margin 5 % + 20 MB) |
| Memory breakdown, row text changed | 23–45 | 10–16 (hold band 3 %) |
| CPU card text | 80–91 | 56–72 (2 s window + 0.75-step hold; shown value within 0.74 pp of the 2 s average) |
| Memory card text | 22–30 | 14 (1-step hold, shown within 0.09 GB) |
| Network ↓ text | 50–103 | 17–26 (2 s window + hold band max(1.5 steps, 15 %)) |

The CPU card keeps changing about once a second because whole-Mac load really was moving 7–30 % on this
machine; a stronger hold (5 % relative) or updating the text once a second instead of every 0.5 s gave no
further gain in the same data and sample-and-hold read up to 4.3 pp stale, so neither is recommended.

---

## 5. Fix design

Principles (from the UX research doc, Part 1.5): **slow what is read, freeze what is pointed at, keep moving
only what is glanced at (graphs).** Every reading stays an exact average over a stated window; holds and
margins are bounded and only affect what is *shown*.

### 5.1 Per-app CPU and energy over a trailing window, header over the same window

- **Scan every 2 s instead of 1 s** (`breakdownScanInterval = 2.0`; keep `breakdownFirstRescanDelay = 0.5`
  so "Measuring…" stays short), and show each row as the average over the **last 4 s** (the last two scan
  intervals; on the 2nd and 3rd scan the window is what's available: 0.5 s, then 2.5 s). Activity Monitor's
  own default refresh is 5 s (its "Often" option is 2 s), so this is still at least as live as the reference
  app. It also **halves the breakdown's own CPU cost** (measured 4.2–5.5 ms per scan → ~2.5 ms/s).
  Alternative if the owner wants 1-s updates: keep 1 s scans with a 5-scan window (variant C, similar
  stability, same CPU cost as today).
- **Where:** inside `BreakdownScanner` (`ProcessScan.swift`). Keep a small ring of the last *K* intervals,
  each holding: `elapsed`, the machine's busy CPU-ns for the interval (from the same `CPUTicks` it already
  reads), and per-pid `(ownerAppPID, cpuNs after creditScale, energyNj after creditScale)` plus the interval's
  exit credit per app. Drop intervals older than the window (`trailingWindowSeconds = 4`). Each scan:
  - process row value = Σ ns over the window ÷ (Σ elapsed × cores) — exactly "% of the Mac over the last 4 s";
  - header (`totalCPUPercent`) = Σ busy-ns ÷ (Σ elapsed × cores) — the same span, so rows + System still add
    up to it (the "System" row stays "total − rows");
  - a process that started mid-window counts only what it used (÷ the whole window), like Activity Monitor;
  - a process that exited mid-window: its earlier ns stay in the window under its app's existing
    **"Exited processes"** child row (app still running), else they fall into System (today's rule). This
    also makes that row steady for the window instead of blinking (B9).
  - Memory rows stay instantaneous (footprint has no window).
- Cost: K = 2–5 dictionaries of ~500 `(Int32 → 3 × UInt64)` entries ≈ 20–60 KB while a breakdown is open,
  freed on back. No extra syscalls.
- Implementer checks: `ProcessSampler.debtScans = 3` is counted in scans, so at 2 s it spans 6 s instead of
  3 s (harmless: the debt is a cap). `exitWorkCredit`'s baseline (`lastSystemPercent`) should keep using the
  *per-interval* System value, not the windowed one.

### 5.2 Stable ranking: margin + dwell (pure, `MacStatsCore`)

```swift
/// Re-ranks rows with hysteresis. Starts from `previous` (rows that vanished are dropped, new rows enter at
/// their sorted place), then lets a row climb past the one above only when it is clearly bigger on the last
/// two readings: min(now, before) > max(now, before) of the row above × (1 + rel) + abs.
/// A row that leads by a lot (> 2× and > `jump`) moves at once (a real spike isn't held back).
/// `pinned` rows keep their index (others reorder around them). `frozen` returns `previous` as is
/// (+ new rows appended at the end, vanished ones removed).
public func stableRanking(previous: [Int32], now: [Int32: Double], before: [Int32: Double],
                          rule: RankHysteresis, pinned: Set<Int32> = [], frozen: Bool = false) -> [Int32]
```

- Algorithm: one insertion pass (what the probe ran, plus the jump rule): O(n²) worst case on ~60 rows,
  microseconds.
- Rules (pp = points of the whole Mac): CPU `rel 0.25, abs 0.3 pp (≈ 2.4 % of one core), jump 2 pp`;
  memory `rel 0.05, abs 20 MB, jump 200 MB` (group rows stay last, as today); energy `rel 0.25, abs 0.05 W,
  jump 1 W`. Ties and new-row placement keep today's pid tie-break, so the order is deterministic.
- Apply to **app rows and to each app's process rows** (children) with the same rule, so the expanded app's
  top-5 stay put (B4).
- State: the previous order and previous values per breakdown, held next to `breakdown` in `MetricsStore`
  (Core), reset in `beginBreakdown` / `clearBreakdown`. `setBreakdown` takes the scanner's rows and publishes
  them in the stable order. The scanner keeps returning the true sort (tests keep meaning "sorted").

### 5.3 Freeze while pointing, pin the expanded app

- **Freeze:** `BreakdownView` reports pointer-in-list with one `.onHover` on the list card (not per row) and
  menu tracking with `NSMenu.didBeginTrackingNotification` / `didEndTrackingNotification` (observed only while
  `BreakdownView` exists; a context menu is an `NSMenu`). It calls `store.setBreakdownOrderFrozen(true/false)`.
  While frozen, `setBreakdown` still updates **values** in place but keeps the order (`frozen: true`); new apps
  are appended at the bottom, quit apps removed. On pointer exit the freeze ends at the **first scan ≥ 1 s
  after exit** (compare timestamps in `setBreakdown`), so moving the pointer out and back to click doesn't
  meet a reshuffle, and **no timer** is needed.
- This fixes B2, B3 and B10: the slot under the pointer, its hover highlight, tooltip and right-click target
  can't change while the pointer is there. Quitting the wrong app becomes impossible by this route.
- **Pin the expanded app:** while an app is expanded, pass it as `pinned` so it keeps its index even when the
  pointer is outside the list; other apps reorder around it. The UX doc suggested freezing the *whole* order
  while expanded; pinning only the expanded app keeps the rest of the list truthful when the user isn't
  pointing, and stops the expanded block from sliding.
- If an expanded app quits, clear `expanded` (today it silently stays set to a dead pid).
- **Animate only applied reorders** (rare now): wrap the publish in `withAnimation(.snappy(duration: 0.25))`
  when, and only when, the order actually changed, so the few remaining moves slide instead of teleport (B11).
  Never while frozen (nothing moves then).

### 5.4 Display holds for text (pure, `MacStatsCore`)

```swift
/// The value to show: `shown` (the last shown, already quantised) unless `value` moved at least
/// max(band × step, relBand × |shown|) away; then `value` quantised to `step`.
public func heldValue(shown: Double?, value: Double, step: Double, band: Double = 0.75,
                      relBand: Double = 0) -> Double
```

- Error bound: |shown − true| ≤ max(band × step, relBand × shown) — e.g. CPU card ≤ 0.75 pp instead of 0.5 pp
  from rounding. Stored readings, sparklines and alerts keep the exact values.
- Where state lives: `MetricsStore` keeps the shown values next to the raw ones (e.g. `shownCPUPercent`),
  updated in `record(...)` and in the paused/resume path (a resume shows the latest value, hold restarted).
- Settings:
  - CPU card: `rateWindowSeconds` 1 → **2 s** (also smooths the sparkline a little; history keeps 0.5 s
    points), hold `step 1, band 0.75`.
  - Memory card: hold the **whole `MemorySample`** (used + App/Wired/Compressed parts) as one unit when used
    moved < 1 step (0.1 GB), so the Memory breakdown's parts card still adds up to the header.
  - Network ↓/↑: 2 s window, `step` = the printed precision (1 KB/s or 0.1 MB/s), `band 1.5, relBand 0.15`.
    Also hold the KB/s ↔ MB/s switch the same way.
  - Temperature: `step 1 °C, band 1.0` (a reading must move a full degree from what's shown).
  - Breakdown rows: `step` = printed precision (0.1 below 10 %, else 1; 1 MB / 0.1 GB; 0.01 / 0.1 W),
    `relBand 0.10` for CPU and energy, `0.03` for memory. **Derive "% of one core" from the held value**
    (shown × cores) so the two numbers on a row always agree (or drop it from rows, per the UX doc Part 3
    item 3). The header "N% used" uses the windowed total with the CPU card's hold.
  - Battery time left: hold in minutes with `step` = the `formatTimeLeft` rounding step at that length
    (1/5/15/60 min) and `band 0.75`. Time to full: let it fall freely, but only let it **rise** by ≥ 2 min
    (a countdown that ticks up reads as broken).
- Bars may keep following the windowed value (they animate smoothly; a 4-s average moves little).

### 5.5 Battery breakdown bar scale

Replace "relative to the top row" with a **sticky nice scale**: `niceUpperBound(peak:)` (already in
`SparklineGeometry.swift`, 1-2-5 ladder) that grows at once but only shrinks when the peak falls below 40 %
of it. Pure function `stickyUpperBound(previous:peak:)` next to `niceUpperBound`. Bars then change only when
their own row changes.

### 5.6 What stays as is

- Sparklines keep sliding at 0.5 s (glanced at, not read).
- The CPU breakdown header falls back to the card value before the first windowed total (B7); with the 2-s
  card window and the 4-s breakdown window the difference on entry is small. Fine to leave.
- Closed-popover behaviour is untouched: the idle sampler (10 s) and alerts use raw values; nothing new runs
  while closed or while no breakdown is open.

---

## 6. What must be pure and unit-tested in `MacStatsCore`

The test target (`Tests/MacStatsCoreTests`, Swift Testing, run with `./Scripts/test.sh`) can only reach
`MacStatsCore`, so every decision above lives there; the views only read results and report hover/menu state.

| Unit | File (suggested) | Tests to write |
|---|---|---|
| Trailing window in `BreakdownScanner` | `ProcessScan.swift` | rows over K intervals equal Σns ÷ (Σelapsed × cores); header over the same window; rows + System = header; window trims by time; a process starting mid-window; a process exiting mid-window lands in its app's "Exited processes" row (or System if the app is gone); first scans after "Measuring…" use the partial window; memory unaffected |
| `stableRanking` + `RankHysteresis` | `ProcessBreakdown.swift` or new `StableRanking.swift` | no swap within margin; swap only when it holds on two readings; jump rule moves a spike at once; new rows enter at sorted place; vanished rows removed; `pinned` keeps index; `frozen` keeps order and appends new rows; memory group rows stay last; deterministic ties |
| `heldValue` | new `DisplayHold.swift` | boundary wobble (8.49 ↔ 8.51) holds; a real move passes; error bound; nil → quantised value; relative band |
| Memory sample hold | `MemoryStats.swift` / `MetricsStore` | parts and used are held together (still add up) |
| `stickyUpperBound` | `SparklineGeometry.swift` | grows immediately; shrinks only below 40 %; never below the minimum |
| Time-left / time-to-full holds | `DurationFormat.swift` | step-boundary wobble holds; time to full can fall by 1 min but not rise by 1 |
| `MetricsStore` integration | `MetricsStore.swift` | `setBreakdown` applies the stable order; freeze flag holds order but updates values; unfreeze takes effect on the first scan ≥ 1 s after exit; reset on `beginBreakdown` / `clearBreakdown`; held card values survive pause/resume correctly |

Constants go next to the existing ones in `RefreshScheduler.swift` (`breakdownScanInterval`,
`trailingWindowSeconds`, `rateWindowSeconds`) with a comment citing this document's measurements.

---

## 7. Cost check (owner's requirement: MacStats must stay cheap)

- No new timers anywhere; the unfreeze delay is a timestamp check in `setBreakdown`.
- No extra per-process scans; the recommended 2-s cadence **halves** breakdown scan work while drilled in.
- Extra memory only while a breakdown is open: the interval ring (~20–60 KB) and previous order/values
  (~a few KB); freed on back / close (`clearBreakdown`).
- Overview: one extra snapshot in the 2-s rate window (5 instead of 3 `Snapshot`s, ~100 bytes each) and a
  handful of held doubles.
- Fewer value changes → fewer `contentTransition` animations and fewer SwiftUI diffs per second while open.
- Verify after implementing, the same way as the readings-accuracy work did: idle/closed CPU and footprint
  (`top -l` / `footprint` on the installed app) unchanged; drilled-in CPU lower than at `1ed61cf`.

---

## 8. Suggested order of work

1. `heldValue`, `stableRanking`, `stickyUpperBound` + tests (pure, no behaviour change yet).
2. Trailing window in `BreakdownScanner` + tests; `breakdownScanInterval = 2`.
3. `MetricsStore`: stable order, freeze flag, pinned app, held values; tests.
4. `BreakdownView`: list `.onHover` → freeze, `NSMenu` tracking → freeze, pin expanded, clear `expanded` when
   its app quits, derive "% of one core" from the shown value, animate only applied reorders, sticky energy
   scale.
5. Cards: 2-s `rateWindowSeconds`, holds for CPU / memory / network / temperature / battery times.
6. Re-run the probe (section 4) against the new code paths and an off-screen render check of the breakdown
   (see `docs/reviews/2026-10-05-readings-accuracy/*/` for probe patterns) — everything in the background.
