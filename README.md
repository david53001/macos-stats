# MacStats

A lightweight macOS **menu-bar system monitor**. Lives next to your battery and clock,
shows your Mac's vitals at a glance, and drills into *which app* is using what — without
hogging the resources it's watching.

> **Status: early development.** The design and a complete, test-first implementation plan
> are done; the app itself isn't built yet. See [Roadmap](#roadmap). This README describes
> the target product.

## What it does

Click the menu-bar item to open an overview popover with one card per stat, each with a
live sparkline. Click a card to drill into the top apps using that resource, with quick
actions like **Quit** and **Force Quit**.

A preview of the intended UI lives at [`docs/mockups/menubar-mockup.html`](docs/mockups/menubar-mockup.html)
— open it in a browser.

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

**Milestone 1 (foundation):**
- Live **CPU %**, **Memory** (used / total + pressure), **Network** (↓/↑ speed), **Battery %**
- Per-stat **history sparklines** (Swift Charts)
- **Adaptive refresh** — near-zero cost when idle; 1s updates only while you're looking

**Planned:**
- **CPU temperature** and live **power (watts)** / battery health & cycle count
- **Per-app breakdowns** (CPU + Memory) + **Quit** / **Force Quit** quick actions
- **Alerts** (high temp, low battery, runaway process), **customizable menu-bar display**, Settings

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
swift test             # run the test suite
./Scripts/bundle.sh    # assemble MacStats.app
open MacStats.app      # launch (appears in the menu bar, no Dock icon)
```

To quit: open the popover → **Quit** (or `pkill MacStats`).

> The app is **not sandboxed** (it needs direct sensor access) and is **not** distributed via
> the Mac App Store. To share a build with others it would be signed and notarized.

## Tech stack

Swift · SwiftUI (`MenuBarExtra`) · Swift Charts · IOKit / Mach / `getifaddrs` · Swift Package Manager

## Roadmap

| Milestone | Scope |
|-----------|-------|
| **1** | Runnable menu-bar app: live CPU %, Memory, Network, Battery + sparklines + adaptive refresh |
| **2** | CPU temperature (IOKit IOHID), battery health & live watts |
| **3** | Per-app breakdown + drill-in views + quick actions |
| **4** | Settings, customizable menu-bar display, alerts |
| v2+ | Per-app network, disk, GPU/fans, multiple menu-bar items, persisted history |

Design details: [`docs/superpowers/specs/2026-05-29-macstats-menubar-design.md`](docs/superpowers/specs/2026-05-29-macstats-menubar-design.md)
· Build plan: [`docs/superpowers/plans/2026-05-29-macstats-milestone-1-foundation.md`](docs/superpowers/plans/2026-05-29-macstats-milestone-1-foundation.md)

## License

Not yet decided.
