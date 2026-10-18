# MacStats: how people learn an app, and what to change so a first-time user gets it in ~30 s

Date: 2026-10-06 · Branch: `feat/stability-tour` (baseline commit `1ed61cf`) · Research only: no source code
was changed for this document.

**Who this is for:** whoever implements the stability fixes, the guided tour and the intro for MacStats
(the native Swift macOS menu-bar system monitor in this repo). It has three parts: what research says about
how people learn and read apps (part 1), an audit of MacStats as it is at `1ed61cf` (part 2), and a ranked
list of small, concrete changes with exact strings (part 3). Part 4 sketches the tour and intro. Sources are
listed at the end.

Screenshots of the current UI are in `docs/research/2026-10-06-ux-audit/`. They were rendered off-screen
from the real SwiftUI views with fake data (see "How the screenshots were made" at the end), so the
numbers in them are made up but the layout and wording are real.

---

## Terms used in this document

| Term | Meaning |
|---|---|
| **NN/G** | Nielsen Norman Group, the usability research firm most cited below. **HIG** = Apple's Human Interface Guidelines. **AM** = Activity Monitor (macOS's built-in process viewer). **pid** = process ID. |
| **Popover / panel** | The window that opens under the MacStats menu-bar icon (`MenuBarExtra(.window)`, 320 × 404 pt). |
| **Overview** | The panel's first screen: CPU, Memory, Network, Battery cards, the Trash row, and the footer (Quit, gear). |
| **Card** | One rounded rectangle on the overview (e.g. the CPU card). |
| **Drill-in / breakdown** | The screen you get by clicking the CPU, Memory or Battery card: a ranked list of apps. |
| **Row / expand** | One app in a breakdown. Apps with several processes have a `›` and can be expanded to show them. |
| **Context menu** | The menu that appears on right-click (or Control-click / two-finger click). MacStats puts Quit and Force Quit there. |
| **Tooltip** | The small yellow-ish label macOS shows after hovering ~1–2 s (SwiftUI `.help`). |
| **Affordance** | What an element *can* do (a card can be clicked). |
| **Signifier** | The visible clue that tells you it can (a `›` chevron, a hover highlight). Don Norman's distinction. |
| **Cognitive load** | Mental effort needed to use the UI. *Intrinsic* load comes from the task itself; *extraneous* load is effort the design adds without helping (e.g. two numbers that mean the same thing). |
| **Hick's law** | Decision time grows with the number of choices (roughly with log₂ of the count). |
| **Recognition over recall** | People find it easier to recognise an option they can see than to remember one they can't. |
| **Progressive disclosure** | Show the common things first; put advanced detail one step deeper. |
| **Information scent** | How well a label/icon predicts what you'll get if you click it. |
| **Change blindness** | People fail to notice changes they aren't attending to, even big ones. |
| **Attentional capture** | Sudden motion or appearance pulls the eyes there whether you want it or not. |
| **Preattentive features** | Colour, length, size, motion etc. that the eye picks out in < 250 ms, before conscious search. |
| **Layout shift** | Content moving while you're looking at it or about to click it. |
| **Coach mark / tag** | A small callout pointing at one real control. A **tour** is a short sequence of them. BetterScreenshot's TourKit calls a step's callout a *tag* and the control it outlines the *anchor*. |
| **Push vs. pull help** | *Push*: shown unasked (a tour on launch). *Pull*: shown when the user signals interest (hover tooltip, a "?" button, a tour started from a menu). |
| **Permission priming** | Explaining in your own UI why you'll ask for a permission, before macOS shows its system prompt. |
| **Concentric corners** | A rounded shape inside another, inset by *d*, uses radius = outer radius − *d*, so the gap stays even around the corner. MacStats: panel 16 pt, cards 8 pt (inset 8). |

---

## Part 1 — What the research says, and what it means for MacStats

### 1.1 Cognitive load: cut what doesn't help, not what does

- NN/G separates **intrinsic** load (the task) from **extraneous** load (the design's own noise) and says to
  minimise the second: redundant elements, meaningless styling, and anything that doesn't help the user
  understand the content slow people down. Building on existing mental models (how other apps work) is the
  main way to keep it low. [NN/G, Minimize Cognitive Load]
- Working memory holds about **4 chunks** for adults (Cowan 2001; Miller's older "7 ± 2" is now seen as an
  overestimate). [Cowan 2001]

**For MacStats:** each extra number on a row is a chunk the eye has to place. The CPU list currently shows
two numbers per app ("9.8%" and "78% of one core", same quantity on two scales) — 16 numbers on screen for
8 apps. That is extraneous load and invites "which one is right?" doubts.

### 1.2 Hick's law and "how complicated does it feel"

- Choice time rises with the number of options (Hick 1952; Hick–Hyman law). Practical reading: every
  visible control competes; fewer, clearly grouped choices feel simpler. [Laws of UX, Hick's law]
- **Gestalt proximity:** things close together are read as one group; things apart as different roles.
  [NN/G, Proximity]
- **Jakob's law:** people spend most of their time in *other* apps, so they expect yours to behave like
  those. For a Mac menu-bar utility the "other apps" are Control Center, the Battery menu and Activity
  Monitor. [Laws of UX, Jakob's law]

**For MacStats:** the overview already has very few choices (3 clickable cards, Empty, Quit, gear) and a
calm grid — this is a strength. Keep it that way: don't add buttons to cards; put new things one level deep.

### 1.3 Recognition over recall, and progressive disclosure

- Nielsen's heuristic #6: make elements, actions and options visible; the user shouldn't have to remember
  how to reach them. [NN/G, Recognition and Recall; NN/G, 10 Heuristics]
- Progressive disclosure: show the most important options first, specialised ones on request; it makes apps
  easier to learn and less error-prone. [NN/G, Progressive Disclosure]

**For MacStats:** the overview → drill-in → expand structure *is* progressive disclosure, which is good. The
one thing that breaks recognition is **Quit/Force Quit living only behind right-click**: nothing visible
says it exists.

### 1.4 Signifiers: how people know something is clickable

- Norman: affordances are what's possible; **signifiers** are the visible cues that announce them. Designers
  have to supply signifiers on screens because nothing physical does. [Norman 2008/2013]
- NN/G eyetracking (71 participants, 9 sites): pages with **weak/flat signifiers took 22 % longer and drew
  25 % more fixations** than the same pages with strong ones; long exposure trains people to hover and click
  around uncertainly. [NN/G, Flat UI Elements]
- Hidden context menus: "because the default view of a contextual menu is usually hidden, users may not
  know it is available"; commands in a context menu should also be reachable another way.
  [NN/G, Contextual Menus guidelines]
- Tooltips: don't put information needed to complete the task only in a tooltip — users shouldn't need to
  find a tooltip to succeed. Tooltips are good for *extra* detail and for teaching shortcuts.
  [NN/G, Tooltip Guidelines]

**For MacStats:** cards have strong signifiers (trailing `›`, hover fill, press scale) — good. App rows'
expand `›` is a weak-to-medium signifier (small, tertiary grey, and only some rows have it, with no
explanation of why). Right-click Quit has **no** signifier. Several explanations (Wired, Compressed,
System, Other processes) live only in tooltips; that's acceptable because they're extra detail, but the
labels themselves must be understandable without them.

### 1.5 Moving numbers, re-sorting lists and "jumpiness"

- **Change blindness:** in Rensink's flicker experiments, people missed even large changes unless attending
  exactly there. Attention is required to *see* a change. [Rensink et al. 1997]
- **Attentional capture:** abrupt onsets and motion grab attention involuntarily (Yantis & Jonides 1984).
  [Yantis & Jonides 1984]
- Motion and flicker are **preattentive** features: detected in < 250 ms whether you want to or not.
  [Healey, Perception in Visualization]

  Together: every value that ticks pulls the eye, but the reader can't actually take in the change. A screen
  where many things tick at once is tiring and *reads less*, not more.
- **Real-time dashboards:** past the rate at which a person can read a value before it changes, faster
  updates *reduce* usability; keep layouts stable during interaction and let only decision-relevant values
  move. [Smashing Magazine, UX Strategies for Real-Time Dashboards]
- **Layout shift:** content moving as you're about to click causes misclicks and loss of place; it's
  uniquely frustrating because it actively interferes with what the user is doing. [web.dev / CLS write-ups]
- **Response-time limits:** 0.1 s feels instant, 1 s keeps flow, 10 s keeps attention. [NN/G, Response
  Times]. Animation: 100–500 ms; the more frequent the animation, the shorter and subtler it should be.
  [NN/G, Animation Duration]
- **The reference app is slower on purpose:** Activity Monitor updates **every 5 seconds by default**
  (View → Update Frequency). [Apple Support, Activity Monitor update frequency]

**For MacStats (this is the owner's complaint #1):** the overview recomputes every 0.5 s and the breakdown
re-sorts every 1 s (`breakdownScanInterval = 1.0`, `RefreshScheduler.swift`). A light app at ~2 % that
dips for one scan swaps places with its neighbours; the row under the pointer changes, the hover highlight
jumps, and a click intended for VS Code can land on a different app (or toggle the expansion off). That
matches exactly what the owner reported. The research says: **slow what is read, freeze what is pointed at,
keep moving only what is glanced at (graphs).** Concretely in Part 3, item 1.

### 1.6 Onboarding: tours, coach marks, intros

- NN/G study (70 users, 4 apps): people who went through a deck-of-cards tutorial had **no better task
  success** (91 % vs 94 % for those who skipped, not significant) and rated the tasks **harder** (4.92 vs
  5.49 out of 7, significant). Tutorials "don't make users faster or more successful … they make them
  perceive the tasks as more difficult." Time is better spent making the UI itself clear.
  [NN/G, Mobile Tutorials]
- Push help (shown unasked) interrupts, is forgotten because it's out of context, and costs effort to
  dismiss; pull help (contextual, user-triggered) works better. Don't explain obvious conventions (e.g. that
  a gear means Settings). [NN/G, Onboarding Tutorials vs. Contextual Help]
- Coach marks: short, focused, scannable and sparse; avoid long chains; show at first encounter.
  [NN/G, Instructional Overlays and Coach Marks]
- Tour length, from Chameleon's benchmark of millions of tour views: **3-step tours ~72 % completion,
  4-step tours highest, 7-step ~16 %**; beyond 5 steps more than half of users drop. **Self-triggered tours
  get about 2× the engagement** of automatic ones; immediate on-page-load modals do worst (39 %);
  **progress indicators ("2 of 4") add ~12 %**. [Chameleon Benchmark Report 2025; Chameleon blog]
- Apple HIG (Onboarding): "Design a flow that's fast, fun, and optional." "Teach through interactivity."
  "Consider providing a collection of context-specific tips instead of a single onboarding flow." If people
  skip the tutorial, "don't present it again on subsequent launches, but make sure it's easy for people to
  find if they want to view it later." Put needed permission requests into onboarding so you can explain
  why. [Apple HIG, Onboarding]
- Permission priming: explaining a permission in your own UI before the system prompt raises grant rates
  and avoids a cold, confusing prompt. [Permission-priming write-ups, e.g. Appcues/Adjust figures cited by
  PushEngage]

**For MacStats:** the owner wants a skippable tour plus an introduction (like BetterScreenshot/JVoice). The
research supports that *if* it is: optional (asked, not forced), **≤ 4 steps**, numbered, interactive where
possible ("click the CPU card"), never auto-repeated, and replayable from Settings. The intro's real job is
not teaching the cards (they're self-explanatory) but three things the UI can't show by itself: **where the
app is** (menu bar, no Dock icon), **why macOS is about to ask for permissions**, and **the hidden actions**
(expand, right-click Quit).

### 1.7 Apple HIG on menu-bar extras

From the HIG "The menu bar" page:
- "When necessary, the system hides menu bar extras to make room for app menus." "Avoid relying on the
  presence of menu bar extras … you can't be sure which other menu bar extras people have chosen to display
  or predict the location of your menu bar extra."
- "Display a menu — not a popover — when people click your menu bar extra. Unless the app functionality …
  is too complex for a menu." (MacStats's live graphs justify the popover.)
- "Consider exposing app-specific functionality in other ways, too."

**For MacStats:** on a MacBook with a notch and many menu-bar icons, the MacStats icon can be hidden. The
app has no Dock icon (`LSUIElement = true`) and doesn't react to being launched again (no reopen handling
in `Sources/MacStatsApp`), so a new user who installs it and sees nothing has **no way to find it**. The
intro must point at the icon, and relaunching the app (Spotlight / Applications) should do something
visible.

---

## Part 2 — Audit of MacStats today (`1ed61cf`)

Files read: `Sources/MacStatsApp/{OverviewView, StatCard, RootView, Design, BreakdownView, MemoryPartsCard,
BatteryDetailsCard, SettingsView, MenuBarLabel, TrashActions, ProcessActions, AlertNotifier,
MacStatsApp}.swift`, `Resources/Info.plist`. Screens rendered: overview (dark/light, charging, no battery),
CPU / Memory / Battery breakdowns, CPU expanded, "Measuring…", Settings.

### 2.1 First 30 seconds, as a new user experiences it now

1. Run the curl installer → the app launches. **Nothing visible happens** except, immediately, a macOS
   **notification-permission prompt** with no context (`AppModel.init` → `notifier.requestAuthorization()`,
   `MacStatsApp.swift:108`), and MacStats silently registers as a login item.
2. The user has to spot a small sparkline glyph in the menu bar (may be hidden behind the notch).
3. First click → the overview opens, and at once macOS asks **"MacStats wants to control Finder"**
   (the Trash size read on open, `refreshTrashSize()`). Nothing in MacStats explained this. If the user
   clicks *Don't Allow*, the Trash row shows "—" with a disabled Empty button forever, with no explanation.
4. The overview itself is clear: four labelled cards, big values, graphs. **This part passes the 30-second
   test** — CPU / Memory / Network / Battery are recognised instantly.
5. What the user can't discover without help: that the `›` cards open per-app lists (likely found by
   curiosity — strong signifier), that apps with `›` expand, that **right-click** quits an app, and what the
   gear does (convention, fine).

### 2.2 Every visible string, with verdict

Overview (`OverviewView.swift`, `StatCard.swift`):

| Where | Current text | Verdict |
|---|---|---|
| Header | `MacStats` | Fine (brand, orients the user). |
| CPU card meta | `47°C` / fallback `live` | Temp is fine (it's under "CPU"). **`live` means nothing** to a user — it's what shows on Macs without a usable sensor. |
| Memory card value | `10.4 / 16.0 GB` | Clear. |
| Memory card meta | `● normal` / `warning` / `critical` | "normal" *what*? The word "pressure" is missing; "warning" is a UI state, not a level. Alerts call it "Memory pressure high". |
| Network | `↓ 33 KB/s` / `↑ 14 KB/s` | Clear to most; graph is download only (not stated). Fine. |
| Battery meta | `4h left`, `38m to full`, `fully charged`, `not charging`, `calculating…`, `no battery` | Clear. |
| Trash row | `Trash  803 MB  [Empty]`; when 0: `Trash  empty  [Empty]` | When the Trash is empty the row reads **"empty Empty"** — adjective and verb side by side. When permission is missing it reads `—` with no way forward. |
| Footer | `Quit` | Ambiguous next to app-level "Quit" actions elsewhere; Apple menu-bar apps say "Quit <App>". |
| Footer | gear (tooltip "Settings") | Convention; fine. Its corner radius is 6 pt while Quit's is 8 pt (see 2.4). |

CPU breakdown (`BreakdownView.swift`):

| Where | Current text | Verdict |
|---|---|---|
| Header | `‹ CPU` … `23% used` | Clear. |
| Row | `Code` · bar · `78% of one core` · `9.8%` · `›` | **Two numbers for one thing.** New users can't tell which is "the" number; the bar shrinks to ~45 pt to make room for the text column (vs ~140 pt in Memory/Battery). |
| Group rows | `System`, `Other processes` | Names OK; tooltips are long (System's is 30 words). |
| Footer | `Share of the whole Mac (all 8 cores)` | OK; slightly abstract. |
| Loading | `Measuring…` / `Sampling CPU usage` | Second line says the same as the first; doesn't set an expectation of how long. |
| Empty | `No apps` | Odd for a Mac that obviously runs apps; only shows in an edge state. |
| Context menu | `<name>`, `78% of one core`, `Quit`, `Force Quit…` | Good wording; hidden (see 2.3). |
| Process rows | `Code 58374`, `Exited processes` | pid in tertiary grey is fine for the expanded (expert) level. |

Memory breakdown (`MemoryPartsCard.swift`, `BreakdownView.swift`):

| Where | Current text | Verdict |
|---|---|---|
| Parts card | `App Memory` `Wired` `Compressed` | Activity Monitor's terms — good for recognition by people who know AM, jargon for everyone else. Tooltips exist but are technical ("kernel and drivers", "compressed app data … at full size"). |
| Footer | `Rows are each app's footprint (as in Activity Monitor); they don't add up to Memory Used` | **Wraps to 2 lines** and crowds the Quit button (screenshot `breakdown-memory-light.png`). "Footprint" and "Memory Used" are jargon; "Memory Used" isn't a label anywhere on screen (the header says "used"). |

Battery breakdown (`BatteryDetailsCard.swift`):

| Where | Current text | Verdict |
|---|---|---|
| Rows | `Status`, `Time left`, `Time to 85%`, `Optimized Charging`, `Charge limit` | Clear (matches the macOS Battery menu). |
| Row | `Power, last min` | Telegraphic; reads like a note to self. |
| Row | `Avg awake since unplugged` / `Avg awake since MacStats started` | Abbreviation + odd word order; "awake" qualifier is a technical caveat. |
| Row | `Health  91% · 212 cycles`, `Temperature  31 °C` | Clear. Temperature uses `31 °C` (space) while the CPU card uses `47°C` (no space). |
| Value | `4h` | Coarse rounding is deliberate (honest), but nothing says it's approximate. |
| Footer | `App power counts CPU only` | OK; could say what it excludes. |

Settings (`SettingsView.swift`): `APPEARANCE`, `Opacity`, `Default`, `Transparent … Opaque`,
`How much of what's behind shows through the panel.` — all clear. No way to see the tour again (will be
needed).

System dialogs: `Empty the Trash?` / `Items in the Trash will be permanently deleted.` / `Empty Trash`;
`Force quit "X"?` / `The app will quit immediately and you'll lose any unsaved changes.` — good, match macOS.
Notifications: `High CPU usage` / `CPU has been above 85% for the last 30 seconds.`; `Memory pressure high` /
`Your Mac is low on available memory.` — good.

"Overhead" and "Wired/Compressed" questions from the brief: **"Overhead" does not appear in the UI** (it's a
review-report category). "Wired" and "Compressed" do; see item 6 below.

### 2.3 Every clickable thing — can a first-time user tell?

| Element | Signifier today | Discoverable? |
|---|---|---|
| CPU / Memory / Battery cards → drill-in | Trailing `›`, hover fill, press scale | **Yes.** Strong. |
| Network card | No `›`, no hover (correctly not clickable) | Correct. |
| Empty (Trash) | Real button | Yes. |
| Quit / gear | Real buttons; gear has tooltip | Yes. |
| `‹ CPU` back | Chevron + title | Yes (iOS/Control Center convention). No hover feedback; **Esc doesn't go back**. |
| App row expand | Small tertiary `›` that rotates; only on multi-process apps | **Partly.** Users may read `›` as "opens a screen" (same glyph as cards). Rows without `›` give no reason. |
| Right-click → Quit / Force Quit | **None** | **No.** Pure recall; NN/G says hidden context menus aren't found. |
| Process row right-click | None | No (expert level, acceptable). |
| "N more…" row | Text only | Yes, reads as a link. |
| Memory parts tooltips | None (hover 1–2 s) | Extra detail only — acceptable. |
| Opacity slider / Default | Standard controls | Yes. |

### 2.4 Alignment, centring, spacing (measured on the 2× renders)

Good:
- Left edges line up: header title, card labels and values all start 20 pt from the panel edge
  (`panelInset 8 + cardPadding 12`).
- Graph column starts at the same x on all four cards (fixed 120 pt value column), gauge vertically centred
  in the same 38 pt slot as the sparklines.
- Breakdown value column (58 pt, trailing) lines up between app rows and process rows; header trailing text
  sits 20 pt from the right edge, matching card content.
- Measuring state is centred in the list card; Settings card follows the same inset.
- Corners: panel 16, cards 8 (concentric with 8 pt inset), row highlights 4 inside 4 pt list padding.

Issues:
1. **Gear button radius is 6 pt, Quit's is 8 pt.** `SettingsButton` uses `SubtleButtonStyle()` (default
   6) but the two buttons sit in mirror-image panel corners; only Quit is concentric with the panel's 16 pt
   corner (`SettingsView.swift:83`). The CLAUDE.md status note says both use `Design.cardCornerRadius`; the
   code disagrees.
2. **Footer text vs header text trailing edges differ:** header trailing text ends 20 pt from the edge,
   footer footnotes end ~9 pt from the edge (they sit in the button row). Small, but visible when the push
   transition aligns the two screens.
3. **Memory footer wraps to two lines** and its first line sits higher than the Quit label's baseline.
4. **CPU rows' bars are ~45 pt** (the "% of one core" column takes 88 pt) vs ~140 pt on Memory/Battery
   rows — the same component looks different per screen, and short bars carry little preattentive signal.
5. Trash row uses 7 pt vertical padding vs cards' 9 pt — intentional (secondary row), fine.

### 2.5 Jumpiness sources seen in code (for the stability work)

- Overview: every value re-renders every 0.5 s (`refreshInterval(.popoverOpen) = 0.5`). The 0.25 s
  interpolate fade runs twice a second on 6–8 numbers → constant motion in peripheral vision.
- Breakdown: full re-sort every 1 s with `sortedRows` (ties by pid only); no hysteresis, no freeze while the
  pointer is over the list. Rows animate to new positions under the cursor.
- Expanded app: `expanded` is keyed by app pid, so the expansion survives a re-sort *logically*, but the
  row moves, so the next click often lands on a different row (toggling/expanding the wrong one), which
  the user perceives as "the expansion goes away".
- Light apps hover around the 1-decimal display threshold (e.g. 1.9 ↔ 2.1 %), so even unchanged ranks
  flicker digits.

---

## Part 3 — Ranked changes (small, concrete, Apple-look-preserving)

Ranked by how much each moves "understands it within ~30 s / stops feeling jumpy" per unit of code.
Each item says *what*, *why (research)*, and *exact strings* where copy changes. None adds a timer while
the popover is closed or an extra per-process scan.

### 1. Make it calm (owner's #1) — for the stability implementer
Research: change blindness, attentional capture, layout shift, Activity Monitor's 5 s default.
- **Freeze row order while the pointer is inside the breakdown list or an app is expanded.** Values keep
  updating in place; order is re-applied (animated) when the pointer leaves. This alone fixes "can't open
  VS Code".
- **Hysteresis on re-sort** when not frozen: an app only moves above its neighbour if it leads by a margin
  (e.g. ≥ 0.5 percentage points CPU / ≥ 5 % relative memory) for 2 consecutive scans. Ranking stays
  truthful within noise.
- **Display cadence ≠ sample cadence.** Keep sampling at 0.5 s (graphs keep sliding — they are glanced at,
  not read), but update *text* values ~1×/s on the overview and ~2 s on breakdown rows, or show breakdown
  rows as a short moving average (~2–3 s). Header totals keep their audited values; this is display
  smoothing only, the readings stay accurate. Activity Monitor itself shows 5 s.
- Don't animate row reordering faster than ~250 ms and don't animate value fades on every tick
  (NN/G: frequent animation should be short and subtle).

### 2. Point people at the app and explain permissions before macOS asks (intro)
Research: HIG menu-bar extras (icon may be hidden), HIG onboarding (permissions inside onboarding),
permission priming.
- On first launch show one small **welcome window** (JVoice-style, see Part 4) instead of firing the
  notification prompt cold. Move `notifier.requestAuthorization()` behind the intro's "Turn On Alerts"
  (or the end of the intro). Don't read the Trash size (Finder Automation prompt) until the intro is done.
- **Relaunching MacStats while it's running** (from Spotlight/Applications) should open the welcome window
  (or a small "MacStats is in your menu bar" panel) — the only way a user with a hidden icon can find it.
- Trash row when Finder permission is missing: value `Needs permission` and the button becomes
  `Allow…`, which explains and opens System Settings → Privacy & Security → Automation
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_Automation`).

### 3. One number per CPU row
Research: cognitive load (one quantity, one number), Hick, Jakob (most users never compare with AM).
- Remove the always-visible `NN% of one core` text from CPU rows; keep it in the tooltip and context menu
  (already there), or show it **only while hovering that row** in place of nothing (no layout change).
  The bar regains its full width, matching Memory/Battery rows. *Owner decision:* this was added on
  purpose in round 3 for Activity Monitor comparison; hover-only keeps that ability.
- Footer: `Share of the whole Mac (all 8 cores)` → **`% of the whole Mac · hover an app for % of one core`**
  (if hover-only) or keep the current string if the text is removed entirely.

### 4. Make the hidden actions visible without clutter
Research: signifiers (NN/G flat UI), hidden context menus, tooltip guidelines.
- **App-row tooltip for every real app** (not just CPU): `Click to show its N processes · Right-click to
  quit` (multi-process) / `Right-click to quit` (single process). Group rows keep their explanation.
- **Breakdown footer hint for the first 3 drill-ins** (stored count, no timer): replace the footnote with
  `Right-click an app to quit it` the first three times a breakdown opens, then show the normal footnote.
  Zero layout change, recognition at the moment of need (pull help).
- Make the row expand chevron slightly stronger: `.secondary` instead of `.tertiary` (matches the card
  chevrons), so "this row opens" reads at a glance.
- **Esc goes back** from a drill-in/Settings (`.onExitCommand` / `keyboardShortcut(.cancelAction)` on the
  back button) — every macOS sheet/popover user expects it.

### 5. Copy fixes on the overview (exact strings)
| Element | Now | New | Why |
|---|---|---|---|
| CPU meta when no temperature | `live` | *(empty — keep the line height)* | "live" carries no information. |
| Memory meta | `normal` / `warning` / `critical` | `pressure normal` / `pressure high` / `pressure critical` | Says *what* is normal; matches the alert "Memory pressure high". Fits the 120 pt column at caption2. |
| Trash value, 0 bytes | `empty` | `Nothing in it` *(button stays, disabled)* | Avoids "empty Empty". |
| Footer button | `Quit` | `Quit MacStats` | Unambiguous next to the per-app Quit; Apple menu-bar apps use "Quit <App>". |
| Network value tooltip | *(none)* | `Download speed` / meta: `Upload speed` | Arrows are clear to most, tooltip covers the rest. |
| CPU temperature format | `47°C` | `47 °C` (or change Battery's to `31°C`) | One format app-wide. |

### 6. Copy fixes in the drill-ins (exact strings)
| Element | Now | New |
|---|---|---|
| Memory footer | `Rows are each app's footprint (as in Activity Monitor); they don't add up to Memory Used` | **`Each app's memory, as Activity Monitor counts it`** (one line). Move the rest into its tooltip: `Compressed memory counts at full size here, and macOS's own processes aren't listed, so the rows don't add up to the total above.` |
| `App Memory` tooltip | `Memory in use by every process (yours, macOS's and other users'), not counting what is compressed` | `Memory apps and macOS are using right now` |
| `Wired` tooltip | `Memory the kernel and drivers keep in RAM; it can't be compressed or freed` | `Memory macOS keeps for itself. It can't be freed.` |
| `Compressed` tooltip | `RAM holding X GB of compressed app data. The rows below count that data at full size.` | `X GB of app data squeezed into less RAM to make room. Normal, not a problem.` |
| `System` tooltip (30 words) | `The kernel, WindowServer, other users' processes, commands run with sudo, and processes that exited before they could be traced to an app` | `macOS itself: the kernel, WindowServer and other system work` |
| `Other processes` tooltip | `Your background processes that no app is responsible for` | `Background tasks that don't belong to an open app` |
| Measuring sub-line | `Sampling CPU usage` / `Sampling energy use` | `Takes about a second` (both) |
| Empty list | `No apps` | `Nothing to show yet` |
| Battery `Power, last min` | — | `Power now` + tooltip `Average over the last minute` |
| Battery `Avg awake since unplugged` | — | `Average since unplugged` + tooltip `Counts only time the Mac was awake` |
| Battery `Avg awake since MacStats started` | — | `Average this session` + same tooltip |
| Battery time left value | `4h` | `About 4h` (card meta stays `4h left`) |
| Battery footer | `App power counts CPU only` | `App power counts CPU only, not screen or GPU` |

Keep the Activity Monitor names `App Memory / Wired / Compressed` themselves: people who look further will
recognise them (Jakob's law), and the plain-language tooltips cover everyone else.

### 7. Small layout fixes
- Gear button: `SubtleButtonStyle(cornerRadius: Design.cardCornerRadius)` (concentric with the panel corner,
  same as Quit). `SettingsView.swift`, `SettingsButton`.
- Breakdown footnote: trailing padding so its right edge matches the header's trailing text
  (`.padding(.trailing, Design.cardPadding - Design.panelInset)` → 4 pt, puts text 12 pt in) — or accept the
  difference; it's minor. Single-line footnotes (item 6) remove the two-line crowding.
- With item 3, CPU rows get the same bar length as Memory/Battery rows.

### 8. Settings gets a "Help" card
- New card under Appearance: `HELP` · `Show Tour` (SubtleButtonStyle) · caption
  `A 4-step look at what you can click.` HIG: a skipped tour must be "easy to find" later. Fills the empty
  Settings screen without adding anything to the overview.

### Not recommended
- No always-visible "?" buttons on cards, no badges, no hint text on the overview — the overview already
  passes the 30-second test; adding help there would raise extraneous load (NN/G tutorials study: help
  makes simple apps *feel* harder).
- No auto-starting tour. Ask once ("Want a quick tour?"), honour "Not Now", never re-show automatically.
- No per-row Quit buttons revealed on hover — they'd move/appear under the pointer in a live list (layout
  shift) and duplicate the context menu.

---

## Part 4 — Intro and tour sketch (for the tour implementer)

### 4.1 Intro (one window, JVoice/BetterScreenshot style, shown once on first launch)
Title: **`MacStats is in your menu bar`**
Body: `Click [sparkline icon] at the top right of your screen to see CPU, memory, network and battery.`
(If the icon is hidden by the notch, macOS hides it — add: `Don't see it? Make room by quitting another
menu-bar app, or hold ⌘ and drag icons to rearrange.`)
Two permission lines (each with its own button, both optional):
- `Alerts` — `Get a notification when your Mac stays busy or runs low on memory.` → **Turn On** (fires the
  system prompt now, in context).
- `Trash` — `MacStats asks Finder for the Trash size so you can empty it from here.` → **Allow** (fires the
  Automation prompt now).
Bottom: `Want a quick tour?` · **Show Me Around** (default) · **Not Now**. Footnote: `You can find it later
in Settings.`

### 4.2 Tour (4 steps, numbered "1 of 4", skippable on every step, Esc = skip)
Bodies ≤ ~70 characters so a tag fits two lines (BetterScreenshot `TagFitTests` rule).

| # | Anchor | Kind | Title | Body |
|---|---|---|---|---|
| 1 | CPU card (or the 4 stat cards as one group) | Try: advances when a card is clicked | `Live usage` | `Click CPU, Memory or Battery to see which apps use it.` |
| 2 | First app row in the breakdown | Explain | `Apps, ranked` | `Click an app with › to see its processes.` |
| 3 | Same row | Explain | `Quit from here` | `Right-click any app to quit it.` |
| 4 | Gear button | Explain | `Settings` | `Opacity, and this tour again, live here.` |

Trash and Network need no step (self-explanatory labels and a real button). If a step's anchor is missing
(no battery, empty list), skip it and renumber, as TourKit already does.

### 4.3 Highlight geometry — exactly concentric
The cards sit 8 pt inside a 16 pt panel corner with 8 pt radii. Outset the highlight ring by
**d = 4 pt = `Design.panelInset / 2`**: ring rect = card frame inset by −4, radius = 8 + 4 = **12 pt**
(`RoundedRectangle(cornerRadius: 12, style: .continuous)`). That is concentric with the card (8 + 4) *and*
with the panel (16 − 4), and leaves an even 4 pt gap to the panel edge — the "perfectly centred" look.
Draw the stroke *inside* that path (`strokeBorder`) so a 2 pt line doesn't spill. Dim the rest with the
same path cut out (even-odd fill). For a footer button (radius 8 at the panel corner, 0 pt gap) use
d = 4 too → radius 12; for app rows (radius 4, inside the list card's 4 pt padding) use d = 2 → radius 6
so the ring stays inside the list card. Compute rects from the anchor view's real frame (anchor preference
or `NSView` frame), never hard-coded offsets.

---

## How the screenshots were made (to reproduce)

A throwaway SwiftPM package copies `Sources/MacStatsCore`, `Sources/CAppleSensors` and the needed view
files from `Sources/MacStatsApp` (Design, StatCard, OverviewView, BreakdownView, MemoryPartsCard,
BatteryDetailsCard, SettingsView, Sparkline, Appearance, ProcessActions) plus a `main.swift` that fills a
real `MetricsStore` with fake samples and renders each view in a borderless window at
`CGWindowLevelForKey(.desktopWindow) + 1`, `orderBack(nil)`, captured with `CGWindowListCreateImage(…,
.optionIncludingWindow, …)` and closed. The probe sources are saved next to the images:
`docs/research/2026-10-06-ux-audit/probe-main.swift` and `probe-Package.swift` (in the copy of
`BreakdownView.swift`, `@State private var expanded: Int32?` was changed to `= probeExpanded` to render an
expanded row). Build with `export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk; swift
build`, run with `(./.build/debug/Probe out & PID=$!; (sleep 90; kill $PID) & wait $PID)`.
The glass background is an `NSVisualEffectView(.popover)`, so the panel tint differs slightly from the real
Liquid Glass popover; the expanded-row render had duplicate fake pids and is not included.

---

## Sources

- NN/G — Onboarding Tutorials vs. Contextual Help: https://www.nngroup.com/articles/onboarding-tutorials/
- NN/G — Mobile Tutorials: Wasted Effort or Efficiency Boost?: https://www.nngroup.com/articles/mobile-tutorials/
- NN/G — Instructional Overlays and Coach Marks for Mobile Apps: https://www.nngroup.com/articles/mobile-instructional-overlay/
- NN/G — Minimize Cognitive Load to Maximize Usability: https://www.nngroup.com/articles/minimize-cognitive-load/
- NN/G — Progressive Disclosure: https://www.nngroup.com/articles/progressive-disclosure/
- NN/G — Memory Recognition and Recall in User Interfaces: https://www.nngroup.com/articles/recognition-and-recall/
- NN/G — 10 Usability Heuristics for User Interface Design: https://www.nngroup.com/articles/ten-usability-heuristics/
- NN/G — Information Scent: https://www.nngroup.com/articles/information-scent/
- NN/G — Flat UI Elements Attract Less Attention and Cause Uncertainty: https://www.nngroup.com/articles/flat-ui-less-attention-cause-uncertainty/
- NN/G — Designing Effective Contextual Menus: 10 Guidelines: https://www.nngroup.com/articles/contextual-menus-guidelines/
- NN/G — Tooltip Guidelines: https://www.nngroup.com/articles/tooltip-guidelines/
- NN/G — Proximity Principle in Visual Design: https://www.nngroup.com/articles/gestalt-proximity/
- NN/G — Response Time Limits: https://www.nngroup.com/articles/response-times-3-important-limits/
- NN/G — Executing UX Animations: Duration and Motion Characteristics: https://www.nngroup.com/articles/animation-duration/
- Laws of UX — Hick's Law: https://lawsofux.com/hicks-law/ · Jakob's Law: https://lawsofux.com/jakobs-law/
- Hick's law (Hick 1952, Hick–Hyman): https://en.wikipedia.org/wiki/Hick%27s_law
- Cowan, N. (2001). The magical number 4 in short-term memory. *Behavioral and Brain Sciences* 24: https://www.ai.rug.nl/~niels/publications/cowanBBS.pdf
- Norman, D. (2008). Signifiers, not affordances. *interactions*: https://www.alice.id.tue.nl/references/norman-2008.pdf
- Rensink, O'Regan & Clark (1997). To see or not to see: the need for attention to perceive changes in scenes. *Psychological Science* 8(5): https://www2.psych.ubc.ca/~rensink/publications/download/PsychSci97-RR.pdf
- Yantis & Jonides (1984). Abrupt visual onsets and selective attention: evidence from visual search. *JEP:HPP* 10: 601–621 (summary: https://link.springer.com/article/10.3758/BF03208805 , PubMed follow-up https://pubmed.ncbi.nlm.nih.gov/2137514/)
- Healey, C. — Perception in Visualization (preattentive features): https://www.csc2.ncsu.edu/faculty/healey/PP/
- Smashing Magazine (2025) — From Data To Decisions: UX Strategies For Real-Time Dashboards: https://www.smashingmagazine.com/2025/09/ux-strategies-real-time-dashboards/
- Cumulative Layout Shift (frustration, misclicks): https://www.debugbear.com/docs/metrics/cumulative-layout-shift
- Chameleon — User Onboarding Benchmark Report 2025: https://www.chameleon.io/benchmark-report · step-count figures: https://www.chameleon.io/blog/effective-product-tour-metrics
- Apple HIG — Onboarding: https://developer.apple.com/design/human-interface-guidelines/onboarding (text mirror used for quotes: https://github.com/incrediblecrab/apple-os-documentation/blob/main/human-interface-guidelines/patterns/onboarding.md)
- Apple HIG — The menu bar (Menu bar extras): https://developer.apple.com/design/human-interface-guidelines/the-menu-bar (mirror: `human-interface-guidelines/components/the-menu-bar.md` in the same repo)
- Apple Support — Change how often information is updated in Activity Monitor: https://support.apple.com/guide/activity-monitor/change-how-often-information-is-updated-actmntr2224/mac
- Permission priming (grant-rate figures, Appcues/Adjust cited): https://www.pushengage.com/ios-push-notification-permission/
- Internal: BetterScreenshot TourKit (`/Users/davidghermansteinberg/Desktop/Home/Projects/Code/BetterScreenshot/Packages/TourKit`, `App/Tours/CLAUDE.md`), JVoice welcome (`/Users/davidghermansteinberg/Desktop/Home/Projects/Code/JVoice/Sources/JVoice/UI/WelcomeWindow.swift`).
