# MacStats

A lightweight macOS **menu-bar system monitor**. Lives next to your battery and clock,
shows your Mac's vitals at a glance, and drills into *which app* is using what — without
hogging the resources it's watching.

> **Status: in active development.** The runnable menu-bar app (Milestone 1) and the
> per-app breakdown drill-in (Milestone 3 core) are **built and working**. CPU temperature,
> settings, and alerts are still planned — see [Roadmap](#roadmap).

## What it does

Click the menu-bar item to open an overview popover with one card per stat, each with a
live sparkline. Click a card to drill into the top apps using that resource, with quick
actions like **Quit** and **Force Quit**.

UI mockups: the overview at [`docs/mockups/menubar-mockup.html`](docs/mockups/menubar-mockup.html)
and the per-app breakdown at [`docs/mockups/per-app-breakdown-mockup.html`](docs/mockups/per-app-breakdown-mockup.html)
— open them in a browser.

```
  menu bar:   🟢 58° 23%        ← click

  ┌─ MacStats ───────────────┐
  │ CPU      23%   58°C  ▁▃▅▂ │
  │ MEMORY   9.2/16 GB  ▁▁▂▁ │   click a card →  top apps + Quit
  │ NETWORK  ↓1.2 MB/s  ▂▅▃▁ │
  │ BATTERY  84% · 12W  ▁▁▁▁ │
  │           Settings · Quit │
  └───────────────────────────┘
```

## Features

**Built:**
- Live **CPU %** with **CPU temperature**, **Memory** (used / total + real pressure level),
  **Network** (↓/↑ speed), **Battery %**
- Per-stat **history sparklines** (Swift Charts)
- **Adaptive refresh** — near-zero cost when idle; 1s updates only while you're looking
- **Per-app breakdown** — click the **CPU** or **Memory** card to drill into the apps using
  that resource, grouped by app and ranked; right-click a row to **Quit** or **Force Quit**.
  Per-process scanning runs only while a breakdown is open.
- **Threshold alerts** — a notification when CPU runs sustained-high or the system hits real
  memory pressure, even while the popover is closed (lightweight 10s background check).
- **Empty Trash** — a Trash-size readout and a one-click Empty (confirms first).
- **Launch at login** — enrolls itself to start at login on first run; manage it any time in
  System Settings → General → Login Items (removing it there sticks).

**Planned:**
- Live **power (watts)** / battery health & cycle count
- **Settings** — customizable menu-bar display, adjustable alert thresholds
- Per-app **Network/Battery** breakdowns (deferred — no clean per-app network API)

## Why it's lightweight

A monitor that eats CPU and RAM defeats its own purpose. MacStats only does the expensive
work while you're looking at it: when the popover is closed it just refreshes the one or two
menu-bar numbers on a slow cadence and does **not** enumerate processes. Per-process scanning
happens only when you drill into a card.

## Requirements

- **macOS 14+** (built and aimed at Apple Silicon — temperature sensors are M-series-focused)
- **Xcode Command Line Tools** with Swift 6+ to build (`xcode-select --install`). Full Xcode is
  not required — MacStats builds with Swift Package Manager.

## Building from source

```bash
swift build            # compile
./Scripts/test.sh      # run the test suite (Swift Testing — NOT bare `swift test`)
./Scripts/bundle.sh    # build + install ~/Applications/MacStats.app
open ~/Applications/MacStats.app   # launch (appears in the menu bar, no Dock icon)
```

> Tests use **Swift Testing**; `Scripts/test.sh` adds the framework search path that a bare
> `swift test` lacks on Command-Line-Tools-only setups (no full Xcode), so use the script.

> **Threshold notifications** require the bundled `MacStats.app` (not the bare `swift build`
> binary) and macOS notification permission on first launch. **Empty Trash** asks once for
> permission to control Finder (System Settings → Privacy & Security → Automation). **CPU
> temperature** uses a private IOKit sensor API and shows the SoC die temperature on Apple
> Silicon; if no usable sensor is found it falls back to showing "live". **Launch at login**
> likewise needs the bundled, signed app (the API keys off the app bundle) — install it to
> `~/Applications` via `./Scripts/install.sh` for reliable startup.

To quit: open the popover → **Quit** (or `pkill MacStats`).

> The app is **not sandboxed** (it needs direct sensor access) and is **not** distributed via
> the Mac App Store. To share a build with others it would be signed and notarized.

## Tech stack

Swift · SwiftUI (`MenuBarExtra`) · Swift Charts · IOKit / Mach / `getifaddrs` · Swift Package Manager

## Roadmap

| Milestone | Scope | Status |
|-----------|-------|--------|
| **1** | Runnable menu-bar app: live CPU %, Memory, Network, Battery + sparklines + adaptive refresh | ✅ Built |
| **2** | CPU temperature (IOKit IOHID), battery health & live watts | 🟡 CPU temp built; battery health/watts planned |
| **3** | Per-app breakdown + drill-in views + quick actions | ✅ CPU + Memory built (Network/Battery deferred) |
| **4** | Settings, customizable menu-bar display, alerts | 🟡 Threshold alerts + Empty Trash built; Settings/display planned |
| v2+ | Per-app network, disk, GPU/fans, multiple menu-bar items, persisted history | ⬜ Deferred |

Design: [`menubar-design.md`](docs/superpowers/specs/2026-05-29-macstats-menubar-design.md) ·
[`per-app-breakdown-design.md`](docs/superpowers/specs/2026-05-29-macstats-per-app-breakdown-design.md)
· Plans: [`milestone-1-foundation.md`](docs/superpowers/plans/2026-05-29-macstats-milestone-1-foundation.md) ·
[`per-app-breakdown.md`](docs/superpowers/plans/2026-05-29-macstats-per-app-breakdown.md)

## License

Not yet decided.
