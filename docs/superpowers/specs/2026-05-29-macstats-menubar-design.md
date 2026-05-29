# MacStats — Menu-Bar System Monitor — Design Spec

- **Date:** 2026-05-29
- **Status:** Approved (design); implementation plan to follow
- **Mockup:** [`docs/mockups/menubar-mockup.html`](../../mockups/menubar-mockup.html) — open in a browser

## Summary

MacStats is a lightweight macOS menu-bar app that lives next to the battery/clock and
shows live system stats. Clicking the menu-bar item opens a popover with one card per
stat (each with a live sparkline). Clicking a card drills into a per-app breakdown for
that metric, with quick actions (e.g. Quit a process, free memory). The app is built to
be near-zero cost when idle and only does expensive work while the user is looking at it.

## Goals

- Show, at a glance in the menu bar, a small configurable set of stats (default: CPU temp + CPU %).
- One click → an overview popover covering **CPU, Memory, Network, Battery & Power**, each with a live history sparkline.
- One more click on a card → **per-app breakdown** for that metric.
- **Lightweight:** negligible CPU/RAM when the popover is closed.
- Polished, native look using **Swift Charts** for graphs.

## Non-Goals (deferred to v2+)

- Disk stats (free space / I/O) — explicitly out of v1.
- GPU, fans, and the full raw-sensor list — out of v1.
- Multiple separate menu-bar items (iStat-style one-item-per-category) — v1 uses a single combined item.
- Mac App Store distribution (would require sandboxing, which blocks sensor access).

## Users & Distribution

- **Primary:** the author's own Mac (Apple Silicon, macOS 26.x), **direct install, not sandboxed**.
- **Future:** may share with others → will require Apple Developer signing + notarization. Architecture must not assume sandbox-only or App-Store-only APIs, but may freely use non-sandbox APIs (private IOKit sensor calls, etc.).

## Tech Stack

- **Language:** Swift
- **App shell / menu bar:** SwiftUI `MenuBarExtra` (window-style popover)
- **Graphs:** Swift Charts (sparklines + larger drill-in charts)
- **System access:** IOKit, Mach host APIs, `libproc`, CoreWLAN — via small C-bridging where needed
- **Min target:** macOS 14+ (uses `MenuBarExtra`; dev machine is macOS 26)
- **Not sandboxed** (entitlement-free for sensor access); notarization added later for sharing.

## Feature Scope (v1)

### Stats shown
| Stat | In menu bar (configurable) | In overview card | Drill-in (per-app) |
|------|---------------------------|------------------|--------------------|
| CPU % | yes (default) | %, temp, P/E split, sparkline | top processes by CPU + Quit |
| CPU temp | yes (default) | shown on CPU card | — |
| Memory | optional | used / total, pressure 🟢🟡🔴, sparkline | top processes by RAM |
| Network | optional | ↓/↑ speed, data today, sparkline | top processes by bandwidth *(best-effort, see risks)* |
| Battery & Power | optional | %, time left, watts in, health %, sparkline | top processes by energy impact *(approximate)* |

### UX features
- **History graphs** — in-memory ring buffer per metric (e.g. last ~10 min at 1s while open); sparkline on each card + a bigger chart in the drill-in. History is **not persisted across launches** in v1.
- **Alerts** — user-set thresholds (high CPU temp, low battery, runaway process); delivered as native macOS notifications.
- **Customizable menu-bar display** — Settings lets the user pick which 1–3 metrics appear up top and whether each is text or a tiny inline graph.
- **Quick actions** — per-app **Quit** / **Force Quit** in drill-in.

### Settings window (standard SwiftUI Settings scene, tabbed)
- **General:** launch at login, base refresh cadence.
- **Menu Bar:** which metrics show, text vs mini-graph.
- **Alerts:** thresholds per metric, enable/disable.

## UX Design

See the mockup. Summary:

- **Menu-bar item:** single compact item, default `58° 23%`. Click opens the overview popover.
- **Overview popover (~320pt wide):** header (`MacStats` + gear), one card per stat (label, big value, secondary meta, colored sparkline, drill chevron), footer (Settings · Quit).
- **Drill-in:** back chevron + metric summary, a larger Swift Charts history chart, a "Top processes" list (icon, name, value, Quit button), same footer.
- Colors map per stat (CPU green, Memory blue, Network purple, Battery yellow); pressure/health use 🟢/🟡/🔴.

## Adaptive Refresh & Performance Budget

The defining constraint: **don't be a monitor that hogs the resources it monitors.**

- **Popover closed (idle):** only the 1–3 menu-bar values update, on a slow/cheap cadence (~2–3s). **No** per-process enumeration, no heavy collection.
- **Popover open:** refresh bumps to **1s**; full per-stat collection runs.
- **Drilled into a card:** the expensive per-process scan runs, and **only for the visible metric**.
- A single timer/scheduler owns cadence; collectors are pull-based and cheap to skip.
- Target: effectively ~0% CPU and a few MB RAM when idle.

## Architecture

Small, independently-testable units:

- **Collectors** (one per domain, pure data, no UI): `CPUCollector`, `MemoryCollector`, `NetworkCollector`, `BatteryCollector`, plus `SensorReader` (IOKit temp) and `ProcessCollector` (per-app). Each exposes a `sample()` returning a plain value struct.
- **MetricsStore** (observable): holds the latest sample + a ring buffer of history per metric; the source of truth the UI binds to.
- **RefreshScheduler:** owns the adaptive cadence; tells the store which collectors to run based on popover/drill-in visibility.
- **UI (SwiftUI):** `MenuBarLabelView` (the bar text/graph), `OverviewView` (cards), `DetailView` (drill-in), `SettingsView`.
- **AlertEngine:** watches the store against thresholds, fires notifications (debounced).
- **C-bridge:** thin module exposing IOKit/Mach/libproc calls Swift can't reach directly.

**Data flow:** `RefreshScheduler` → runs relevant `Collector.sample()` → writes to `MetricsStore` → SwiftUI views observe and re-render; `AlertEngine` also observes the store.

## Data Sources & Feasibility

| Metric | API / source | Privilege | Difficulty |
|--------|--------------|-----------|------------|
| CPU % (overall, per-core, P/E) | `host_processor_info` / `host_statistics64` | none | easy |
| Load averages, uptime | `sysctl` | none | easy |
| Memory used/free/wired/compressed, swap | `host_statistics64(HOST_VM_INFO64)`, `sysctl vm.swapusage` | none | easy |
| Memory pressure 🟢🟡🔴 | `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` / `sysctl` | none | easy |
| Network speed + totals | `getifaddrs` `if_data` byte counters (sampled delta) | none | easy |
| Wi-Fi SSID/signal | CoreWLAN `CWInterface` | none | easy |
| Battery %, time left, charging | IOKit `IOPSCopyPowerSourcesInfo` | none | easy |
| Battery health, cycle count | IOKit `AppleSmartBattery` properties | none | easy |
| Live watts in/out, adapter watts | `AppleSmartBattery` Amperage×Voltage / adapter details | none | medium |
| **CPU temp (Apple Silicon)** | IOKit `IOHIDEventSystemClient` thermal sensors | none (non-sandboxed) | **hard — semi-private API, sensor keys vary by chip; needs on-device testing** |
| Per-process CPU | `proc_listpids` + `proc_pid_rusage`/`proc_pidinfo` (CPU-time deltas) | none | medium |
| Per-process memory | `proc_pidinfo(PROC_PIDTASKINFO)` / `ri_phys_footprint` | none | medium |
| Per-process energy impact | approximate from CPU time + wakeups (`ri_*_wkups`) | none | **approximate — exact "energy impact" formula is private** |
| **Per-process network** | private `NetworkStatistics` framework, or parse `nettop` | none | **hard — no clean public API; v2 / best-effort** |
| Quit process | `kill(pid, SIGTERM)` | none (own user's procs) | easy |

## Risks & Open Questions

1. **CPU temp** is the biggest risk: the IOHID sensor approach needs validation on the actual M-series machine; sensor naming differs across chips. Isolate it so the rest of the app ships even if temp needs iteration. Fallback: hide the temp readout if no sensor is found.
2. **Per-app network** has no clean public API. v1 plan: ship total network speed; treat per-app network as best-effort/deferred to v2.
3. **Per-app energy impact** is approximate; label it honestly rather than implying it equals Activity Monitor's number.
4. **Xcode/toolchain** must be present to build (verify before scaffolding).

## Testing Strategy

- **Collectors** are pure functions over system state → unit-test value parsing/derivation with injected/mocked raw inputs (e.g. byte-counter deltas → speed).
- **MetricsStore** ring-buffer logic → unit tests (capacity, eviction, windowing).
- **AlertEngine** threshold + debounce logic → unit tests.
- **Adaptive scheduler** → unit-test cadence selection given visibility state.
- **Sensor/IOKit reads** → can't unit-test cleanly; validate manually on-device and guard behind capability checks.
- UI is validated visually against the mockup.

## Build Phasing (feeds the implementation plan)

0. Project scaffold: Xcode project, `MenuBarExtra` app shell showing static text, launches.
1. Easy collectors (CPU %, Memory, Network speed, basic Battery) + `MetricsStore` ring buffers + `RefreshScheduler` (adaptive).
2. Overview popover UI with Swift Charts sparklines, bound to the store.
3. Hard sensors, isolated: CPU temp (IOKit IOHID) + battery health/watts.
4. Per-app breakdown (CPU, memory) + drill-in UI + quick actions (Quit / Force Quit).
5. Customizable menu-bar display + Settings window.
6. Alerts (thresholds + notifications).
- **v2+:** per-app network, Disk, GPU/fans/raw sensors, multiple menu-bar items, persisted history.
