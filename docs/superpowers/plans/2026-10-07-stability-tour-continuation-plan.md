# Stability + tour: continuation plan (consolidation, then the review loop)

**Written:** 2026-10-07. **For:** a fresh Claude session with zero context. **Repo:**
`/Users/davidghermansteinberg/Desktop/Home/Projects/Code/Mac Apps/MacStats` (MacStats, a native Swift macOS menu-bar system
monitor; read its `CLAUDE.md` first for the build/test/SDK notes). **Branch:** `feat/stability-tour` (pushed to
GitHub as a branch; not merged, not released). **Baseline** (the commit before this work): `1ed61cf`.

This plan picks up a paused multi-agent job. Its goal: fix jumpy numbers and rows, make the app more intuitive, add
a squircle guided tour, and keep improving until **two independent reviewers both score it above 9.0 overall with no
area below 8.5**. Five review rounds ran; scores rose from 7.3 to about 8.2 and then stalled. This plan diagnoses
the stall, lists every open finding, and orders the work: a **consolidation** pass first, then the review loop.

---

## 0. Terms (read first)

| Term | Meaning |
|---|---|
| **Overview / card** | The popover's main screen: four cards (CPU, Memory, Network, Battery), each with a number and a sparkline. |
| **Breakdown** | The screen you get by clicking the CPU, Memory or Battery card: a ranked list of apps. |
| **Expand / expanded app** | Clicking an app row with several processes shows its **process rows** (children) under it. |
| **Group rows** | Synthetic rows: **System** (kernel + work not owned by an app), **Other processes** (macOS helpers and background tasks), **Finished processes** (work of processes of an app that exited during the averaging window). |
| **Scan** | One per-process read for an open breakdown, every 2 s (`breakdownScanInterval`). |
| **Window** | The span a row's number is averaged over (CPU 8 s, Battery energy 16 s; Memory is instantaneous). |
| **Fast attack / fast release** | The window restarts when one app used ≥ ¾ of a core more (attack) or less (release) over the latest scan than over the rest of the window, so loads that start or end show within ~2 s. |
| **Printed value / exact value** | The number on screen (held, changes only past a band) vs the measured number (drives the bar). |
| **Hold / hysteresis** | A change is ignored unless it exceeds a margin. Used for printed values and for order. |
| **Dwell** | Minimum time between two changes (e.g. the list reorders at most once per 5 s). |
| **Inversion** | A row printed higher than the row above it (the list is briefly out of order). |
| **Inversion timeout** | Current rule: an inversion that lasts one scan is fixed on the next allowed scan, margins or not. |
| **Promotion floor** | Current rule: process rows printed under 0.5 % (0.05 W) pass a neighbour only by the margins. |
| **Freeze / partial freeze** | Freeze = the order is not changed by a scan while the pointer is over the list (or a right-click menu is open). Partial freeze = with the pointer on app K, only rows from the top down to K keep their places; rows below still re-rank (never past K). |
| **Unfreeze delay** | The freeze ends at the first scan ≥ 1 s after the pointer leaves or the menu closes. |
| **Ended placeholder** | While frozen, an app/process that exited stays as a dimmed "Ended" row so nothing shifts. |
| **macOS agent** | A running "app" that is part of macOS (not a regular Dock app, installed under `/System/` or `/usr/` but not `/usr/local/`: loginwindow, Dock, WindowManager…). Its processes go to "Other processes". |
| **Tour / spotlight / cutout / hole / callout** | The in-panel guided tour: a dim layer with a squircle **cutout** (the "hole") around the target card, and a **callout** (text bubble with Back / Next / Skip). |
| **Squircle / continuous corners / concentric** | Apple's smooth rounded rectangle (`RoundedRectangle(style: .continuous)`); concentric = an outer radius equals the inner radius plus the gap (card 8 pt, cutout 11 pt, panel 16 pt). |
| **Inset** | Gap between the card and the cutout edge; measured 3.0 pt on all four sides. |
| **pp** | Percentage points of the whole Mac's CPU. |
| **Probe** | A small headless SwiftPM/swiftc program under `docs/research/2026-10-06-probes/` that runs the real MacStatsCore code (or renders the real SwiftUI views in an off-screen window) and prints measures. |
| **Record / replay** | `record.swift` saves 300 s of real per-process scans to JSON; `replay.swift` runs them through the real display code and prints order changes, inversions, rise/fall times. Lets two code versions be compared on identical input. |
| **Reviewer A / B** | Two independent reviewer agents per round, following `~/.claude/skills/reviewer/SKILL.md`. They write `docs/reviews/2026-10-06-stability-tour-review-r<N>-<A|B>.md`. Finding IDs (S1, I2, …) are per report: S = stability, I = interaction, D/U = discoverability, T = text, V = visual, TR = tour, C = code, R/P = resource. |
| **The bar** | Both reviewers' overall > 9.0 **and** every area of both ≥ 8.5. |
| **Owner** | The repo's owner (the human user). |

---

## 1. Where things stand

### 1.1 Git and install state
- Branch `feat/stability-tour`. Last commits: `ac7ea54` (docs: pause the loop), `95d0990` (docs: review round 5),
  `5b8306a` (round-5 probes), `a3abcc7` (Finished processes always last). Working tree clean at writing time.
- `./Scripts/test.sh`: **373 tests in 46 suites pass** (255 at the baseline `1ed61cf`).
- At pause, HEAD was installed with `./Scripts/bundle.sh` into `~/Applications/MacStats.app` and relaunched with
  `open -g`. Measured: **closed-panel idle 0.0 % CPU, phys_footprint 13 MB** (`footprint <pid>`). This closes the
  "install HEAD and confirm closed-panel CPU" finding that every round raised (r1 B, r2 B P1, r3–r5 A R1).
- Round 6 was interrupted: reviewer A died when the Mac slept (API error at 05:24). Reviewer B finished:
  `docs/reviews/2026-10-06-stability-tour-review-r6-B.md`, **8.4/10** (committed). With only one report, round 6
  does not count as a passed or failed round. **No round-6 fixes were made**; r6-B's findings are in section 2.9
  and feed the consolidation.

### 1.2 Score history (owner's 1–10 scale)

Areas: **Stab** = stability of numbers & lists, **Inter** = interaction reliability, **Intu** = intuitiveness &
discoverability, **Copy** = text/copy clarity, **Vis** = visual layout/alignment/centering, **Tour** = intro & tour
(incl. spotlight centering), **Code** = code quality of the new code, **Res** = resource cost.

| Round · reviewer | Overall | Stab | Inter | Intu | Copy | Vis | Tour | Code | Res |
|---|---|---|---|---|---|---|---|---|---|
| r1 · A | 7.3 | 8.0 | 7.5 | 7.5 | 7.5 | 8.0 | 8.5 | 8.0 | 5.5 |
| r1 · B | 7.3 | 6.4 | 7.2 | 7.6 | 7.6 | 8.6 | 8.8 | 7.4 | 7.4 |
| r2 · A | 7.9 | 7.2 | 7.8 | 7.8 | 8.2 | 8.6 | 8.9 | 7.8 | 8.6 |
| r2 · B | 7.8 | 7.3 | 8.0 | 7.8 | 8.0 | 7.8 | 8.6 | 7.8 | 8.0 |
| r3 · A | 7.9 | 7.5 | 8.0 | 8.0 | 8.2 | 7.8 | 8.8 | 8.0 | 8.3 |
| r3 · B | 7.9 | 7.4 | 7.6 | 8.0 | 8.2 | 8.5 | 8.8 | 7.8 | 8.6 |
| r4 · A | 8.3 | 8.6 | 8.0 | 7.8 | 8.0 | 8.4 | 8.7 | 8.3 | 8.0 |
| r4 · B | 8.1 | 8.0 | 8.2 | 7.5 | 8.2 | 8.4 | 8.8 | 8.3 | 8.2 |
| r5 · A | 8.1 | 8.0 | 8.0 | 8.0 | 8.3 | 8.5 | **9.0** | **7.5** | 8.0 |
| r5 · B | 8.2 | 7.8 | 8.2 | 8.4 | 8.2 | 8.7 | 8.9 | 7.8 | 8.7 |
| r6 · A | — | died when the Mac slept; no report | | | | | | | |
| r6 · B | 8.4 | 8.6 | 8.2 | 8.3 | **7.8** | 8.6 | 8.8 | **7.8** | 8.7 |

Reports: `docs/reviews/2026-10-06-stability-tour-review-r{1..5}-{A,B}.md` and `...-r6-B.md`, images in
`docs/reviews/2026-10-06-stability-tour/r<N>-<A|B>/`. Per-round fixes, evidence and rejections:
`docs/superpowers/plans/2026-10-06-stability-tour-progress.md` ("Review round N" sections).

### 1.3 What is solid (measured; keep all of it)
- **Tour centering:** cutout inset **3.0 pt on all four sides**, every step, light and dark, both Opacity settings
  (every reviewer, every round, measured from pixels). Render probe: inner 2/2/2/2 px, outer 6/6/6/6 px,
  `failures=0`. Radii concentric: card 8, cutout 11, panel 16. Skippable 4 ways, replayable 3 ways (`?`, Settings,
  welcome), resumes after a close, keyboard-driven, VoiceOver labels, handles Macs with no battery.
- **Nothing moves under the pointer:** 0 position changes in every frozen-scan sample (r2: 0/116; r3: 0/45; r4:
  0/19 per breakdown live; r5 A: 0/48; r5 replay: 135 frozen scans, 0 rows at or above the pointer moved). An
  expanded app never collapsed or vanished while hovered (≈ 6 min live in r5).
- **Currency:** a one-core load reaches the CPU card and the breakdown row in ~2 s (fast attack: row 12 % at +2 s,
  was 3.1 %). After a load ends: header 30 → 12 % 2 s later (fast release), card 32 → 17 %.
- **Cards:** CPU card never ≥ 3 pp from its reading; cards change 3–4× less often than the raw readings.
- **Order churn (r5 replay under `load.sh`):** expanded app's visible top-5 order changes 10.1 → **5.1**/min, set
  changes 0.8/min, "Finished processes" in the top 2: 13 → **0** scans, first 14 rows' slot changes 33.0 →
  **17.2**/min. Synthetic close/bursty apps: 23.7 → 14.3 reorders/min. Live: 2.5 reorders/min, 0/49 inversion scans.
- **Resource:** nothing new runs while the panel is closed (no new timers or observers); breakdown scan ~15–17 ms
  per 2 s (p50 17.1 ms), display logic 0.3–0.4 ms per scan; tour +0.3–1 pp of a core and 4–6 MB only while shown,
  nothing when hidden; installed HEAD idle 0.0 % / 13 MB closed. Open overview ~12 % of a core in the probe
  (pre-existing sparkline slide, see O-RES-2).
- macOS agents are grouped into "Other processes"; loginwindow has no Quit / Force Quit.

### 1.4 Plateau diagnosis (why rounds 3–5 stalled at ~8)
1. **Each round patched symptoms by adding a stabiliser rule.** The breakdown order now comes from ~8 interacting
   mechanisms and ~12 tuned constants: two-scan text confirmation, relative + absolute hysteresis, a jump rule, the
   inversion timeout, the promotion floor, two dwells (apps 5 s, processes 10 s), freeze + partial freeze + unfreeze
   delay, ended placeholders, newcomers-below-for-one-scan, groups-last, Finished-last, trailing windows, fast
   attack/release. `docs/design/breakdown-stability.md` lists 23 rules. Every fix traded one measure against
   another (e.g. r5's process dwell cut reorders but raised child inversion scans 67 → 79/149).
2. **Code quality is the lowest area (r5: 7.5 / 7.8)** and is now what caps the overall: reviewers cite the rule
   stack (r5 A C1, Medium), long functions (`BreakdownView.swift` 661 lines; `BreakdownDisplay.swift` 292;
   `ProcessScan.swift` 599), and history in comments.
3. **Interaction reliability is capped at ~8 because reviewers cannot drive key interactions off-screen:**
   right-click `NSMenu` contents and targets, trackpad scrolling, real hover enter/exit, and clicking through the
   tour's hole (r4 A I3, B I4; r5 A I3, B I4). They score what they cannot verify conservatively.
4. **A few recurring Low items are rejected every round** (Quit only via right-click, empty Settings, header vs
   row sum, frozen order goes stale). Each costs ~0.1–0.3 per area per round. Either fix them or get the owner's
   decision recorded so reviewers see it as intended (section 2.8).

The fix is not another rule. It is fewer, clearer rules (section 3), plus making the unverifiable interactions
testable, plus closing the cheap Low items.

---

## 2. Open findings (r4, r5, still-open items from r1–r3; deduplicated)

Status keys: **OPEN** = not fixed; **PARTIAL** = partly fixed; **REJECTED** = a fix round rejected it (reason given;
do not redo blindly, but reconsider where noted); **OWNER** = needs the owner (decision or a real-panel check).
Evidence = report + section. All paths relative to the repo root.

### 2.1 Stability of numbers & lists
| ID | Sev | Status | Finding | Evidence | Fix | Files | Acceptance |
|---|---|---|---|---|---|---|---|
| O-ST-1 | Medium | PARTIAL → consolidation | Rule stack is hard to reason about and rules trade against each other (child inversion scans 79/149 after r5; "0.0 % above 0.5 %" child rows in captures) | r5 A "Code quality" C1, "Stability" S3, "Visual" V1; r5 B S1; progress note r5 "Fixed" row 2 trade-off | Section 3 consolidation | `Sources/MacStatsCore/BreakdownDisplay.swift`, `StableRanking.swift` | Replay numbers in 3.4 all at or better than r5 |
| O-ST-2 | Low–Med | PARTIAL (by design) | A pointer resting where the card was clicked does not freeze the list; a click without moving can hit a row that just moved | r5 A "Interaction" I1; r5 B I3 | Keep the rule (r2 showed freezing on the first noisy reading caused stale order: Chrome 5.2 % below a 0.0 % app). Consolidated model: **at most one reorder** under an unmoved pointer, and never within 1 s of a click/scroll in the list | `BreakdownDisplay.swift`, `Sources/MacStatsApp/BreakdownView.swift` (`PointerProbe`) | Unit test: unmoved pointer + reorder + click 0.5 s later hits the same key |
| O-ST-3 | Low | REJECTED (r1, r2, r4) | While frozen, a newly heavy app joins at the bottom / an order goes stale while the pointer rests | r5 A S2; r5 B S2; r2 A | Partial freeze (r5) already lets rows below the pointer re-sort. Rejected reason: anything more moves rows under the pointer (the owner's original bug). Optional: a tiny "Sorting paused" cue (r5 B top fix 4) | — | — |
| O-ST-4 | Low | REJECTED (r2, r3) | Breakdown header ≠ sum of shown rows (up to 3.9 pp at 28 % mean CPU) | r2 B S5; r3 A S4 | Rejected: the header is the measured whole-Mac figure; "System" row covers the rest. If flagged again: show the header as the rounded sum of shown rows | — | — |
| O-ST-5 | Low | REJECTED (r4, r5) | CPU card 20–26 text changes/min, a few A→B→A flips | r5 A S4 | Rejected: a 3 s dwell would trade away "never ≥ 3 pp off, load in ~2 s", which both reviewers praise | — | — |
| O-ST-6 | Low | REJECTED (r1) | Card (2 s window) vs breakdown header (4 s, now 8 s) disagree briefly | r1 A S5 | Accepted; fast release now limits it to ~2 s | — | — |

### 2.2 Interaction reliability
| ID | Sev | Status | Finding | Evidence | Fix | Files | Acceptance |
|---|---|---|---|---|---|---|---|
| O-IN-1 | Medium (caps the area) | OPEN → consolidation (c) | Right-click menu contents, Quit/Force Quit targets, trackpad scroll keeping, real hover, tour-hole click-through cannot be driven off-screen | r4 A I3, r4 B I4, r5 A "Interaction" (I3), r5 B I4 | Pure models + tests + probe driver (section 3.3) | new Core files (3.3), `ProcessActions.swift`, `BreakdownView.swift`, `TourOverlay.swift` | Tests listed in 3.3 pass; probe prints a menu/target/scroll/hit-test table |
| O-IN-2 | Low | REJECTED (r5) | Expanded app that drops to one process collapses by itself (pointer away) | r5 A I2 | Rejected: its one process row would repeat the app row; frozen lists keep it. Reconsider only if the consolidated "expanded app pinned" model makes it free (keep expanded showing one row) | — | — |
| O-IN-3 | Low | OPEN (unverified) | Stale hover highlight after a reorder under an unmoved pointer | r3 A I2 | Covered by O-ST-2's "at most one reorder under an unmoved pointer"; hover state keyed by row key, not index | `BreakdownView.swift` (`RowHover`) | Unit test on the hover model; owner check |
| O-IN-4 | Low | OWNER | Esc / Return / arrows in the real panel; lock/unlock with a breakdown open | progress note "Owner manual checks" | — | — | Section 6 |

### 2.3 Intuitiveness & discoverability
| ID | Sev | Status | Finding | Evidence | Fix | Files | Acceptance |
|---|---|---|---|---|---|---|---|
| O-DI-1 | Low (recurs every round r1–r5) | REJECTED ×4 → OWNER | Quit / Force Quit only via right-click; no visible control | r5 B D1; r4 A U2, B D2; r3 A D2; r2 | Rejected reason: hint footnote "Click to expand · Right-click to quit" + tooltips, as Activity Monitor (which has a toolbar ✕). **Ask the owner** whether to add a hover-revealed ✕ (quit) on app rows. If no: record "owner decision" in the progress note so the fix round can cite it | `BreakdownView.swift` | Owner answer recorded |
| O-DI-2 | Low | OPEN | Group rows' meaning (System, Other processes, Finished processes) only in tooltips | r5 A D3, "Cross-cutting" | Make the tooltip text a one-line subtitle under the row name on first appearance of each group per breakdown, or a footnote line; keep tooltips. Measure fit at 1.00× with the render probe | `BreakdownView.swift`, `BreakdownFormat.swift` | Render probe fit 1.00; captures light/dark |
| O-DI-3 | Low | REJECTED (r3, r5) | Memory's "Other processes" (largest) pinned last | r5 A D2 | Rejected: the list answers "which app"; the group is an aggregate of helpers | — | — |

### 2.4 Text / copy
| ID | Sev | Status | Finding | Evidence | Fix | Files | Acceptance |
|---|---|---|---|---|---|---|---|
| O-TX-1 | Low | OPEN | Battery card "4h left" reads as exact; "About 4h left" signals an estimate | r5 B T4 | Change copy if it fits the card meta at 1.00×; else leave | `Sources/MacStatsCore/DurationFormat.swift` or the card view | Render probe fit; `DurationFormatTests` updated |
| O-TX-2 | Low | REJECTED (r3–r5) | Raw process names ("zsh", "Helper (Renderer)") | r5 A T3; r4 B T2 | Inherent; full name in the tooltip | — | — |

### 2.5 Visual layout
| ID | Sev | Status | Finding | Evidence | Fix | Files | Acceptance |
|---|---|---|---|---|---|---|---|
| O-VI-1 | Low (recurs r1–r5) | REJECTED (speculative) → reconsider | Settings ~55–60 % empty | r5 A V3, r5 B D2/V3 | A real, non-speculative fill: an "About" line at the bottom (app name, version from `CFBundleShortVersionString`, "Replay tour" already exists). No new settings | `Sources/MacStatsApp/SettingsView.swift` | Captures light/dark; nothing clipped |
| O-VI-2 | Low | REJECTED (r1 dim tuned) → reconsider | Half-covered text of the next card peeks out under the tour dim | r5 B V2 | Try dim 0.35 (light) / 0.45 (dark) in the render probe; keep only if callout text contrast stays ≥ 4.5:1 and the highlighted card is unchanged | `Sources/MacStatsApp/TourOverlay.swift` | Render captures; `insets.txt` unchanged |
| O-VI-3 | Low | → O-ST-1 | Briefly unsorted process rows (0.0 % above 0.5 %) | r5 A V1 | Consolidation | — | — |

### 2.6 Intro & tour
| ID | Sev | Status | Finding | Evidence | Fix | Files | Acceptance |
|---|---|---|---|---|---|---|---|
| O-TO-1 | Low (nit) | REJECTED (r5) | Cutout ~0.5–0.9 pt wider at the 45° corner apex than on the sides | r5 A TR1 | Rejected as the shape's nature. Optional: draw the cutout as the card's path stroked outward by 3 pt (true offset curve) | `TourOverlay.swift`, `Sources/MacStatsCore/TourLayout.swift` | Render probe apex gap = side gap ± 0.25 pt |
| O-TO-2 | Low | REJECTED (r5) | Two accidental closes mark the tour seen | r5 A TR2 | Rejected: `?` replays it | — | — |
| O-TO-3 | Medium for the score | OPEN → 3.3 | Tour hole click-through not verifiable | r5 A, B (Interaction) | `TourHitTest` model (3.3) | — | — |

### 2.7 Code quality
| ID | Sev | Status | Finding | Evidence | Fix | Files | Acceptance |
|---|---|---|---|---|---|---|---|
| O-CQ-1 | Medium | PARTIAL → consolidation | ~8 interacting stabiliser mechanisms, ~12 constants | r5 A C1; r5 B C1 | Section 3.1–3.2 | `BreakdownDisplay.swift`, `StableRanking.swift`, `RefreshScheduler.swift`, `docs/design/breakdown-stability.md` | ≤ 6 ordering constants; design note ≤ ~10 rules |
| O-CQ-2 | Low | PARTIAL | History / measurement prose in comments ("5.1 → 3.6 times a minute", "review round 2", research citations) | r5 A C2; r5 B C2; r2 A | Comments say what the code does now; history lives in docs only | all of `Sources/` | `grep -rnE "round [0-9]|→ [0-9]|was [0-9]|review|docs/research" Sources/` returns nothing |
| O-CQ-3 | Low | OPEN | `BreakdownView.swift` 661 lines (view, row types, pointer probe, icon cache) | r5 A C5 | Split into `BreakdownView.swift` (screen), `BreakdownRows.swift` (row views), `PointerProbe.swift`, `AppIconCache.swift`; no behaviour change | `Sources/MacStatsApp/` | Each file < ~250 lines; build + tests green |
| O-CQ-4 | Low | REJECTED/deferred (r1–r4) | `MetricsStore` holds ~15 breakdown-state fields; `CardDisplay` extraction | r2 A; r1 A C2 / B C3 | Do it as part of 3.1: the new `BreakdownOrder` value holds the state; `MetricsStore` keeps one field | `Sources/MacStatsCore/MetricsStore.swift` | `MetricsStore` has one breakdown-state property |
| O-CQ-5 | Low | REJECTED (r1–r3) | Zero-size buttons for tour key shortcuts instead of `onKeyPress` | r1 A C3 / B C5 | Rejected: `onKeyPress` needs focus a non-activating panel doesn't reliably give. Document this in one comment | `TourOverlay.swift` | Comment present |
| O-CQ-6 | Low | OPEN | `BreakdownDisplay.engaged` lasts the whole breakdown | r5 B C4 | Folded into the new model's per-breakdown state | — | — |

### 2.8 Resource cost
| ID | Sev | Status | Finding | Evidence | Fix | Files | Acceptance |
|---|---|---|---|---|---|---|---|
| O-RES-1 | Medium | **DONE at pause** | Install HEAD and confirm closed-panel CPU | r5 A R1/R2; r4 A P2, B R1 | Done: 0.0 % CPU, 13 MB (`ac7ea54`). Tell the next reviewers (in the progress note) so they measure the installed HEAD | — | Reviewers measure ≤ 0.5 % closed |
| O-RES-2 | Medium/Low (pre-existing) | OWNER | Open overview ~10–13 % of a core (continuous sparkline slide) | r1 A X2 / B K2; r4 A P1 | `.drawingGroup()` tried, within noise, reverted. Sliding less often changes the owner-approved motion: **owner decision** | `Sources/MacStatsApp/Sparkline*.swift` | — |
| O-RES-3 | Low | OWNER | Tour's 4–6 MB not returned 20 s after skip (probe lacks the app's `malloc_zone_pressure_relief`) | r2 progress "Rejected" | Owner check with `footprint` | — | Section 6 |
| O-RES-4 | — | OPEN (workflow step) | Perf vs baseline `1ed61cf` never formally measured | workflow "Verify" phase | Section 5 step 4 | — | `docs/reviews/2026-10-06-stability-tour-perf.md` |

### 2.9 Round 6, reviewer B (8.4) — all new, none fixed yet
Report: `docs/reviews/2026-10-06-stability-tour-review-r6-B.md` (live 150 s run: 0 rows at or above the pointer
moved in 159 scans; CPU card 20.8 text changes/min vs 54.8 raw, 0 A→B→A flips; burst shown in 1.5 s; spotlight
3.0 pt all sides). Its lowest areas: **Copy 7.8, Code 7.8**.

| ID | Sev | Status | Finding (r6-B section) | Fix | Files | Acceptance |
|---|---|---|---|---|---|---|
| R6-I1 | **Medium** | OPEN | Uncovering the panel (screen unlock / display wake) with a breakdown open calls `setVisibility(.popoverOpen)` → `enterBreakdown` → `beginBreakdown`: rows cleared, "Measuring…", ranked from scratch, so the list re-sorts under the pointer ("Interaction" I1). Round 4 chose "scan afresh on uncover"; this reviewer measures it as a break of "nothing moves under the pointer" | On uncover restart only the scan session (window); keep the shown rows, order and expanded app; first new scan updates values under the normal rules | `Sources/MacStatsApp/MacStatsApp.swift:191`, `MetricsStore.beginBreakdown` | Unit test: uncover keeps rows/order/expansion; owner check 6.7 |
| R6-S1 | **Medium** | OPEN — conflicts with REJECTED r2/r5 | Frozen list under a resting pointer shows a lower value above a higher one for up to 29 scans (58 s); 48/53 CPU scans had one ("Stability" S1). Earlier rounds rejected "unfreeze after N s of rest" (rows moving under a pointer about to click = the owner's original bug) | Decide in the consolidation, not as a new rule. Options: (a) after ≥ 10 s of a motionless pointer, re-sort only rows **above** the hovered row and keep the hovered row's screen position (scroll compensates), (b) a subtle "Sorting paused" cue, (c) hold printed values of frozen rows so a frozen list never prints an inversion (values update again at unfreeze). (c) keeps "nothing moves" and removes the visible unsorted pair; check it doesn't hide a real load (header still live) | `BreakdownOrder` (3.1), `RowHold` | Replay: frozen scans with a printed inversion ≈ 0, rows at/above pointer moved = 0 |
| R6-S2 | Low | OPEN | "Finished processes" blinks in/out at ~0.2 % with the pointer away, shifting rows below by one (first 9 rows changed 18×/53 scans expanded vs 1× hovered) | Show it only at ≥ 0.5 % (or once shown, keep it until collapse) | `BreakdownDisplay.swift` / `BreakdownOrder` | Replay: Finished-row show/hide toggles ≤ 1/min |
| R6-S3 | Low | OPEN | CPU breakdown header opens at the card's 2 s value (27 %) then switches to the 8 s window (12 %) | Show "Measuring…" header until the first breakdown total, then print it without the two-scan confirmation; or keep the card value until the window is filled | `BreakdownDisplay.swift` (header hold), `MetricsStore` | Test: header's first printed value = first breakdown total |
| R6-S4 | Low | OPEN | Network ↑ line 12.8 changes/min at a few KB/s | relBand 0.25 or a 3 KB/s absolute band for ↑ | `MetricsStore.swift:177`, `DisplayHold.swift` | `rateHoldsSmallWobble` extended |
| R6-I2 | Low | OPEN | Tour step 5: `?` sits in the cutout; clicking it restarts the tour at step 1 | While the tour is showing, `?` = Done | `Sources/MacStatsApp/RootView.swift` (`startTour`) | `TourStateTests` case; `TourHitTest` (3.3) |
| R6-I3 | Low | OPEN | Long lists: last row cut by the card edge, no scroll indicator | `.scrollIndicators(.visible)` briefly on appear, or a bottom fade | `BreakdownView.swift` | Render capture |
| R6-D1 | Low | OPEN | Battery breakdown at idle: 5 of 7 rows "<0.01 W" | Print "Idle" (exact value in tooltip); rank unchanged | `BreakdownFormat.swift` | `BreakdownFormatTests` |
| R6-D2 | Low | OPEN | "Other processes" chevron: contents unclear | Count in the name ("Other processes · 214") or tooltip — merge with O-DI-2 | `BreakdownView.swift` | Render fit 1.00 |
| R6-D3 | Low | REJECTED (= O-DI-1) | Right-click only to quit | See O-DI-1 (owner decision) | — | — |
| R6-T1 | Low | OPEN (copy churn) | Tour step 1 "The number is right now; the graph shows the last minute." still awkward (third rewrite) | Use the reviewer's second option: "Shows how busy your Mac is now and over the last minute. Click to see which apps use it." Then stop iterating | `Sources/MacStatsCore/Tour.swift:40` | `TourCatalogLintTests`, 2-line fit |
| R6-T2 | Low | OPEN | Battery footnote "Processor power, not the screen" cryptic | "Apps' processor power only" (check fit 1.00) | `BreakdownView.swift` | Render fit |
| R6-T3 | Low | OPEN | CPU card "Chip 33 °C" ambiguous | "Chip temp 33 °C" if it fits the meta line | card view / `MetricsStore` | Render fit |
| R6-T4 | Low | OPEN | Mixed case on card secondary lines ("OK", "not charging", "running low") | Sentence case throughout ("Not charging", "Running low") | card meta strings (grep the literals) | Tests that assert these strings updated |
| R6-T5 | Low | OPEN | Welcome card text-heavy (permission lines ~18 words each) | "Will ask to send alerts" / "Will ask to use Finder for the Trash" | `Tour.swift` (welcome copy) | Lint + render |
| R6-V1 | Low | = O-VI-1 | Settings ~45 % empty | O-VI-1 | — | — |
| R6-V2 | Low | OPEN (optional) | Step 5 ring encloses two buttons as one pill | Optional: spotlight only `?`, mention the gear in copy; keep centring 3.0 pt | `Tour.swift`, `TourLayout.swift` | `insets.txt` |
| R6-C1 | **Medium** | → consolidation | Many interacting rules (= O-CQ-1) | Section 3 | — | — |
| R6-C2 | Low | OPEN | `stableRanking(… frozen:, fixed:)`: two ways to say "all fixed" | One parameter (disappears in `BreakdownOrder`) | `StableRanking.swift` | — |
| R6-C3 | Low | OPEN | `MetricsStore.breakdownPointerProbe`: public mutable closure, implicit view→model dependency | Pass the pointer state into the per-scan call (`BreakdownOrder` input) | `MetricsStore.swift`, `BreakdownView.swift` | — |
| R6-C4 | Low | = O-CQ-2 | Comments link to `docs/research/…` | Link only to `docs/design/` | — | grep in O-CQ-2 |
| R6-C5 | Low | OPEN | `CLAUDE.md` "255 tests" line is stale (373) | Update the status line in the docs step | `CLAUDE.md` | — |
| R6-P1 | Low | OPEN | Tour on screen ~+3–4 % of a core (noisy probe); overlay recomputed every 0.5 s card tick | Cache the cutout per step (anchors are static); keep the overlay out of the card tick's invalidation | `TourOverlay.swift` | Render-probe CPU with tour on within noise of tour off |

---

## 3. Work package C: Consolidation (top priority)

**Goal:** replace the layered stabiliser with **one small, clearly specified model**, keep or improve every
measured probe result, remove history from comments, split long functions, and make the interactions reviewers
cannot drive off-screen testable as pure models with unit tests and a headless probe driver.

### 3.1 The target model (spec)

One pure value type in MacStatsCore, suggested name `BreakdownOrder` (new file
`Sources/MacStatsCore/BreakdownOrder.swift`), owning all order state for one open breakdown. Inputs per scan:
rows (stable key, printed value, exact value, kind: app / process / group / ended), the pointer
(`.away`, `.onApp(key)`, `.unknown`), `menuOpen`, the expanded app key (if any), and `now`. Output: the ordered
rows. **Rules (aim: 5):**

1. **Freeze.** Pointer on app K → every row from the top down to and including K (and K's process rows) keeps its
   slot; rows below re-rank but never pass K. Pointer `.unknown` or a menu open → everything keeps its slot. The
   freeze ends at the first scan ≥ 1 s after the pointer leaves / the menu closes (scan-checked, no timer). While
   frozen, rows that ended stay as "Ended" placeholders and no rows are added above the pointer.
2. **Expanded app pinned.** The expanded app never disappears (kept below the top-N cut if needed) and its process
   rows are **held**: they keep their order while expanded except through rule 3; new processes append at the
   bottom of the block; "Finished processes" is always the block's last row and hidden while it prints 0.
   *Caution:* round 2 removed a pin of the expanded app's **position** in the app list (30 of 31 mis-sorted scans
   sat next to it). "Pinned" here means "present and not collapsed", not "fixed position" — the app row itself is
   ranked by rule 3 like any other.
3. **One hysteresis rule.** Row B passes row A only when B's printed value leads A's by at least a per-metric
   margin (relative **and** absolute, e.g. CPU 15 % and 0.15 pp; Battery 15 % / 0.015 W; Memory 5 % / 20 MB), and
   that lead has held continuously for the dwell (rule 4). A **decisive** lead (> 1.5× and > 1 pp / 0.05 W /
   200 MB) counts as held at once. One function: `lead(b, over: a) -> .none | .small | .decisive`.
4. **One dwell time.** A small lead must persist for `D` seconds (start with D = 6 s, three scans; tune by replay
   only). This single "lead for D seconds" rule replaces the inversion timeout, the promotion floor, the two
   separate dwells (5 s / 10 s) and newcomers-below-for-one-scan (a newcomer must lead for D like anyone).
   *Note:* round 5 rejected exactly this merge ("would change every measured trade-off at once"). The owner's
   consolidation instruction overrides that; the guard is the replay comparison in 3.4 — if the merged rule loses
   on a measure, tune D or the margins, don't add a rule back without recording why.
5. **Layout, not ranking:** group rows go after apps (Memory: always; CPU/Battery: by value, as now — keep
   whichever the current tests require), ended placeholders occupy their slot until unfreeze.

**Kept outside the order model (value rules, unchanged unless a replay shows a win):** trailing windows and fast
attack/release (`BreakdownScanner` in `ProcessScan.swift`), printed-value holds (`RowHold`), card holds
(`DisplayHold.swift`, `MetricsStore.updateCards`), sticky bar scale.

**Constants target:** ordering uses ≤ 6 named constants (margins per metric, decisive factor, D, unfreeze delay),
all in one `enum` next to the model. Delete `breakdownProcessReorderDwell`, `RankHysteresis.promotionFloor` and the
inversion-timeout bookkeeping (`lagging`) once the replay passes.

### 3.2 Comments and function size
- Every doc comment says what the code does now. Measurement history, review-round references and research
  citations go to `docs/design/breakdown-stability.md` (rewritten to the new ≤ ~10 rules: rule, constant, test) and
  the probe READMEs. Check with the grep in O-CQ-2.
- No function over ~40 lines in the touched files (`BreakdownDisplay.apply`, `ListRanking.rank`,
  `BreakdownScanner` methods in `ProcessScan.swift:448-563`, `RefreshScheduler.swift:38-89`).
- Split `BreakdownView.swift` (O-CQ-3).

### 3.3 Make the off-screen-unverifiable interactions testable
Each as a pure type in MacStatsCore with Swift Testing unit tests in `Tests/MacStatsCoreTests/` (suggested names;
check for existing equivalents first, e.g. `canQuitProcess`, `BreakdownList`):

| Interaction | Pure model | Unit tests (examples) |
|---|---|---|
| Right-click menu contents | `RowMenu.items(for row: RowKind, …) -> [MenuItem]` (header text, Quit, Force Quit…, disabled reason) used by the real `contextMenu` | app row → Quit + Force Quit; process row → per-process Quit; loginwindow → no Quit, reason "Part of macOS…"; group rows → no actions; ended row → none; MacStats itself → sensible (no self force-quit, or confirm) |
| Quit / Force Quit targets | `QuitTarget` resolved from the row **key** captured at menu open (pid set + bundle id), never from a slot index | reorder between menu open and action doesn't change the target; target app ended → action is a no-op with a message; app with N processes → graceful quit goes to the app, Force Quit confirms with the right name |
| Scroll keeping | `ScrollAnchor.keep(previous rows, anchor key, new rows) -> anchor key / offset` | reorder below the anchor keeps the anchor; anchor ended (placeholder) keeps it; scroll event without pointer motion → pointer `.unknown` (full freeze) |
| Tour hole click-through | `TourHitTest.hit(point, step, layout) -> .throughToCard(id) / .callout / .blocked` using the same rect `TourLayout` gives the spotlight | point inside the hole (incl. 1 pt inside each edge) passes through; inside the 3 pt inset ring but outside the card → defined behaviour (pass or block, documented); outside → blocked; callout buttons hit the callout |
| Hover / pointer state | `BreakdownPointer` transitions (enter app K, leave, scroll, click, menu open/close) | unmoved pointer + click within 1 s of a reorder → same key (O-ST-2) |

**Probe driver:** extend the r5 replay (`docs/research/2026-10-06-probes/r5-fixes/replay.swift` → a new
`docs/research/2026-10-07-probes/consolidation/`) to: (a) replay a recording through `BreakdownOrder` with scripted
pointer/menu/scroll events, printing order changes and "rows at or above pointer moved" (must be 0); (b) print a
table of menu items and Quit targets for every row of a real scan, before and after a forced reorder; (c) print
`TourHitTest` results for a grid of points per tour step. Reviewers can run it headlessly.

### 3.4 Acceptance: the probe numbers to keep (r5 replay on the same recording; re-record if the old JSON is gone)

| Measure (r5 README definitions) | Must be (r5 value) |
|---|---|
| Frozen scans: rows at or above the pointer that moved | **0** (0 of 135) |
| Expanded app collapsed / vanished while hovered | **never** |
| Burst rise: row at +2 s after a one-core load | ≥ 12 % (header ≥ 28 %) |
| Fall: header 2 s after the load ends | ≤ 12 % (from 30 %) |
| Expanded app's visible top-5 order changes/min (pointer away) | ≤ 5.1 |
| "Finished processes" in the block's top 2 | 0 scans |
| First 14 rows' slot changes/min | ≤ 17.2 |
| Child inversion scans (CPU; Battery) out of 149 | ≤ 79; ≤ 25 — aim lower (this is the trade-off the merge should improve) |
| App reorders/min, synthetic close/bursty load | ≤ 14.3 |
| Longest app inversion | ≤ 3 scans |
| Render probe | `failures=0`, inner 2/2/2/2 px, outer 6/6/6/6 px every step, footnotes fit 1.00 |
| Cost | scan p50 ≤ ~17 ms, display ≤ 0.4 ms/scan; nothing new while closed |

Record before (HEAD `ac7ea54`) and after, side by side, in the new probe README.

---

## 4. Ordered task list

### Ground rules for every task
- **Background only** (the owner works at this Mac). Never activate any app, never click or move the mouse, never
  open the real menu-bar popover, never take full-screen screenshots. Probe windows: level
  `CGWindowLevelForKey(.desktopWindow) + 1`, then `orderBack(nil)`; capture with
  `CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution])`; close
  windows right after.
- **Every probe under a kill timeout:** `(./probe & PID=$!; (sleep 120; kill $PID) & wait $PID)`. Kill leftovers:
  `pgrep -fl probe`, `pkill -f r4-fixes/load.sh; pkill -x yes`.
- **One build or test run at a time** (no parallel builds; they can freeze the Mac).
- **SDK:** `export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` before a bare `swift build`
  (`./Scripts/test.sh` and `./Scripts/bundle.sh` pin it themselves). Tests use Swift Testing, never `swift test`.
- **Resource limits:** no new work while the popover is closed (no timers, observers or scans); the tour costs
  nothing when not on screen; no extra per-process scans; MacStats's own CPU/RAM at or below current HEAD.
- **Accuracy:** stored readings, graphs, bars and alerts must stay exact (audited to Activity Monitor/top/vm_stat).
- **Git:** small commits on `feat/stability-tour`, each ending with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. No push to `main`, no release. Do not install
  (`./Scripts/bundle.sh`) except in the final step.
- **Mac awake:** run `caffeinate -i -s &` (and keep the lid open) for the whole session; sleep killed reviewer A in
  round 6. Kill it at the end.
- Update `docs/superpowers/plans/2026-10-06-stability-tour-progress.md` after every task (the session can end any
  moment).

### Standard verification
```bash
cd /Users/davidghermansteinberg/Desktop/Home/Projects/Code/Mac Apps/MacStats
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk; swift build
./Scripts/test.sh                                   # all (373 at ac7ea54)
./Scripts/test.sh --filter StableRankingTests       # one suite
# record/replay (exact commands: docs/research/2026-10-06-probes/r5-fixes/README.md)
P=docs/research/2026-10-06-probes/r5-fixes; SDK=$SDKROOT
mkdir -p "$TMPDIR/r5/rec" "$TMPDIR/r5/rep"
cp $P/record.swift "$TMPDIR/r5/rec/main.swift"; cp $P/replay.swift "$TMPDIR/r5/rep/main.swift"
bash -c 'CORE=$(ls Sources/MacStatsCore/*.swift | grep -v AppleSensorReader)
  swiftc -sdk '"$SDK"' -O -o "$TMPDIR/r5/record" $CORE "$TMPDIR/r5/rec/main.swift"
  swiftc -sdk '"$SDK"' -O -o "$TMPDIR/r5/replay" $CORE "$TMPDIR/r5/rep/main.swift"'
(sleep 20; exec docs/research/2026-10-06-probes/r4-fixes/load.sh) & L=$!
"$TMPDIR/r5/record" 300 "$TMPDIR/r5/rec.json"; kill $L; pkill -f r4-fixes/load.sh; pkill -x yes
"$TMPDIR/r5/replay" "$TMPDIR/r5/rec.json"
OUT=$PWD/$P/out docs/research/2026-10-06-probes/tour-render/run.sh               # tour captures + insets + fit
OUT=$PWD/$P/out docs/research/2026-10-06-probes/tour-render/run.sh --breakdowns  # real-scan breakdowns
pgrep -fl probe                                     # must be empty when you finish
```
Current vs superseded probes: **current** = `r5-fixes/` (record/replay), `tour-render/` (captures, insets, fit),
`r4-fixes/load.sh` (bursty load generator), `visibility/` (open/closed detection, round 1). **Superseded** =
`stability/` (no agents, no pointer probe, counts children as a set; its README says so), `r1-fixes/` (round-1 API,
no longer builds), `r2-fixes/`, `r3-fixes/` (kept as records; r3's `run.sh synthetic` still useful for synthetic
contention). Note: the replay copies `record.swift`/`replay.swift`, which compile against Core's API; when the
consolidation changes that API, update copies of both into the new probe folder (keep the r5 ones as the "before").

### Tasks
- [ ] **T0. Start.** `caffeinate -i -s &`. Read this plan, `CLAUDE.md`, `docs/design/breakdown-stability.md`,
  the progress note's round 4–5 sections, `r5-fixes/README.md`, and `docs/reviews/2026-10-06-stability-tour-review-r6-B.md`
  (its findings are already in section 2.9). Run the standard build + tests.
- [ ] **T1. Baseline numbers.** Record one 300 s recording under `load.sh`; run the r5 replay on it; save output as
  `docs/research/2026-10-07-probes/consolidation/before.txt` (copy the recording JSON there too if < ~5 MB). Verify:
  numbers within noise of section 3.4.
- [ ] **T2. Owner questions (ask once, short, don't block):** O-DI-1 (visible ✕ on rows?), O-RES-2 (slide less
  often?). Continue with defaults (no change) if no answer; record answers in the progress note.
- [ ] **T3. Pure interaction models** (3.3): `RowMenu`, `QuitTarget`, `ScrollAnchor`, `TourHitTest`,
  `BreakdownPointer` transitions; wire the real views to use them (no behaviour change). Verify: build, tests
  (new suites green), render probe `failures=0`.
- [ ] **T4. `BreakdownOrder` model** (3.1) with tests written first for the 5 rules (freeze/partial freeze, pin,
  hysteresis, dwell, layout) plus the property test `frozenKeepsTheShownRowsAsAPrefix` ported. Keep old code in
  place until T5 passes.
- [ ] **T5. Switch over + replay.** Route `MetricsStore` through `BreakdownOrder` (one state property). Run replay on
  the T1 recording → `after.txt`. Every row of 3.4 must hold; tune D / margins only. Then delete the replaced rules
  and constants and their now-dead tests (they are code you changed in this branch; mention removed tests in the
  commit). Verify: build, all tests, replay, render probe `--breakdowns`.
- [ ] **T6. Comments + splits** (3.2, O-CQ-2, O-CQ-3, O-CQ-4, O-CQ-5, O-CQ-6). Rewrite
  `docs/design/breakdown-stability.md` to the new rules (rule · constant · test). Verify: the grep in O-CQ-2 is
  empty; build; tests.
- [ ] **T7. Probe driver** (3.3 "Probe driver") in `docs/research/2026-10-07-probes/consolidation/` with a README
  (terms, exact commands with timeouts, what each output line means). Verify: runs headless in < 2 min, prints 0
  for "rows at or above pointer moved".
- [ ] **T7b. Round-6 Mediums:** R6-I1 (keep the list on uncover) and R6-S1 (frozen list prints no inversion;
  decide the option inside `BreakdownOrder`, record the choice and why in the design note). Verify: tests + replay.
- [ ] **T8. Low items:** all OPEN rows of section 2.9 (copy pass R6-T1…T5 once, then stop iterating copy; R6-S2,
  S3, S4, I2, I3, D1, D2, C2, C3, P1), plus O-DI-2 (group row explanation), O-TX-1 ("About 4h left" if it fits), O-VI-1 (Settings
  About line), O-VI-2 (dim test, keep only if better), O-ST-2 (one-reorder rule under an unmoved pointer + click
  guard), O-TO-1 (optional true offset cutout, only if render probe shows apex = sides ± 0.25 pt and nothing else
  changes). Verify: render probe captures (Read the PNGs yourself, light and dark), fit 1.00, `insets.txt`
  unchanged, tests.
- [ ] **T9. Cost check.** Scan p50 and display ms/scan from the replay; open overview with the tour off/on in the
  render probe; confirm no new timers/observers while closed (code read: grep `Timer`, `addObserver`,
  `NSEvent.addLocalMonitor` and check each is created only while a breakdown/tour is shown).
- [ ] **T10. Progress note.** Add "Consolidation (round 6 fix)" to the progress note: what changed, before/after
  table, removed rules, rejected items with reasons, owner checks. Commit. Then go to section 5.

---

## 5. Resuming the review loop

The original loop is a Workflow-tool script:
`/Users/davidghermansteinberg/.claude/projects/-Users-davidghermansteinberg-Desktop-Home-Projects-Code-MacStats/4c5e9659-3251-4902-b736-9eb78a2dad17/workflows/scripts/macstats-stability-tour-wf_1e020f34-4b6.js`
(args used: `date: '2026-10-06'`, `baseCommit: '1ed61cf'`). Its full prompt text from the shared rules onward is
copied verbatim in **Appendix A**, so the loop can be rebuilt even if that file is gone.

Running the script as-is would redo Research/Plan/Build and restart at round 1. To resume, write a new workflow
script (load the `workflow-authoring` skill first; the owner already opted into this workflow) that reuses
`RULES`, `CALIBRATION`, `REVIEW_SCHEMA`, `BUILD_SCHEMA`, the reviewer prompt, the fix prompt, `CONSOLIDATE`, the
Verify and Document phases from Appendix A, and changes only:
1. **Skip** Research, Plan, Build.
2. **Fix round 6 = the consolidation** (sections 3–4 of this plan; equivalently the fix prompt with `round = 6`, so
   `CONSOLIDATE` is appended), fed by the r5 reports and `...-r6-B.md`. If the consolidation was already done
   by hand following section 4, skip this step.
3. **Reviews start at round 7** (`r7-A`, `r7-B`), two independent reviewers in parallel, same prompt. Add to the
   reviewer prompt one sentence: "HEAD is installed in ~/Applications/MacStats.app only if the progress note says
   so; measure closed-panel idle CPU with ps/footprint on the running app without opening its panel."
4. Loop: reviews → if not (both overall > 9.0 and min area ≥ 8.5) → fix round (prompt with CONSOLIDATE appended
   for every round ≥ 6) → reviews, up to round 10 (`while (round < 10 && !passed)`, starting `round = 6`).
5. Then **Verify** (bug hunt of `git diff 1ed61cf` + perf vs `1ed61cf`, both writing their docs), fix pass, then
   **Document** (CLAUDE.md status entry, README line, `docs/design-language/guided-tour.md`, progress Results,
   final `swift build`, `./Scripts/test.sh`, `./Scripts/bundle.sh`, `open -g ~/Applications/MacStats.app`, 60 s
   closed-panel idle measurement).

**Keep the Mac awake for the whole run:** `caffeinate -i -s` (prevent idle and system sleep, the latter on AC
power) and keep the lid open; a sleeping Mac killed reviewer A in round 6. If a reviewer dies, rerun that one
reviewer for the same round; don't count a single report as a passed round.

If the bar is still not met after round 10, stop and report honestly with the per-area table; don't lower the bar.

---

## 6. Open manual checks for the owner (agents can't verify these off-screen)

Need the installed HEAD (already installed at pause; after new work, the final step reinstalls it).
1. **First-launch flow** in the real menu bar: back up defaults (`defaults export <bundle id> ~/macstats-defaults.plist`),
   reset, launch: the panel opens itself with the welcome card; the notification and Finder prompts come after it.
   Restore the defaults afterwards. Relaunching from Spotlight opens the panel.
2. **Keys in the real panel:** Esc on a tour step skips the tour without closing the panel; Esc goes back from a
   breakdown or Settings; Return / → = Next, ← = Back.
3. **Right-click menus:** on an app row, a process row, loginwindow under "Other processes" (no Quit / Force Quit),
   a group row; Quit/Force Quit act on the row you clicked even if the list re-sorted meanwhile.
4. **Scrolling and hover:** scroll the CPU list with the trackpad without moving the pointer: the order stops
   changing. Rest the pointer on the 2nd row while something below gets busy: rows below re-sort, nothing at or
   above moves. No stale hover highlight after a reorder.
5. **Tour hole click-through:** during a tour step, click the highlighted card through the hole: it drills in (or
   does what the tour copy says).
6. **Currency:** quit a busy app (or stop `yes`): its row and the header drop within ~2 s, like the card.
7. **Lock/unlock** with a CPU breakdown open: still there ("Measuring…" ~2 s); a running tour keeps its step.
8. **Resource:** closed panel `ps -o %cpu,rss -p $(pgrep -x MacStats)` < 0.5 % (was 0.0 % at pause); tour memory
   returns within ~20 s after skipping (`footprint <pid>`).
9. **Time to full while charging** (old open item from v1.1.0): plug in at ~75 %, compare MacStats's time to
   full / to the charge limit with the actual time.

---

## Appendix A: the workflow script's prompt text (verbatim)

Copied from `macstats-stability-tour-wf_1e020f34-4b6.js` lines 15 to the end, unchanged. `${D}` was
`2026-10-06`, `${BASE}` was `1ed61cf`, `${REPO}` the repo path above; `${round}` and `${who}` are the loop
variables.

```js
const REPO = '/Users/davidghermansteinberg/Desktop/Home/Projects/Code/Mac Apps/MacStats'
const BASE = args.baseCommit
const PROGRESS = 'docs/superpowers/plans/' + D + '-stability-tour-progress.md'
const PLAN = 'docs/superpowers/plans/' + D + '-stability-tour-plan.md'

const RULES = `
CONTEXT: repo ${REPO} (MacStats, native Swift macOS menu-bar system monitor; see its CLAUDE.md for build/test/SDK notes). Branch feat/stability-tour; baseline commit before this work: ${BASE}.
HARD RULES (the owner is working at this Mac right now):
- EVERYTHING IN THE BACKGROUND. Never bring any window in front of the owner, never call NSApp.activate / makeKeyAndOrderFront / orderFront, never click or move the mouse, never drive the owner's real menu bar or open the installed MacStats popover, never take full-screen screenshots. For visual checks, use an off-screen probe (a SwiftPM executable in the scratchpad or docs/reviews/... that renders the REAL SwiftUI views with a real or fake MetricsStore): put every window at level CGWindowLevelForKey(.desktopWindow)+1 and orderBack(nil), capture with CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) (fallback: cacheDisplay), close windows right after. Prior probes to copy from: docs/reviews/2026-10-05-readings-accuracy/*/main.swift and ~/.claude/skills/reviewer/references/capture.md. Run probes with a kill timeout: (./probe & PID=$!; (sleep 120; kill $PID) & wait $PID). Kill anything you started before finishing.
- No heavy jobs: one swift build at a time, no parallel builds of several checkouts at once. Bare 'swift build' needs: export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk . Tests: ./Scripts/test.sh (Swift Testing, not XCTest).
- Do not delete or overwrite files you did not create (except editing source/docs as the task requires). Do not push, release, or change git remotes. Commit your work on feat/stability-tour in small logical commits; end every commit message with the line: Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
- Do not install/replace ~/Applications/MacStats.app unless your task says so.
- Do not regress accuracy (the readings were audited to Activity Monitor/top/vm_stat parity) and do not raise MacStats's own RAM or CPU use: no new timers while the popover is closed, no extra per-process scans, nothing that runs when the tour is not on screen.
- Match the existing code style; minimum code; keep the Apple-native look (squircles = continuous corners, concentric radii; see docs/design-language/README.md and Sources/MacStatsApp/Design.swift).
- The session can end any moment: keep ${PROGRESS} updated (what's done, what's next, exact commands) whenever you finish a meaningful step.`

const USER_ASK = `The owner's request (dictated, paraphrased faithfully):
1) Things jump around. Example: in the CPU breakdown VS Code shows 2%, then drops, then 2% again, constantly. When they try to open (expand) VS Code to see its processes, the row jumps/re-sorts and the expansion goes away, so it's very hard to open and close things. The same jumpiness applies to basically every part of MacStats (cards, rows, numbers).
2) How intuitive is the app? How easy is it for people to find things, how clear is the text, how clean and how centered is the layout? When someone opens it for the first time, how do they know where things are?
3) Adopt the guided tour / introduction from their other apps BetterScreenshot (/Users/davidghermansteinberg/Desktop/Home/Projects/Code/Mac Apps/BetterScreenshot, App/Tours + Packages/TourKit + App/MenuBar/OnboardingController.swift) and JVoice (/Users/davidghermansteinberg/Desktop/Home/Projects/Code/Mac Apps/JVoice, Sources/JVoice/UI/WelcomeWindow.swift etc.): a skippable tour that shows the different things, whose highlight sits PERFECTLY around the squircle cards — perfectly centered — plus an introduction.
4) Research the psychology of how people use apps and how complicated an app feels, then implement the findings.
5) Review with the /reviewer skill, rate 1-10, keep improving until above 9. Then verify bugs, make sure MacStats's own RAM and CPU use do not spike (they don't want it to cost the user's computer much), document everything, verify it all works — all in the background.`

// ---------------- Research ----------------
phase('Research')
const research = await parallel([
  () => agent(`${RULES}\n\n${USER_ASK}\n\nYOUR TASK (research only, no source edits): diagnose part 1 (jumpiness) in the code and design the fix.\nRead Sources/MacStatsCore (MetricsStore, ProcessBreakdown, ProcessScan, ProcessReader, CPUUsage, NetworkThroughput, BatteryEstimator, RefreshScheduler) and Sources/MacStatsApp (BreakdownView, OverviewView, StatCard, MenuBarLabel, BatteryDetailsCard, MemoryPartsCard). For EVERY displayed number and list, find why it jitters (sampling window per tick, 0.5s cadence, rounding at boundaries, ranking re-sorts every tick, top-N cutoff, expanded state keyed to something that disappears, animation of reorder, list identity, hover/context-menu targets moving).\nIf useful, write a tiny headless measurement (scratchpad, NOT committed) that runs the real MacStatsCore breakdown sampling for ~60 s and counts rank swaps per minute and value flips for the top apps — report numbers. Keep it light.\nDesign concrete, accuracy-preserving fixes, e.g.: per-app CPU over a longer trailing window (say 2-3 s, or EMA) while the header/total stays consistent with rows; display hysteresis for rounding; stable ordering with a hysteresis margin + minimum dwell time; freeze ordering while the pointer is over the list or a context menu/expansion is active; pin an expanded app so it never disappears (keep it in the list even below the top N); stable identities; no reorder animation that moves rows under the cursor; similar treatment for card numbers, network rates, battery times. Say which logic must be pure + unit-tested in MacStatsCore.\nWrite your findings to docs/research/${D}-stability-diagnosis.md (standalone doc: define terms, exact paths) and return a concise summary (<= 400 words) with the file path.`, { label: 'research:stability', phase: 'Research' }),
  () => agent(`${RULES}\n\n${USER_ASK}\n\nYOUR TASK (research only, no source edits): parts 2 and 4. (a) Web research (WebSearch/WebFetch) on the psychology of how people learn and use apps: cognitive load, Hick's law, recognition over recall, progressive disclosure, information scent/discoverability and affordances (how people know something is clickable: chevrons, hover states), change blindness and why flickering numbers hurt reading, preattentive processing, Nielsen heuristics, onboarding research (coach marks vs. tours, skippable, 3-5 steps, users skip long tours, contextual tips, 'show me later'), Apple HIG on onboarding and menu bar extras. Cite sources. (b) Audit MacStats as it is NOW from the code (Sources/MacStatsApp/*.swift) and the screenshots in docs/design-language/assets and docs/reviews: every label and sentence, every clickable thing and whether a first-time user can tell it's clickable (cards drill in, right-click rows for Quit, click app to expand, gear = Settings, Empty Trash), alignment/centering/spacing consistency, jargon (e.g. 'Wired', 'Compressed', 'Overhead', '% of one core'), empty/loading states. You may render the real views off-screen to look at them (rules above). (c) Give a ranked list of concrete, small changes (copy rewrites with exact new strings, affordance hints, layout fixes) that would make a first-time user understand everything within ~30 s, without clutter and keeping the minimal Apple look.\nWrite docs/research/${D}-ux-psychology.md (standalone, define terms, sources) and return a concise summary (<= 400 words) with the path.`, { label: 'research:ux-psychology', phase: 'Research' }),
  () => agent(`${RULES}\n\n${USER_ASK}\n\nYOUR TASK (research only, no source edits): part 3. Study how BetterScreenshot (App/Tours/CLAUDE.md, App/Tours/TourCoordinator.swift, Packages/TourKit — TourEngine, TourRules, TourText, the tag/overlay presenter, App/MenuBar/OnboardingController.swift, App/Settings/SettingsView.swift 'Tours & tips') and JVoice (Sources/JVoice/UI/WelcomeWindow.swift and anything tour/intro related; check its docs/ and CLAUDE.md) implement their intro + tour: step model, anchors, spotlight/cutout drawing, tag/callout layout and copy style, Skip / Next / Back / 'n of m', persistence keys, who sees it (new vs existing users), replay entry point, tests. Then design the MacStats adaptation for a SwiftUI MenuBarExtra(.window) popover with a FIXED 320x404 size (see RootView.swift, OverviewView.swift, StatCard.swift, Design.swift, Appearance.swift): an in-panel overlay (no new windows) that dims everything except a squircle cutout around the target card; the cutout must be PERFECTLY centered on the card: anchor bounds via anchorPreference/GeometryReader in the panel's coordinate space, equal inset on all four sides, continuous corners, radius concentric with the card (cardRadius + inset), pixel-aligned; the callout placed above/below without covering the target, inside the panel bounds; keyboard (Return/Esc/arrows) support; reduced-motion respect; tour state pure + testable in MacStatsCore. Propose: welcome/intro step, the step list and exact copy (short, plain language), when it shows (first open of the popover for new installs; how existing users like the owner get offered it once), Skip tour, replay from Settings (and maybe a small '?' affordance), persistence keys in UserDefaults, and how to make sure it costs nothing when not shown. Note pitfalls with MenuBarExtra (the panel auto-dismisses on focus loss; NSAlert is used for dialogs).\nWrite docs/research/${D}-tour-design.md (standalone) and return a concise summary (<= 400 words) with the path.`, { label: 'research:tour-prior-art', phase: 'Research' }),
])
const researchText = research.map((r, i) => r ? r : '(research agent ' + i + ' failed)').join('\n\n---\n\n')

// ---------------- Plan ----------------
phase('Plan')
const plan = await agent(`${RULES}\n\n${USER_ASK}\n\nResearch summaries (full docs in docs/research/${D}-*.md — read them):\n${researchText}\n\nYOUR TASK: write ONE implementation plan at ${PLAN} and create the progress note ${PROGRESS} (standalone docs a fresh session can resume from: goal, terms, exact files, commands, checklists). Split the work into exactly two build parts that will be done sequentially by two different agents:\n PART A — Stability: all jumpiness fixes (numbers, ordering, expansion/selection that never disappears, context menus that act on the right row), with pure logic in MacStatsCore + Swift Testing unit tests, plus a small reusable headless 'stability probe' (kept in docs/research/${D}-probes/ or Tests) that measures rank swaps/min and value flips so reviewers can verify.\n PART B — Intuitiveness + tour: the copy/affordance/layout changes from the UX research and the in-panel intro + skippable tour with perfectly centered squircle spotlight, replay from Settings, persistence, tests for the pure tour state, and an off-screen render probe that captures every tour step (light + dark) and checks the cutout's insets are equal on all sides (print the measured insets).\nBe concrete (files, types, function names, exact copy strings, acceptance criteria incl. resource limits: no new work while popover closed; tour costs nothing when not shown). Commit the plan + progress note + research docs. Return a <= 300-word summary.`, { label: 'plan', phase: 'Plan' })

// ---------------- Build ----------------
phase('Build')
const BUILD_SCHEMA = { type: 'object', properties: { summary: { type: 'string' }, buildOk: { type: 'boolean' }, testsPassed: { type: 'string' }, openIssues: { type: 'array', items: { type: 'string' } } }, required: ['summary', 'buildOk', 'testsPassed', 'openIssues'] }
const buildA = await agent(`${RULES}\n\nRead ${PLAN} and ${PROGRESS}. Implement PART A (stability) exactly, with tests. Verify: export SDKROOT as noted; swift build; ./Scripts/test.sh all green; run the stability probe and record before/after numbers (baseline = ${BASE}; you may build the baseline in a git worktree under the scratchpad, sequentially, and remove that worktree afterwards). Commit. Update ${PROGRESS}. Return the schema.`, { label: 'build:A-stability', phase: 'Build', schema: BUILD_SCHEMA })
log('Part A: ' + (buildA ? buildA.summary.slice(0, 300) : 'FAILED'))
const buildB = await agent(`${RULES}\n\nRead ${PLAN} and ${PROGRESS} (Part A is done; build on it). Implement PART B (intuitiveness changes + intro & tour) exactly, with tests and the off-screen render probe; look at every captured tour step image yourself (Read the PNGs) and fix anything off-center (equal insets on all four sides, concentric continuous corners) or clipped, in light and dark. Verify: swift build; ./Scripts/test.sh green. Commit. Update ${PROGRESS}. Return the schema.`, { label: 'build:B-tour-ux', phase: 'Build', schema: BUILD_SCHEMA })
log('Part B: ' + (buildB ? buildB.summary.slice(0, 300) : 'FAILED'))

// ---------------- Review loop ----------------
phase('Review')
const REVIEW_SCHEMA = { type: 'object', properties: {
  overall: { type: 'number', description: 'overall score 1-10 with one decimal' },
  areas: { type: 'array', items: { type: 'object', properties: { area: { type: 'string' }, score: { type: 'number' }, verdict: { type: 'string' } }, required: ['area', 'score', 'verdict'] } },
  fixes: { type: 'array', items: { type: 'object', properties: { severity: { type: 'string', enum: ['High', 'Medium', 'Low'] }, issue: { type: 'string' }, evidence: { type: 'string' }, fix: { type: 'string' } }, required: ['severity', 'issue', 'evidence', 'fix'] } },
  reportPath: { type: 'string' },
}, required: ['overall', 'areas', 'fixes', 'reportPath'] }

const CALIBRATION = `CALIBRATION (owner's scale: 8-10 basically perfect, only nitpicks, 10 = best-in-class; 4-7 great app with noticeable issues; 1-3 not to our standard — NOT a school scale).
Target: MacStats, a native macOS 26 menu-bar system monitor (SwiftUI MenuBarExtra popover, fixed 320x404): overview cards (CPU, Memory, Network, Battery) with sparklines; click a card -> per-app breakdown (expand an app into its processes, right-click for Quit/Force Quit); Battery drill-in; Settings (gear); first-run intro + skippable guided tour. Audience: everyday Mac users, including non-technical ones. Mature (v1.x).
Standard for a 10: Apple's own Battery / Control Center menu-bar panels and Activity Monitor-quality readings; tour = Apple-quality coach marks.
A 3: numbers flicker and rows re-sort every tick so you can't click or expand; tour misaligned or traps you; jargon everywhere.
A 6: mostly steady but rows still occasionally move under the pointer or an expanded app collapses; tour works but the highlight is a few points off-center or the copy is wordy; some controls not discoverable.
A 9: values steady enough to read yet still current within a few seconds; rows never move out from under the pointer and an expanded app never vanishes; a first-time user understands every card and how to drill in within ~30 s; every tour highlight is exactly centered on its squircle (equal inset on all sides, concentric continuous corners) in light and dark, skippable at any time, replayable; text plain and short; MacStats's own CPU/RAM no worse than baseline.
Areas to score (each 1-10, one decimal): Stability of numbers & lists; Interaction reliability (expand/collapse, right-click, back, scroll); Intuitiveness & discoverability (first-time user); Text/copy clarity; Visual layout, alignment & centering; Intro & tour (incl. spotlight centering); Code quality of the new code; Resource cost.`

const CONSOLIDATE = `

PLATEAU NOTE (from the orchestrator): overall scores have sat at 7.9-8.3 for rounds 3-5 because each round patched symptoms by adding rules. Code quality (7.5-7.8) and interaction reliability are the lowest areas. This round is a CONSOLIDATION pass, in addition to the valid findings above:
(a) Re-design the breakdown steadiness logic (the stabiliser in MacStatsCore + its use in BreakdownView) as ONE small, clearly specified model with as few rules and tuned constants as possible (e.g. a single display-list state: rows above and including the hovered row frozen, expanded app pinned with its process rows held, everything else ranked with one hysteresis rule + one dwell time). Delete overlapping rules. Keep or improve every measured result in the record/replay probes (no row moves under the pointer, no expanded app collapse, fresh within a few seconds) — run them before and after and record both.
(b) Comments: describe what the code does now, no change history; split long functions.
(c) Make the interactions that reviewers could not drive off-screen verifiable: put the right-click menu contents, the Quit/Force Quit targets, scroll-position keeping and the tour hole's click-through into testable pieces (pure model/unit tests) and extend the probe so a reviewer can exercise them headlessly.
(d) Fix every remaining Low item the reports list (copy nits, tooltips for expandable rows and group rows, Settings empty space, chip gap, half-covered text under callouts, pid jargon, placeholder names).
Keep resource cost at or below the current HEAD.`
let round = 0
let passed = false
const history = []
while (round < 10 && !passed) {
  round++
  const reviews = await parallel(['A', 'B'].map(who => () => agent(`${RULES}\n\nYou are an INDEPENDENT reviewer, acting as the fresh reviewer subagent of the 'reviewer' skill. Read ~/.claude/skills/reviewer/SKILL.md and its references (scale.md, reviewer-brief.md, capture.md) and follow the reviewer brief + scale exactly. Intake answers (already decided by the owner's request): Scope = everything user-facing in MacStats plus the steadiness of numbers/lists and the new intro/tour; Method = Both (screenshots of the REAL views rendered in an off-screen probe — light and dark, overview, each breakdown incl. an expanded app, Battery, Settings, every tour step — PLUS live-flow simulation: run the real MetricsStore/breakdown logic headlessly for >= 60 s and measure rank swaps, value flips, whether an expanded/hovered row ever moves or disappears; a stability probe may exist under docs/research/ — use it but check it measures the right thing — PLUS code reading of Sources/); Depth = Thorough (you are reviewer ${who}; another reviewer works independently; do not read their report). For tour centering, measure: compute the cutout rect vs. the card rect from the rendered image/geometry and report the four insets in points.\nIndependence: judge what is there; do NOT read docs/superpowers/plans/*, docs/research/*.md conclusions, git log messages or earlier reviews before forming your scores.\n${CALIBRATION}\nWrite the report to docs/reviews/${D}-stability-tour-review-r${round}-${who}.md, images (lean, <= ~5 MB) in docs/reviews/${D}-stability-tour/r${round}-${who}/. Evidence first, then scores. Do not edit source. Commit only your report + images. Return the schema.`, { label: 'review:r' + round + '-' + who, phase: 'Review', schema: REVIEW_SCHEMA })))
  const ok = reviews.filter(Boolean)
  const scores = ok.map(r => r.overall)
  const minArea = Math.min(...ok.flatMap(r => r.areas.map(a => a.score)))
  history.push({ round, scores, minArea, reports: ok.map(r => r.reportPath) })
  log('Round ' + round + ': overall ' + scores.join(' / ') + ', lowest area ' + minArea)
  passed = ok.length === 2 && scores.every(s => s > 9.0) && minArea >= 8.5
  if (passed) break
  const fixes = ok.flatMap(r => r.fixes.map(f => '- [' + f.severity + '] ' + f.issue + ' | evidence: ' + f.evidence + ' | fix: ' + f.fix)).join('\n')
  const fixRes = await agent(`${RULES}\n\nReview round ${round} scored ${scores.join(' and ')} (lowest area ${minArea}); the bar is BOTH overall > 9.0 and no area below 8.5. Reports: ${ok.map(r => r.reportPath).join(', ')} — read them fully. Reviewers' ranked fixes:\n${fixes}\n\nYOUR TASK: verify each finding against the code/probe first (receiving-code-review discipline: don't blindly apply; reject with a reason if wrong), then implement every valid fix, highest severity first, plus anything else needed to raise the lowest areas. Re-run the relevant probes (render probe for visuals — look at the PNGs; stability probe for steadiness). swift build + ./Scripts/test.sh green. Commit. Update ${PROGRESS} with a 'Review round ${round}' section (scores, what was fixed, what was rejected and why). Return the schema.${round >= 6 ? CONSOLIDATE : ''}`, { label: 'fix:r' + round, phase: 'Review', schema: BUILD_SCHEMA })
  log('Fix round ' + round + ': ' + (fixRes ? fixRes.summary.slice(0, 250) : 'FAILED'))
}
if (!passed) log('Review bar not reached after ' + round + ' rounds — reporting honestly; continue in a later run.')

// ---------------- Verify ----------------
phase('Verify')
const VERIFY_SCHEMA = { type: 'object', properties: { summary: { type: 'string' }, problems: { type: 'array', items: { type: 'object', properties: { severity: { type: 'string' }, issue: { type: 'string' }, evidence: { type: 'string' }, fix: { type: 'string' } }, required: ['severity', 'issue', 'evidence', 'fix'] } } }, required: ['summary', 'problems'] }
const verify = await parallel([
  () => agent(`${RULES}\n\nYOUR TASK (find, don't fix): bug hunt the whole diff ${BASE}..HEAD (git diff ${BASE}). Look for correctness bugs, races (main actor vs background scan), retain cycles/leaks (timers, closures, observers), state that can get stuck (tour never ends, overlay blocking clicks, frozen ordering never unfreezing, pinned row after the app quits), edge cases (no battery Mac, 0 processes, app quits while expanded, popover closed mid-tour, reopened, Settings replay, light/dark, reduced motion), persistence bugs, accessibility (VoiceOver labels for the tour). Confirm each finding by reading code or a small headless test; drop anything unconfirmed. Write docs/reviews/${D}-stability-tour-bughunt.md. Return the schema.`, { label: 'verify:bugs', phase: 'Verify', schema: VERIFY_SCHEMA }),
  () => agent(`${RULES}\n\nYOUR TASK (measure, don't fix): MacStats's own resource cost, baseline ${BASE} vs HEAD. Build both (release config, sequentially; baseline in a scratchpad git worktree, removed afterwards). Measure WITHOUT touching the owner's screen: (1) popover closed: a headless run of each build's app binary is not possible without a menu bar icon, so instead write a small harness that links MacStatsCore and drives the same code paths as the closed-popover idle sampler and the open-popover 0.5 s collection + breakdown scan + stability logic for 120 s each; measure CPU time (getrusage / ps -o time) and peak + steady physical footprint (footprint/vmmap or task_info phys_footprint); (2) off-screen render probe of the overview + breakdown + tour views for 60 s with each build: CPU % and footprint. Report deltas with noise ranges (repeat 3x). Anything > ~10% worse or any new work while closed = a problem with its cause. Write docs/reviews/${D}-stability-tour-perf.md. Return the schema.`, { label: 'verify:perf', phase: 'Verify', schema: VERIFY_SCHEMA }),
])
const problems = verify.filter(Boolean).flatMap(v => v.problems)
if (problems.length) {
  const fixV = await agent(`${RULES}\n\nThe bug hunt (docs/reviews/${D}-stability-tour-bughunt.md) and perf check (docs/reviews/${D}-stability-tour-perf.md) found:\n${problems.map(p => '- [' + p.severity + '] ' + p.issue + ' | ' + p.evidence + ' | fix: ' + p.fix).join('\n')}\n\nVerify each, fix the real ones (perf regressions must end up within noise of baseline), add regression tests where pure logic is involved, re-run the perf measurement for anything perf-related and append the after-numbers to the perf doc. swift build + ./Scripts/test.sh green. Commit. Update ${PROGRESS}. Return the schema.`, { label: 'verify:fix', phase: 'Verify', schema: BUILD_SCHEMA })
  log('Verify fixes: ' + (fixV ? fixV.summary.slice(0, 250) : 'FAILED'))
}

// ---------------- Document ----------------
phase('Document')
const docs = await agent(`${RULES}\n\nYOUR TASK: document everything and do the final verification.\n1) Docs (standalone, a fresh session with zero context must be able to use them): update MacStats CLAUDE.md Status with a new dated entry for this work (stability fixes, intuitiveness changes, intro + tour, review scores per round from ${PROGRESS}, perf numbers, open items) and the 'Start here' table; README.md: one short line about the intro/tour and how to replay it (keep the README short, emoji-free); add docs/design-language/guided-tour.md describing the reusable squircle-spotlight tour pattern (geometry rules for perfect centering, copy style, persistence, cost-nothing-when-hidden); finalize ${PROGRESS} with a Results section (scores, numbers, what's left).\n2) Final verification: swift build; ./Scripts/test.sh (report the pass count); then install the new build for the owner with ./Scripts/bundle.sh (it quits the running copy and assembles ~/Applications/MacStats.app) and relaunch it in the background with: open -g ~/Applications/MacStats.app . Do NOT open its popover. Confirm it is running (pgrep -fl MacStats) and measure its closed-popover idle cost for 60 s (ps -o %cpu,rss / footprint) and record it.\n3) Commit docs. Do not push or release. Return a <= 300-word summary with test count, final scores and the install result.`, { label: 'docs+final', phase: 'Document' })

return { research: research.map(r => r ? r.slice(0, 600) : null), plan, buildA, buildB, reviewHistory: history, passed, verify, docs }
```
