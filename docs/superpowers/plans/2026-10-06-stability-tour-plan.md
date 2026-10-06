# Stability + intuitiveness + guided tour: implementation plan (2026-10-06)

**Repo:** `/Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats` (native Swift macOS menu-bar system
monitor; build/test/SDK notes in its `CLAUDE.md`). **Branch:** `feat/stability-tour`. **Baseline (before this
work):** `1ed61cf`. **Progress note (keep it updated):** `docs/superpowers/plans/2026-10-06-stability-tour-progress.md`.

This plan stands on its own. It turns three research documents into two build parts that two different agents do
**one after the other**:

- **Part A: Stability.** Values, row order, expansion and right-click menus stop jumping.
- **Part B: Intuitiveness + tour.** Copy, affordance and layout fixes, plus an in-panel intro and a skippable
  guided tour with a squircle spotlight that is exactly centred on each card.

Part B starts only after Part A is committed and its tests pass. Both parts edit `BreakdownView.swift`, so they
must not run at the same time.

Research it is based on (read the sections cited before each task, not the whole documents):

| Doc | What it holds |
|---|---|
| `docs/research/2026-10-06-stability-diagnosis.md` | Why every number and list jitters, live measurements, the fix design (sections 5–8). |
| `docs/research/2026-10-06-ux-psychology.md` | Research on how people learn apps, an audit of every string and clickable element, and ranked changes with exact strings (Part 3). |
| `docs/research/2026-10-06-tour-design.md` | How BetterScreenshot and JVoice build their tours, plus the MacStats tour design: copy, geometry, persistence, tests, `MenuBarExtra` pitfalls (Parts B–D). |
| `docs/research/2026-10-06-ux-audit/` | Screenshots of the UI at `1ed61cf`, and the off-screen probe source they came from (`probe-main.swift`, `probe-Package.swift`). |

Where the docs disagree, this plan decides. Each decision is listed in "Decisions" below, and the ones the owner
may want to change are repeated in the progress note.

---

## Terms

| Term | Meaning |
|---|---|
| **Popover / panel** | The 320 × 404 pt window under the menu-bar icon (`MenuBarExtra(.window)`), with squircle corners of 16 pt. |
| **Overview** | The panel's first screen: the CPU, Memory, Network and Battery cards, the Trash row, and the footer (Quit, gear). `Sources/MacStatsApp/OverviewView.swift`. |
| **Card** | One inset rounded rectangle, 8 pt continuous corners (`Design.cardCornerRadius`), 6 pt apart (`Design.cardSpacing`), 8 pt from the panel edge (`Design.panelInset`). |
| **Breakdown / drill-in** | The per-app list you get by clicking the CPU, Memory or Battery card. `Sources/MacStatsApp/BreakdownView.swift`. |
| **Scan** | One per-process read (`readRawProcesses`), which runs only while a breakdown is open. `BreakdownScanner.scan` is in `Sources/MacStatsCore/ProcessScan.swift`. |
| **Tick** | One overview sample, every 0.5 s while the popover is open (`AppModel.tick`, `Sources/MacStatsApp/MacStatsApp.swift`). |
| **Window (rate window)** | The time span a rate is averaged over. |
| **pp** | Percentage points of the whole Mac (the breakdown's scale: 100 % = all cores). |
| **Hysteresis / margin** | A row only climbs past its neighbour when it is clearly bigger, not when it is ahead by noise. |
| **Dwell** | The lead must hold on two readings in a row before a row moves. |
| **Display hold** | The *shown* number keeps its old value until the new reading moves clearly away from it. The stored reading stays exact. |
| **Freeze** | Row *order* is held fixed (values still update) while the pointer is over the list or a right-click menu is open. |
| **Pin** | The expanded app keeps its row index while other rows reorder around it. |
| **Squircle / continuous corners** | `RoundedRectangle(cornerRadius:style: .continuous)`. |
| **Concentric** | A rounded shape around or inside another uses radius = the other's radius ± the gap between them. |
| **Tour / step / anchor / callout** | A tour is an ordered list of steps. Each step highlights one real element (its anchor) and shows a callout bubble with a title, a body, "n of m" and buttons. |
| **Cutout / ring / dim** | The dim is a translucent layer over the panel. The cutout is the clear hole in it over the anchor, and the ring is the 2 pt accent-colour outline inside the cutout's edge. |
| **Audience** | `new` or `existing` user. It is decided once, at the first launch of a build that has the tour, and stored. |
| **Probe** | A small throwaway or reusable program that runs the real code with no visible window, to measure or render it. |

---

## Ground rules (both parts)

- **Everything in the background.** The owner is working at this Mac. Never call `NSApp.activate`,
  `makeKeyAndOrderFront` or `orderFront`, never click or move the mouse, never open the installed MacStats
  popover or drive the real menu bar, and never take full-screen screenshots. Render probe windows at
  `CGWindowLevelForKey(.desktopWindow) + 1` with `orderBack(nil)`, capture them with
  `CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution])`
  (fall back to `cacheDisplay`), and close them right after.
- **Always run a probe with a kill timeout**, with the binary itself in the slot:
  `(./probe ARGS & PID=$!; (sleep 120; kill $PID) & wait $PID)`. Before finishing, run
  `pgrep -fl probe` and kill anything you started.
- **No heavy jobs.** Run one `swift build` or `./Scripts/test.sh` at a time. A bare build needs
  `export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`. The scripts set it themselves.
- **Tests:** `./Scripts/test.sh` (Swift Testing: `import Testing`, `@Test`, `#expect`; never XCTest, never a bare
  `swift test`). One suite only: `./Scripts/test.sh --filter StableRankingTests`. 255 tests pass at `1ed61cf`.
- **Don't** install or replace `~/Applications/MacStats.app`, push, release or change remotes. Don't delete files
  you didn't create.
- **Commit** on `feat/stability-tour` in small logical commits. End every commit message with the line
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Cost limits (the owner's hard requirement):**
  - No new timers, polling or observers while the popover is closed.
  - No extra per-process scans.
  - Nothing tour-related runs, lays out or reads settings when the tour isn't on screen, apart from a few
    `UserDefaults` reads per popover open.
  - Readings stay at Activity Monitor / `top` / `vm_stat` parity. Holds and margins change only what is shown,
    within the stated bounds. Stored values, sparkline history and alerts keep the exact values.
- **Style:** match the existing code (doc comments on types and non-obvious functions, `Design` constants, no
  magic numbers in views). Use continuous corners everywhere, and keep radii concentric. See
  `docs/design-language/README.md` and `Sources/MacStatsApp/Design.swift`.
- **Pure logic goes in `MacStatsCore`.** The test target (`Tests/MacStatsCoreTests`) can only import
  `MacStatsCore`, so every decision that needs a test lives there, and the views only read results and report
  hover and menu state.
- **The session can end at any moment.** After each task, tick it in the progress note, add the commit hash
  and write the next step.

---

## Decisions (where the research docs differ, or the owner hasn't chosen yet)

| # | Question | Decision in this plan | Owner can flip? |
|---|---|---|---|
| D1 | While an app is expanded: freeze the whole list (UX doc) or pin only that app (diagnosis)? | **Pin only the expanded app.** The whole order is frozen only while the pointer is in the list or a context menu is open. | Yes: replace `pinned` with `frozen` while `expanded != nil`. |
| D2 | Breakdown cadence | **Scan every 2 s, with a 4 s trailing window** (diagnosis variant D). This halves scan CPU. | Yes: 1 s scans with a 5-scan window (variant C). |
| D3 | Ring geometry: 4 pt outset with 12 pt radius (UX doc), or 3 pt with 11 pt (tour doc)? | **Cutout = card + 3 pt on every side, radius 11, ring 2 pt inside it.** 3 pt is half the 6 pt gap between cards, and 11 + (8 − 3) = 16 = the panel radius, so it is concentric with both. | No (both are concentric; 3 pt never reaches a neighbour). |
| D4 | Separate welcome window (UX doc) or in-panel welcome card (tour doc)? | **In-panel welcome card** (no new windows; a window would steal focus and close the panel). To point at the icon, MacStats **opens its own panel once on a new user's first launch** and **when it is relaunched** (Spotlight or Applications), by clicking its own status button (`performClick`). | Yes. |
| D5 | Number of tour steps | **Welcome, then 5 Explain steps** (4 on a Mac without a battery), numbered "n of m". Trash has no step. | Yes (a Trash step is easy to add). |
| D6 | Ring colour | **System accent** (`Color.accentColor`), like the macOS focus ring. | Yes (monochrome `.primary`). |
| D7 | Existing-user offer | **A "Take the Tour" chip with ✕ in the overview header**, shown on up to **3** opens. | Yes (1 open). |
| D8 | CPU rows show two numbers ("9.8%" and "78% of one core") | **One number per row.** "% of one core" moves to the row tooltip and the right-click menu, where it already appears. The bar gets the full width again. | Yes (this was added on purpose in round 3, so it's the owner's call). |
| D9 | Teaching the hidden actions (expand, right-click Quit) | **A breakdown footnote hint for the first 3 drill-ins**, "Right-click an app to quit it", a tooltip on every app row, and a stronger expand chevron. These are not tour steps. | Yes. |
| D10 | Permission prompts on first launch | **For new users only, defer them** until the welcome card is answered (either button). The card explains both prompts first. Existing users keep today's behaviour. | Yes. |

---

# PART A — Stability (agent 1)

**Goal:** nothing the user reads or points at moves unless the data really changed by a clear amount. The row
under the pointer never changes. An expanded app stays open and stays put. A right-click menu always acts on the
row it was opened on. Accuracy and MacStats's own cost are unchanged (scan cost goes down).

**Read first:** `docs/research/2026-10-06-stability-diagnosis.md`, sections 3, 5, 6, 7 and 8.

**Measured baseline to beat (diagnosis section 4, per minute, busy Mac):**

| Metric | At `1ed61cf` |
|---|---|
| CPU breakdown top-8 order changes | 59 of 59 |
| Row slots showing a different app | 283–320 |
| The expanded app's top-5 child set | 28–41 |
| Row value text changes (top 8) | 364–386 |
| Card text: CPU / network ↓ / memory | 80–91 / 50–103 / 22–30 |

## A1. Pure helpers + tests (no behaviour change yet)

**New file `Sources/MacStatsCore/DisplayHold.swift`:**

```swift
/// The value to show: `shown` (the last shown value, already quantised to `step`) unless `value`
/// moved at least max(band × step, relBand × |shown|) away from it; then `value` quantised to `step`.
/// nil `shown` → quantised `value`. The error is bounded: |result − value| ≤ max(band × step, relBand × |shown|).
public func heldValue(shown: Double?, value: Double, step: Double, band: Double = 0.75,
                      relBand: Double = 0) -> Double

/// Memory card + Memory breakdown header/parts as ONE unit: returns `shown` unchanged while
/// |value.used − shown.used| < `step` (0.1 GiB) and the pressure level is the same. Otherwise it returns `value`.
/// A pressure change always passes at once. Holding the whole sample keeps App + Wired + Compressed adding up to Used.
public func heldMemory(shown: MemorySample?, value: MemorySample, step: UInt64 = 107_374_182) -> MemorySample

/// Network rate hold. Step = the printed precision of the shown unit (1 KB/s, or 0.1 MB/s at
/// ≥ 999.5 KB/s, matching `formattedRate`), band 1.5, relBand 0.15. The KB/s ↔ MB/s switch is held the same way.
public func heldRate(shown: Double?, value: Double) -> Double

/// Battery time left in minutes, held with step = `formatTimeLeft`'s rounding at that length
/// (1 min under 15 min, 5 under 2 h, 15 under 6 h, else 60) and band 0.75.
public func heldTimeLeft(shown: Int?, minutes: Int) -> Int
/// Time to full: falls freely; rises only when `minutes` ≥ shown + 2 (a countdown never ticks up by one).
public func heldTimeToFull(shown: Int?, minutes: Int) -> Int
```

**New file `Sources/MacStatsCore/StableRanking.swift`:**

```swift
/// How strongly a breakdown resists re-ranking (diagnosis section 5.2).
public struct RankHysteresis: Equatable, Sendable {
    public var rel: Double      // relative margin
    public var abs: Double      // absolute margin (metric units)
    public var jump: Double     // a lead this big (and > 2×) moves at once
    public static let cpu    = RankHysteresis(rel: 0.25, abs: 0.3, jump: 2)          // pp of the whole Mac
    public static let memory = RankHysteresis(rel: 0.05, abs: 20 * 1_048_576, jump: 200 * 1_048_576)
    public static let energy = RankHysteresis(rel: 0.25, abs: 0.05, jump: 1)         // W
    public static func `for`(_ metric: BreakdownMetric) -> RankHysteresis
}

/// Re-ranks keys with hysteresis. Starts from `previous`: vanished keys are dropped, and new keys enter at
/// their sorted place (by `now`, ties by today's `ranksBefore` rule). A key climbs past the one above only when
/// min(now, before) of it > max(now, before) of the one above × (1 + rel) + abs, i.e. it leads on both
/// readings. A key that leads by > 2× AND > `jump` on `now` moves at once. `pinned` keys keep their index
/// while the others reorder around them. `frozen` returns `previous` minus vanished keys, plus new keys
/// appended at the end. `groupsLast` (memory) keeps negative keys (group rows) after all apps.
/// One insertion pass, O(n²) on ~60 rows.
public func stableRanking(previous: [Int32], now: [Int32: Double], before: [Int32: Double],
                          rule: RankHysteresis, pinned: Set<Int32> = [], frozen: Bool = false,
                          groupsLast: Bool = false) -> [Int32]
```

**In `Sources/MacStatsCore/SparklineGeometry.swift`, next to `niceUpperBound`:**

```swift
/// A bar scale that grows at once but shrinks only when `peak` falls below `shrinkBelow` of it.
/// Uses `niceUpperBound`'s 1-2-5 ladder, and is never below `minimum`.
public func stickyUpperBound(previous: Double?, peak: Double, shrinkBelow: Double = 0.4,
                             minimum: Double = 0.5) -> Double
```

**New file `Sources/MacStatsCore/BreakdownFormat.swift`.** Move the row text formatting here so the store, the
view and the probe agree on the step:

- `formattedValue` moves out of `BreakdownView.swift` and becomes
  `public func breakdownValueText(_ metric: BreakdownMetric, _ value: Double) -> String`.
  Its output stays the same: CPU `%.1f%%` under 9.95, else `%.0f%%`; memory MB, or GB at ≥ 1024 MB; energy
  `%.2f W` under 1 W, else `formatWatts`.
- `public func breakdownValueStep(_ metric: BreakdownMetric, _ value: Double) -> Double`. The step is the printed
  precision: 0.1 or 1 (CPU); 1 MiB, or 0.1 GiB in bytes (memory); 0.01 or 0.1 W (energy).
- `formatWatts` moves here from `BatteryDetailsCard.swift` and becomes `public`. Its behaviour doesn't change.

**Tests:**
- New `Tests/MacStatsCoreTests/DisplayHoldTests.swift`:
  - wobble across a rounding boundary holds (8.49 ↔ 8.51 with step 1 stays 8)
  - a real move passes
  - the error bound holds over a random walk
  - nil → quantised value
  - relBand
  - memory: used held together with its parts, and a pressure change passes at once
  - rate: unit switch held
  - time left at each step boundary (14/15, 119/120, 359/360 min)
  - time to full falls by 1 but doesn't rise by 1; a rise of 2 passes
- New `Tests/MacStatsCoreTests/StableRankingTests.swift`:
  - no swap within the margin
  - a swap only after two readings
  - the jump rule moves a spike at once
  - new keys enter at their sorted place; vanished keys are removed
  - `pinned` keeps its index
  - `frozen` keeps order and appends new keys
  - `groupsLast` keeps groups last
  - ties are deterministic (by key)
  - empty `previous` = a plain sort
- In `SparklineGeometryTests.swift`: `stickyUpperBound` grows at once, shrinks only below 40 %, and never goes
  below the minimum.
- New `BreakdownFormatTests.swift`: the text is unchanged against today's `formattedValue` cases, and the steps
  match the printed precision.

**Commit:** `core: display holds, stable ranking, sticky scale (pure, tested)`.

## A2. Trailing window in `BreakdownScanner` (diagnosis section 5.1)

- Constants in `Sources/MacStatsCore/RefreshScheduler.swift`, each with a comment citing the diagnosis
  measurements:
  - `breakdownScanInterval` 1.0 → **2.0**
  - new `public let trailingWindowSeconds: TimeInterval = 4.0`
  - keep `breakdownFirstRescanDelay = 0.5`
- `BreakdownScanner.init` gets `windowSeconds: TimeInterval = trailingWindowSeconds`. `0` means only the latest
  interval, which is today's behaviour, so existing `ProcessScanTests` can pass `windowSeconds: 0` where their
  expectations are per interval.
- The scanner keeps a small ring of intervals:
  - `elapsed`
  - the machine's busy ns (`total / 100 × elapsed × cores × 1e9`, or nil when the ticks didn't move)
  - per process keyed by `pid` + `startTime`: owner app, ns after `creditScale`, nJ after `creditScale`
  - the exit credit per app

  It drops intervals that end more than `windowSeconds` before now.
- Each value is computed over the window:
  - **process row** = Σ ns ÷ (Σ elapsed × cores) × 100; watts = Σ nJ ÷ Σ elapsed
  - **header** `totalCPUPercent` = Σ busy ns ÷ (Σ elapsed × cores) × 100. It is nil if any interval in the
    window has no busy figure (same rule as today).
  - **System** stays total − rows (`addingSystemRow`), so rows + System = header still holds exactly.
  - A process that started mid-window counts only what it used (÷ the whole window).
  - A process that exited mid-window: its earlier ns go to its app's "Exited processes" child row while the app
    runs, otherwise they fall into System. This also stops that row blinking.
  - Memory rows stay instantaneous.
- `exitWorkCredit`'s baseline keeps using the **per-interval** System value (`lastSystemPercent` must be computed
  from the latest interval only, not the windowed row).
- Memory cost: the ring is 2–3 dictionaries of about 500 entries (~20–60 KB), only while a breakdown is open.
  It is freed with the scanner on back or close. No new syscalls.
- **Tests (in `ProcessScanTests.swift`):**
  - rows over 2 intervals = Σ ns ÷ (Σ elapsed × cores)
  - the header uses the same window
  - rows + System = header
  - the window trims by time
  - a process starting mid-window
  - an exit mid-window goes to the app's Exited row, or to System if the app is gone
  - the first scans after "Measuring…" use the partial window
  - memory is unaffected
  - `windowSeconds: 0` reproduces today's numbers

**Commit:** `core: 4 s trailing window for breakdown rows and header; scan every 2 s`.

## A3. `MetricsStore`: stable order, freeze, pin, held row values (diagnosis sections 5.2–5.4)

In `Sources/MacStatsCore/MetricsStore.swift` (all main-actor, no timers):

- **Private state:** `order: [Int32]`, `lastValues: [Int32: Double]`, `childOrder: [Int32: [Int32]]`,
  `lastChildValues: [Int32: [Int32: Double]]`, `pointerFrozen`, `menuFrozen`,
  `unfreezeAt: TimeInterval?`, `pinnedApp: Int32?`, and the held row values. All of it is reset in
  `beginBreakdown` and `clearBreakdown`.
- **New public API:**
  - `func setBreakdownPointerInside(_ inside: Bool, time: TimeInterval = now)`
  - `func setBreakdownMenuOpen(_ open: Bool, time: TimeInterval = now)`
  - `func setBreakdownPinnedApp(_ appPID: Int32?)`
  - `func shownValue(app: Int32, pid: Int32? = nil) -> Double?`, the held value for an app row, or for one of its
    process rows. Process keys are `(app, pid)`, because the Exited row's pid `-3` repeats across apps.
  - `@Published private(set) var breakdownOrderRevision: Int`, bumped only when a publish actually changed the
    app order.
  - `@Published private(set) var breakdownEnergyScale: Double`, from `stickyUpperBound` over the top energy row.
  - `@Published private(set) var breakdownShownTotalCPU: Double?`, the header held with `step 1, band 0.75`.
- **Freeze rule:** frozen = pointerInside || menuOpen || (now < unfreezeAt). When both flags clear, set
  `unfreezeAt = time + 1.0`. The freeze ends at the **first `setBreakdown` with time ≥ unfreezeAt**, which is a
  timestamp check, not a timer.
- **`setBreakdown(_ apps:, measuring:, totalCPU:, time: TimeInterval = Date().timeIntervalSinceReferenceDate)`:**
  1. App order = `stableRanking(previous: order, now: values, before: lastValues, rule: .for(metric),
     pinned: pinnedApp.map { [$0] } ?? [], frozen: frozen, groupsLast: metric == .memory)`.
  2. Each app's `processes` are reordered the same way with `childOrder[app]` (frozen too while frozen).
  3. Held values: `heldValue(shown:value:step: breakdownValueStep(...), band: 0.75, relBand: cpu/energy 0.10,
     memory 0.03)` for every app row and every visible child.
  4. Publish `breakdown` in that order. `AppUsage` values stay exact (bars follow them).
- **Tests** (`Tests/MacStatsCoreTests/MetricsStoreBreakdownTests.swift`):
  - the stable order is applied
  - freeze holds the order but updates values, appends new apps and removes quit ones
  - unfreeze happens at the first scan ≥ 1 s after the pointer leaves, not before
  - the menu freeze works the same way
  - the pinned app keeps its index
  - children reorder with hysteresis and freeze
  - the revision bumps only on a real reorder
  - held text values and their bound
  - the energy scale is sticky
  - reset on `beginBreakdown` / `clearBreakdown`

**Commit:** `core: stable breakdown order with freeze/pin and held row values`.

## A4. Card holds + 2 s rate window (diagnosis section 5.4)

- `rateWindowSeconds` 1.0 → **2.0** in `RefreshScheduler.swift`, with an updated comment. The idle path is
  unaffected, because its snapshots are 10 s apart anyway.
- **Store:** new `@Published private(set)` display values, each set **only when it changes** so they don't add
  publishes:
  - `cardCPUPercent: Double` (`heldValue(step 1, band 0.75)`)
  - `cardMemory: MemorySample?` (`heldMemory`)
  - `cardNetwork: NetworkSample?` (`heldRate` per direction)

  The raw `cpuPercent`, `memory` and `network`, the histories and the `Pending` paused path keep exact values,
  so existing tests stay valid. On `resumePublishing`, the card values restart from the latest reading (the hold
  restarts).
- Temperature and battery times are display-only values today, so they are held in place:
  - `setCPUTemperature` holds with `step 1, band 1.0`.
  - `setBattery` replaces `timeToEmptyMinutes` / `timeToFullMinutes` with `heldTimeLeft` / `heldTimeToFull`.
    The hold resets when `state` changes.
- **Tests (in `MetricsStoreTests.swift`):**
  - the card values hold, then pass a real move
  - the raw values and history stay exact
  - the hold restarts after pause/resume
  - temperature holds within 1 °C
  - battery holds reset on a state change

**Commit:** `core: held card values; 2 s CPU/network window`.

## A5. Views

`Sources/MacStatsApp/BreakdownView.swift`:
- `.onHover { store.setBreakdownPointerInside($0) }` on the **list card** (one handler, not one per row).
- Menu tracking, alive only while `BreakdownView` exists:
  `.onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in store.setBreakdownMenuOpen(true) }`,
  and the same for `didEndTrackingNotification` → `false`. This adds no new observer while the popover is
  closed, because the view is gone then (`exitBreakdown` clears the metric).
- `.onChange(of: expanded) { store.setBreakdownPinnedApp($0) }`. When `store.breakdown` no longer contains
  `expanded` (the app quit), set `expanded = nil` and `visibleChildren = BreakdownList.initialChildren`.
- Row text reads `store.shownValue(...)` through `breakdownValueText`. The `.animation(value:)` on the value text
  keys on the **shown** value, so the fade runs only when the text really changes.
  `oneCore(...)` is derived from the shown value (shown × cores), so the two numbers always agree. Part B moves it
  to the tooltip.
- The header uses `store.breakdownShownTotalCPU ?? store.cardCPUPercent`.
- `barScale` for energy = `store.breakdownEnergyScale`.
- `.animation(.snappy(duration: 0.25), value: store.breakdownOrderRevision)` on the `LazyVStack`, so the rare
  real reorders slide instead of teleporting. Nothing moves while frozen.

Other views:
- `OverviewView.swift` reads `cardCPUPercent`, `cardMemory` and `cardNetwork`. The `number:` used for the
  transition must be the held value.
- `MemoryPartsCard.swift` and the Memory breakdown header read `cardMemory`.
- `BatteryDetailsCard.swift` uses the moved `formatWatts`.

**Commit:** `ui: breakdown freezes while pointed at, pins the expanded app, shows held values`.

## A6. Stability probe (reusable, headless) + results

Build it at **`docs/research/2026-10-06-probes/stability/`**:
- `main.swift` runs the **real** `MacStatsCore` pipeline with no window:
  - a copy of `BreakdownScanSession.scan` (`NSWorkspace` running apps → `attributionAnchors`, then
    `readRawProcesses`, then `BreakdownScanner.scan`)
  - into a real `MetricsStore` (`beginBreakdown(.cpu)`, then `setBreakdown`) at the app's cadence: 0.5 s, then
    every `breakdownScanInterval`
  - and the overview path (snapshots + `rateBaselineIndex(window: rateWindowSeconds)` + `store.record`) every 0.5 s
- `run.sh [seconds=90] [app=Code]` compiles with
  `swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -O -o "$OUT/probe" $(ls Sources/MacStatsCore/*.swift | grep -v AppleSensorReader) docs/research/2026-10-06-probes/stability/main.swift`.
  `$OUT` = `${TMPDIR:-/tmp}/macstats-stability-probe`, never in the repo. It runs from the repo root under the
  kill timeout (`sleep seconds+40`).
- **It prints, per minute (one `key=value` line each):**
  - `top8_order_changes`: scans whose published top-8 pid list differs from the previous scan
  - `slot_changes`: Σ over slots 0–7 of "a different pid than last scan"
  - `row_text_changes`: Σ over top-8 apps of `breakdownValueText(shownValue)` changing
  - `target_moves` and `target_child_set_changes`: the app named by the `app` argument, or else the app with the
    most processes. Its top-5 children set is counted with it pinned.
  - `frozen_slot_changes`: during a 20 s window mid-run the probe calls `setBreakdownPointerInside(true)` and
    counts slot changes. Must be 0, apart from apps that quit.
  - `card_cpu_changes`, `card_net_down_changes`, `card_mem_changes`: changes of the held card values
  - `scan_ms_mean` / `scan_ms_max`, and `process_cpu_pct` (`getrusage` user+sys ÷ wall time)
  - `max_sum_gap_pp`: |Σ shown rows + System − shown header|
  - `whole_mac_cpu_mean`, so a reader can judge how busy the Mac was
- Commit `main.swift`, `run.sh` (executable) and a `README.md` (what each number means, the command, and the
  baseline table above). Save a sample output as `results-<date>.txt`.

**Acceptance (run twice, 90 s each; the Mac may be busy, so state its mean CPU):**

| Metric (per min) | Must be |
|---|---|
| `top8_order_changes` | ≤ 15 |
| `slot_changes` | ≤ 40 |
| `target_child_set_changes` | ≤ 2 |
| `frozen_slot_changes` | 0 |
| `row_text_changes` | ≤ 130 |
| `card_cpu_changes` / `card_net_down_changes` / `card_mem_changes` | ≤ 75 / ≤ 30 / ≤ 16 |
| `scan_ms_mean` × scans per s | ≤ the `1ed61cf` figure (4.2–5.5 ms × 1/s), i.e. ≤ ~3 ms/s |
| `max_sum_gap_pp` | ≤ 2 |

**Accuracy spot-check (once):** `top -l 3 -s 2 -o cpu -stats pid,command,cpu | tail -25` during a probe run.
The probe's windowed row for the target app × cores should be within the noise of `top`'s figure for its main
process family. Write the numbers in the README.

**Commit:** `docs: headless stability probe + results`. Then update the progress note and add a Status bullet to
`CLAUDE.md` ("Stability fixes (2026-10-06, branch `feat/stability-tour`)" with the probe numbers).

## Part A definition of done
- [ ] A1–A6 committed. `./Scripts/test.sh` is green (255 + new tests). `swift build` is green.
- [ ] Probe acceptance met. Results are in the probe README and the progress note.
- [ ] `git diff 1ed61cf -- Sources | grep -nE "Timer|asyncAfter|addObserver|DispatchSource|onReceive"` shows only
      the `NSMenu` tracking `onReceive` in `BreakdownView` (alive only while a breakdown is shown).
- [ ] No closed-popover code path changed apart from constants (`rateWindowSeconds` has no effect at the 10 s
      idle spacing).
- [ ] Progress note: Part A ticked, the next step is "Part B, task B1".

---

# PART B — Intuitiveness + intro + guided tour (agent 2, after Part A)

**Goal:** a first-time user understands MacStats in about 30 s:
- where it lives
- why macOS is about to ask for permissions
- what each card is
- how to drill in and quit apps

Copy is clearer and the layout is evenly aligned. There is an optional, skippable, numbered tour inside the panel,
whose spotlight is a squircle that sits **exactly centred** around each card. It can be replayed any time and
costs nothing when not shown.

**Read first:**
- `docs/research/2026-10-06-tour-design.md`, Parts B, C and D. That is the design; this plan pins the decisions.
- `docs/research/2026-10-06-ux-psychology.md`, Part 2 (the audit) and Part 3 items 2–8.

**Do not use** sheets, popovers, `.alert`, `.confirmationDialog`, `NSAlert`, new windows or `NSApp.activate` for
the tour or the intro. The `MenuBarExtra` panel closes when it loses focus (tour doc, Part C).

## B1. Pure tour model + layout + tests (`MacStatsCore`)

**New file `Sources/MacStatsCore/Tour.swift`** (no SwiftUI):

```swift
public enum TourStepID: String, CaseIterable, Sendable { case cpu, memory, network, battery, footer }
public struct TourStep: Equatable, Sendable {
    public let id: TourStepID; public let anchor: String   // "overview.cpu" …
    public let title: String; public let body: String; public let requiresBattery: Bool
}
public enum TourCatalog {
    public static let version = 1
    public static let steps: [TourStep]            // exact copy below
    // Welcome / chip / button strings as static lets (exact copy below), so the lint test covers them.
}
public enum TourEffect: Equatable, Sendable { case show(Int), finished, paused(Int), none }
public struct TourState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case off, welcome, step(Int) }
    public private(set) var phase: Phase = .off
    public private(set) var interruptions = 0
    public mutating func showWelcome()
    public mutating func start(at index: Int = 0, isPresent: (TourStep) -> Bool) -> TourEffect   // first presentable ≥ index
    public mutating func next(isPresent:) -> TourEffect     // .show(i) or .finished
    public mutating func back(isPresent:) -> TourEffect     // previous presentable; .none on the first
    public mutating func skip() -> TourEffect               // .finished
    public mutating func panelClosed() -> TourEffect        // 1st close: .paused(i) (welcome: ask again); 2nd: .finished
    public func progress(isPresent:) -> (number: Int, total: Int)?   // over presentable steps only
}
public enum TourAudience: String, Sendable { case new, existing
    /// existing if any key outside `TourKey.all` is in the app's own defaults domain, or bundleID != "com.macstats.MacStats".
    public static func classify(domainKeys: Set<String>, bundleID: String?) -> TourAudience
}
public enum TourRules {
    public static func shouldShowWelcome(audience: TourAudience, seenVersion: Int?, answered: Bool) -> Bool
    public static func shouldOfferTour(audience: TourAudience, seenVersion: Int?, offerShows: Int, dismissed: Bool) -> Bool  // existing, unseen, < 3, !dismissed
    public static func deferPermissionPrompts(audience: TourAudience, seenVersion: Int?) -> Bool         // new && seenVersion == nil
    public static func showsBreakdownHint(shows: Int) -> Bool                                            // shows < 3
}
public enum TourKey {   // the ONLY keys the tour writes
    public static let audience = "tourAudience"             // "new" | "existing"
    public static let seenVersion = "tourSeenVersion"       // Int: Done, Skip, No Thanks, or the 2nd close
    public static let resumeStep = "tourResumeStep"         // Int, while paused by a panel close
    public static let interruptions = "tourInterruptions"   // Int 0/1 in this run
    public static let offerShows = "tourOfferShows"         // Int: existing-user chip appearances
    public static let offerDismissed = "tourOfferDismissed" // Bool
    public static let breakdownHintShows = "breakdownHintShows" // Int: drill-ins that showed the quit hint
    public static let all: Set<String>
}
```

**New file `Sources/MacStatsCore/TourLayout.swift`** (CoreGraphics only):

```swift
public enum TourLayout {
    public static let cutoutInset: CGFloat = 3        // = Design.cardSpacing / 2 (D3)
    public static let ringWidth: CGFloat = 2
    public static let calloutGap: CGFloat = 6, panelMargin: CGFloat = 8, calloutRadius: CGFloat = 8
    /// target outset by `inset` on every side; each EDGE (minX, minY, maxX, maxY) rounded to 1/scale
    /// (not origin + size), clamped inside `panel`; radius = targetRadius + inset.
    public static func cutout(target: CGRect, targetRadius: CGFloat, panel: CGRect, scale: CGFloat,
                              inset: CGFloat = cutoutInset) -> (rect: CGRect, radius: CGFloat)
    /// Width = panel.width − 2 × margin (304), x = margin. Below the cutout if it fits inside panel − margin,
    /// else above, else the side with more room (clamped). Never intersects the cutout. Edges pixel-rounded.
    public static func callout(cutout: CGRect, height: CGFloat, panel: CGRect, scale: CGFloat) -> CGRect
    /// The welcome card: same width, centred on both axes, pixel-rounded.
    public static func welcome(height: CGFloat, panel: CGRect, scale: CGFloat) -> CGRect
}
```

**Tests** (in `Tests/MacStatsCoreTests/`):
- `TourStateTests`:
  - the full path: welcome → start → steps 0…4 → Done means finished
  - Back at step 0 does nothing; Back skips the missing Battery step
  - Skip from any step means finished
  - `panelClosed`: the 1st close pauses at the same step, the 2nd close finishes; on the welcome card the 1st
    close asks again and the 2nd counts as No Thanks
  - progress reads 1…5 of 5 with a battery and 1…4 of 4 without one, with no skipped numbers
- `TourRulesTests`:
  - classify: an empty domain is new; a domain with only tour keys is new; `didRegisterLoginItem` is existing;
    `NSStatusItem VisibleCC Item-0` is existing; any `battery*` key is existing; `uiOpacity` is existing; a nil
    or other bundle id is existing
  - `shouldShowWelcome` is true only for an unanswered new user
  - `shouldOfferTour`: a version bump re-offers; dismissed means never; 3 shows means never
  - `deferPermissionPrompts`
  - `showsBreakdownHint`
- `TourLayoutTests`:
  - the four cutout margins are equal for fractional inputs at scale 1, 2 and 3, to within 1/scale
  - every edge sits on the pixel grid
  - radius = target radius + 3
  - for full-width cards, radius + gap to the panel edge = 16
  - the cutout stays inside the panel
  - the callout never intersects the cutout, is 6 pt from it and lies inside panel − 8
  - CPU, Memory and Network place the callout below; Battery and Footer place it above (use the fixtures from
    the B6 probe; until then, rects computed from the layout constants)
  - the fallback when neither side fits
  - the welcome card is centred
- `TourCatalogLintTests`:
  - titles ≤ 4 words; bodies ≤ 20 words in 1–2 sentences
  - no straight `'` in any user-facing tour string
  - step titles are unique
  - anchors match `overview.<id>`
  - button labels are Title Case
  - no digits followed by `%` or `GB`
  - fit: with `import AppKit` in the test, each body measured with
    `NSFont.preferredFont(forTextStyle: .callout)` at 280 pt width takes ≤ 2 lines

**Commit:** `core: tour state, rules, keys and layout (pure, tested)`.

## B2. Copy, affordance and layout fixes (UX doc Part 3 items 3–7)

Exact strings (`’` is the typographic apostrophe):

| Where (file) | Now | New |
|---|---|---|
| CPU card meta, no sensor (`OverviewView.cpuMeta`) | `live` | `""` (empty; the line keeps its height) |
| CPU card meta, temperature | `47°C` | `47 °C` (same format as Battery's `31 °C`) |
| Memory card meta | `normal` / `warning` / `critical` | `pressure normal` / `pressure high` / `pressure critical` |
| Network card | no tooltip | `.help("↓ download and ↑ upload speed, right now")` on the card |
| Trash value, 0 bytes | `empty` | `Nothing in it` (Empty stays, disabled) |
| Trash, Finder permission refused | `—` + disabled Empty | value `Needs permission`, button `Allow…` that opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation` |
| Footer button (`PanelFooter`) | `Quit` | `Quit MacStats` |
| CPU footnote | `Share of the whole Mac (all N cores)` | unchanged |
| Memory footnote | `Rows are each app's footprint (as in Activity Monitor); they don't add up to Memory Used` | `Each app’s memory, as in Activity Monitor` (1 line), with `.help("Compressed memory counts at full size here, and macOS’s own processes aren’t listed, so the rows don’t add up to the total above.")` |
| Battery footnote | `App power counts CPU only` | `App power: CPU only, not screen or GPU` |
| Quit hint footnote (first 3 drill-ins, `TourRules.showsBreakdownHint`) | — | `Right-click an app to quit it` |
| App row tooltip (real apps, all metrics) | CPU: `N% of one core` only | multi-process: `Click to show its N processes · Right-click to quit`; single process: `Right-click to quit`. On CPU, add a line: `N% of one core` |
| CPU app/process rows | visible `N% of one core` column (88 pt) | removed (D8); the bar takes the full width like Memory/Battery |
| App row expand chevron | `.tertiary` | `.secondary` |
| `System` tooltip | 30 words | `macOS itself: the kernel, WindowServer and other system work` |
| `Other processes` tooltip | `Your background processes that no app is responsible for` | `Background tasks that don’t belong to an open app` |
| `App Memory` / `Wired` / `Compressed` tooltips | technical | `Memory apps and macOS are using right now` / `Memory macOS keeps for itself. It can’t be freed.` / `X GB of app data squeezed into less RAM to make room. Normal, not a problem.` (no-data variant: `App data squeezed into less RAM to make room. Normal, not a problem.`) |
| Measuring sub-line | `Sampling CPU usage` / `Sampling energy use` | `Takes about a second` |
| Empty list | `No apps` | `Nothing to show yet` |
| Battery row `Power, last min` | — | `Power now`, `.help("Average over the last minute")` |
| Battery rows `Avg awake since unplugged` / `Avg awake since MacStats started` | — | `Average since unplugged` / `Average this session`, `.help("Counts only time the Mac was awake")` |
| Battery details `Time left` value | `4h` | `About 4h` (prefix `About ` unless `formatTimeLeft` already starts with `about`, then capitalise it). The card meta stays `4h left`. |

Layout and affordance:
- Gear: `SubtleButtonStyle(cornerRadius: Design.cardCornerRadius)` (8 pt, concentric with the panel corner, same
  as Quit).
- Breakdown footnote: `.padding(.trailing, Design.cardPadding - Design.panelInset)` (4 pt), so its right edge
  lines up with the header's trailing text.
- **Esc goes back** from a breakdown and from Settings: `.keyboardShortcut(.cancelAction)` on both back buttons.
- `BatteryDetailsCard` rows become `(label, value, help: String?)`.
- **Every footnote must render on one line, untruncated**, beside `Quit MacStats` at a 0.8 minimum scale.
  Check it in the B6 probe; if one doesn't fit, shorten it and record the new string here and in the
  progress note.

**Trash permission state:**
- `TrashActions.trashSize()` returns `enum TrashReading { case bytes(UInt64), notPermitted, unavailable }`
  (`notPermitted` = AppleScript error -1743).
- Store: `setTrashBytes(_:)` stays, plus `@Published private(set) var trashNeedsPermission = false` with a setter.
  Tested in `MetricsStoreTests`.

**Commit(s):** `ui: clearer copy, one number per CPU row, visible hints, concentric gear` and
`ui: Trash row explains a missing Finder permission`.

## B3. `TourController`, audience, deferred permissions, reopen

New file **`Sources/MacStatsApp/TourController.swift`**: `@MainActor final class TourController: ObservableObject`.
- `init(defaults: UserDefaults = .standard, hasBattery: @escaping () -> Bool)`. Tests and probes always pass
  `UserDefaults(suiteName: "MacStatsTourProbe-<uuid>")` and remove it afterwards. **Never write to the real
  `com.macstats.MacStats` domain from a probe.**
- `@Published private(set) var state: TourState` and `var isActive: Bool` (phase != .off).
- `@Published private(set) var offersTour: Bool`, the existing-user chip.
- `func panelOpened()`:
  - reads 4–5 keys
  - resumes a paused step (`tourResumeStep`), or shows the welcome when `shouldShowWelcome`
  - computes `offersTour`; if it is true, increments `tourOfferShows` once per open
- `func panelClosed()` → `state.panelClosed()`, then persists `resumeStep` / `interruptions`, or marks the tour
  seen.
- `start()`, `next()`, `back()`, `skip()`, `noThanks()`, `dismissOffer()`.
  - Finishing (Done, Skip, No Thanks, or the 2nd close) sets `tourSeenVersion = TourCatalog.version`.
  - The first finish of the welcome flow also calls `onIntroFinished` (below).
- `func breakdownOpened() -> Bool`: returns whether to show the quit hint, and increments `breakdownHintShows`
  while it is < 3.
- VoiceOver: on each `.show(i)` it posts
  `AccessibilityNotification.Announcement("\(title). \(body) Step \(n) of \(m).").post()`.

Audience and permission wiring:
- `MacStatsApp.init()` (`MacStatsMain.swift`): **before `AppModel()`**, classify the audience:

  ```swift
  TourController.classifyAudienceIfNeeded(
      domainKeys: Set(UserDefaults.standard.persistentDomain(forName: "com.macstats.MacStats")?.keys ?? []),
      bundleID: Bundle.main.bundleIdentifier)
  ```

  It writes `tourAudience` once. Classifying any later would call everyone existing, because `AppModel.init`
  writes `didRegisterLoginItem`. The owner's domain has non-tour keys, so he is `existing`.
- `AppModel` owns `let tour: TourController`. If `TourRules.deferPermissionPrompts` is true:
  - `init` skips `notifier.requestAuthorization()`
  - `setVisibility(.popoverOpen)` skips `refreshTrashSize()`
  - `tour.onIntroFinished = { [weak self] in self?.notifier.requestAuthorization(); self?.refreshTrashSize() }`
    fires both prompts right after the user has read why (D10)

  Existing users: no change.
- **Reopen and first launch (D4):**
  - Add `static func openPanel()` to `StatusItemHover`: it calls `button?.performClick(nil)` if the button was
    found, and otherwise does nothing.
  - Add a tiny `AppDelegate: NSObject, NSApplicationDelegate` via `@NSApplicationDelegateAdaptor` with
    `applicationShouldHandleReopen(_:hasVisibleWindows:)` → `StatusItemHover.openPanel(); return false`.
  - In `MacStatsApp.init`, when `shouldShowWelcome` holds (new, unanswered), call
    `DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { StatusItemHover.openPanel() }` once. That is a
    one-shot at launch, after the button attaches at 0.5 s and 2.0 s, and only for new users.
  - **Agents must not trigger either path live.** These are owner manual checks.
- RootView:
  - `.onAppear` → `model.tour.panelOpened()` (after `setVisibility`)
  - `.onDisappear` → `model.tour.panelClosed()`
  - Starting the tour sets `showingSettings = false` and calls `model.exitBreakdown()`
  - `RootView` observes `model.tour` with `@ObservedObject var tour: TourController` (passed in from
    `MacStatsApp`), so `OverviewView` never observes it and card ticks never re-run tour logic.

**Commit:** `app: tour controller, audience at first launch, permission prompts after the intro, reopen opens the panel`.

## B4. Anchors, overlay, callout, welcome card, chip, `?`, Settings Help

New file **`Sources/MacStatsApp/TourOverlay.swift`**:
- `struct TourAnchor: Equatable { let bounds: Anchor<CGRect>; let radius: CGFloat }`, and
  `TourAnchorKey: PreferenceKey` with `[String: TourAnchor]` values (dictionaries merge).
- `.tourAnchor(_ id: String, radius: CGFloat)` modifier. It reads `@Environment(\.tourActive)` and attaches
  `.anchorPreference` **only while the tour is active**, so the preference is empty and constant when the tour
  is off: zero cost.
  - Apply it in `OverviewView` **outside** each `StatCard` (not inside `CardButtonStyle`, so the press
    `scaleEffect(0.985)` never moves the rect): `overview.cpu`, `overview.memory`, `overview.network`,
    `overview.battery`, radius `Design.cardCornerRadius`.
  - Apply it around the footer's trailing `HStack { HelpButton; SettingsButton }` as `overview.footer`, radius
    `Design.cardCornerRadius`.
- In `RootView`, on the fixed 320 × 404 frame and inside `.clipped()`:
  `.overlayPreferenceValue(TourAnchorKey.self) { anchors in if tour.isActive { TourOverlay(tour:, anchors:) } }`,
  plus `.environment(\.tourActive, tour.isActive)`.
  - It is shown only while the overview is the current screen. A replay from Settings starts in the completion of
    `withAnimation(.snappy(duration: 0.3)) { showingSettings = false } completion: { tour.start() }`.
- **`TourOverlay`:**
  - `GeometryReader { proxy in … proxy[anchor.bounds] … }`. The rect is already in panel coordinates.
  - **Dim:** `TourDimShape` = panel `RoundedRectangle(16, .continuous)` plus the cutout
    `RoundedRectangle(radius, .continuous)`, filled with `FillStyle(eoFill: true)`. Colour `Color.black` at
    0.25 in light and 0.40 in dark. `animatableData` = the cutout's (minX, minY, width, height).
    `.contentShape(Rectangle())`, so it swallows clicks and hover underneath (no card highlights under the dim).
  - **Ring:** `RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)`
    on the cutout rect. With Increase Contrast it is 3 pt wide.
  - Geometry comes only from `TourLayout.cutout(target:targetRadius:panel:scale:)` with
    `@Environment(\.displayScale)`. Card 8, cutout 11 and panel 16 are concentric.
  - **Callout:**
    - Width 304 at x = 8, radius 8 continuous, `.regularMaterial`. With Reduce Transparency it uses
      `Color(nsColor: .windowBackgroundColor).opacity(0.92)` instead.
    - Hairline `Design.cardHairline` and shadow `radius 12, y 4, black 0.18`. It never reads `uiOpacity`.
    - Content: title `.headline`; body `.callout`, `lineLimit(2)`; footer row
      `n of m` (`.caption`, `.secondary`, `monospacedDigit`) · Spacer · `Skip Tour` (plain, secondary, hidden on
      the last step) · `Back` (`SubtleButtonStyle(cornerRadius: 6)`, hidden on the first presentable step) ·
      `Next` / `Done` (`.borderedProminent`, `.controlSize(.small)`).
    - Height is measured (background `GeometryReader` + preference, opacity 0 until measured). The frame comes
      from `TourLayout.callout(cutout:height:panel:scale:)`.
    - `.accessibilityElement(children: .contain)`. The overlay root has `.accessibilityAddTraits(.isModal)`.
  - **Keys:**
    - Next/Done/Show Me Around: `.keyboardShortcut(.defaultAction)` (Return)
    - Skip Tour/No Thanks: `.keyboardShortcut(.cancelAction)` (Esc)
    - Two zero-size buttons, `.frame(width: 0, height: 0).opacity(0)` (not `.hidden()`), carry
      `.keyboardShortcut(.rightArrow, modifiers: [])` → Next and `.leftArrow` → Back
  - **Motion:** step changes animate with `.snappy(duration: 0.3)`, and the overlay fades in and out over 0.2 s.
    With `accessibilityReduceMotion`, there is a 0.15 s cross-fade and no movement. Nothing loops or pulses.
- **`WelcomeCard`** (phase `.welcome`, dim with no cutout, `TourLayout.welcome`):
  - The `MenuBarLabel` sparkline glyph as a template image, about 36 pt.
  - The title, body, two permission lines (only when `deferPermissionPrompts`), divider, question and sub-line,
    and the buttons `No Thanks` and `Show Me Around` (prominent, default).
- **`TourOfferChip`** in the overview `PanelHeader` trailing slot, only when `tour.offersTour`:
  `Button("Take the Tour")` in `SubtleButtonStyle(cornerRadius: 6)` plus a ✕ button
  (`Image(systemName: "xmark")`, `.accessibilityLabel("Dismiss")`). It must not move anything else in the
  header.
- **`HelpButton`** in the overview footer, left of the gear: `Image(systemName: "questionmark")`,
  `SubtleButtonStyle(cornerRadius: Design.cardCornerRadius)`, `.help("Take the Tour")`,
  `.accessibilityLabel("Take the Tour")`. It starts at step 1.
- **Settings → `HelpCard`**, below `AppearanceCard` and in the same card style:
  - section title `HELP`
  - a row with `Guided tour` on the left and the button `Take the Tour` (`SubtleButtonStyle()`) on the right
  - the caption `A short look at what each card shows and where things are.`

**Exact copy** (put in `TourCatalog`; the lint test checks it):

| Item | Text |
|---|---|
| Welcome title | `Welcome to MacStats` |
| Welcome body | `Your Mac’s CPU, memory, network and battery, live, from this graph icon in your menu bar.` |
| Permission line 1 (bell) | `MacStats will ask to send alerts when your Mac stays busy or runs low on memory.` |
| Permission line 2 (trash) | `macOS will ask to let MacStats use Finder, so it can show and empty the Trash.` |
| Question / sub-line | `Want a quick tour?` / `A few short stops. You can skip any time.` |
| Buttons | `No Thanks` · `Show Me Around` · `Skip Tour` · `Back` · `Next` · `Done` · `Take the Tour` |
| Step 1 `overview.cpu` | **How hard it’s working**: `The big number is right now; the graph is the last minute. Click the card to see which apps.` |
| Step 2 `overview.memory` | **Memory in use**: `How much memory apps are using. The dot turns yellow or red when your Mac runs short.` |
| Step 3 `overview.network` | **Internet speed**: `↓ is download and ↑ is upload, right now. The graph shows downloads over the last minute.` |
| Step 4 `overview.battery` (`requiresBattery`) | **Battery and time left**: `Charge and a steady estimate of time left. Click for battery health and which apps use power.` |
| Step 5 `overview.footer` (last: Done) | **Settings and help**: `The gear holds Settings. Click ? any time to see this tour again.` |

**Commit(s):** `ui: tour overlay with centred squircle spotlight and callout`, then
`ui: welcome card, tour offer chip, ? button and Settings Help`.

## B5. Render probe: every step, light + dark, measured insets

Build it at **`docs/research/2026-10-06-probes/tour-render/`**:
- `Package.swift`: an executable target `Probe`, plus `MacStatsCore` and `CAppleSensors` targets (copy the shape
  of `docs/research/2026-10-06-ux-audit/probe-Package.swift`).
- `main.swift`, and `run.sh`, which:
  1. makes `$B=${TMPDIR:-/tmp}/macstats-tour-probe`, then copies `Sources/MacStatsCore`, `Sources/CAppleSensors`
     and `Sources/MacStatsApp/*.swift` **except `MacStatsMain.swift`** (the `@main`) into `$B/Sources/...`, plus
     this `main.swift`, so the probe always renders the current code
  2. runs `swift build` there with the pinned `SDKROOT`
  3. runs the probe under the kill timeout with the output directory `docs/research/2026-10-06-probes/tour-render/out`
- The probe hosts `OverviewView` with a fixed `MetricsStore` (fake samples as in the audit probe) and the same
  overlay composition as `RootView`. Put that composition in one shared modifier, e.g. `.tourHost(tour)`, so the
  probe and `RootView` use identical code.
  - It uses a `TourController` on a `UserDefaults(suiteName:)` suite.
  - Backdrop: `NSVisualEffectView(.popover)`. Window level `desktopWindow + 1`, `orderBack(nil)`, and
    `NSApp.appearance` set to `.aqua` or `.darkAqua`.
- **Captures** (PNG, 2×): `welcome-{light,dark}`, `step{1..5}-{light,dark}`, `step1-opacity{0,1}-{light,dark}`,
  `nobattery-step4-{light,dark}` (shows Footer as "4 of 4"), `chip-{light,dark}`, `settings-help-{light,dark}`,
  `breakdown-hint-cpu-light`, `breakdown-memory-light` (the one-line footnote).
- **Centring measurement:** for each step capture, render once with the tour and once without (static data, so
  every pixel matches). Then:
  - On the row through the target's vertical centre and the column through its horizontal centre, walk outward
    from the card edge (known from the resolved anchor rect × scale) to the first pixel that differs. That is the
    ring's inner edge.
  - Then walk to the outer edge of the accent-coloured run (the ring's outer edge = the cutout edge).
  - Print one line per capture:
    `step=cpu dark inner(px) L=2 R=2 T=2 B=2 outer(px) L=6 R=6 T=6 B=6 cutout=(x,y,w,h)pt radius=11 callout=(x,y,w,h)pt placement=below`
    to stdout and to `out/insets.txt`.
- **Acceptance:**
  - On every step, light and dark: |L − R| ≤ 1 px and |T − B| ≤ 1 px, for both inner and outer, and outer =
    3 pt ± 1 px.
  - The callout never overlaps the cutout.
  - Each body fits 2 lines.
  - No footnote is truncated.
  - Look at every image (the Read tool shows PNGs).
- Copy the printed rects into `TourLayoutTests` as fixtures.
- Commit `Package.swift`, `main.swift`, `run.sh`, a `README.md`, `out/insets.txt` and a lean image set (≤ 5 MB).
  Don't commit `.build/` (already ignored).

**Commit:** `docs: off-screen tour render probe, captures and measured insets`.

## B6. Cost check + docs

- **Static cost check:** `git diff <Part A head> -- Sources | grep -nE "Timer|asyncAfter|addObserver|DispatchSource|onReceive|NotificationCenter"`.
  The only allowed hits are:
  - the one-shot first-launch `asyncAfter` (new users only)
  - the `AppDelegate` reopen method (event-driven, not polling)

  Then confirm, and write in the progress note:
  - `TourOverlay` exists only `if tour.isActive`
  - anchors emit only while active
  - `OverviewView` doesn't observe `TourController`
  - `panelOpened()` does at most 5 `UserDefaults` reads, and writes only when the chip shows (≤ 3 times ever)
    or the state changes
- **Runtime cost (render probe):** host the overview with 0.5 s `store.record` ticks for 20 s with the tour off,
  then 20 s with it on step 1, and print the process CPU (`getrusage`) for each. Tour off must match a run with
  the tour code compiled out within noise. Simplest version: a `--no-tour` flag that skips `.tourHost`.
- Tests are green (`./Scripts/test.sh`) and `swift build` is green.
- Update `CLAUDE.md` Status with a bullet "Guided tour + clarity pass (2026-10-06, branch `feat/stability-tour`)"
  covering: what was built, the probe paths, the persistence keys and the owner manual checks. Update the
  progress note.

## Part B definition of done
- [ ] B1–B6 committed. Tests and build are green.
- [ ] The render probe shows equal insets (≤ 1 px) on every step in light and dark. `out/insets.txt` is committed.
- [ ] The copy lint and fit tests pass. Every footnote is one line.
- [ ] No cost when not shown (static + runtime checks written in the progress note).
- [ ] The owner manual-check list is in the progress note (below).

---

## Owner manual checks (agents can't do these without driving the real menu bar)

These need the bundled app (`./Scripts/bundle.sh`, which the owner runs or OKs):
1. Esc on a tour step skips the tour and doesn't close the panel. If it closes the panel instead, it counts as a
   pause. Fallback: `.onExitCommand` on the overlay.
2. Esc in a breakdown or in Settings goes back.
3. Return/→ = Next, ← = Back.
4. Relaunching MacStats from Spotlight while it runs opens its panel.
5. New-user flow:
   1. `defaults export com.macstats.MacStats ~/macstats-defaults-backup.plist` (back up first; the owner's call)
   2. `defaults delete com.macstats.MacStats`
   3. relaunch: the panel opens with the welcome card, and both prompts appear only after an answer
   4. restore with `defaults import com.macstats.MacStats ~/macstats-defaults-backup.plist`
6. Closed-popover CPU and footprint vs v1.1.0, measured the way
   `docs/reviews/2026-10-05-readings-accuracy/round3-*/overhead-closed.txt` did (`top -l 2 -s 5 -pid <pid>`,
   `footprint <pid>`).

## After both parts (orchestrator, not a build part)
Run the `/reviewer` skill on the stability and the tour/clarity work. The owner's scale: 8–10 = basically perfect,
and the target is > 9. Reviewers use the two probes for evidence. Fix, then re-review until above 9. Then do the
final verification (tests, build, probes, cost) and update the docs.
