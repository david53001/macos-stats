# MacStats — CPU Temperature, Threshold Alerts & Empty Trash — Design

**Date:** 2026-05-30
**Status:** Approved (design dialogue), pending spec review.
**Targets touched:** new C shim target `CAppleSensors`; `MacStatsCore`; `MacStatsApp`.

## Overview

Three small, independent additions that keep MacStats a glanceable menu-bar monitor while
making it a bit more capable:

- **A. CPU temperature** shown in the CPU card.
- **B. Threshold alerts** — a notification when CPU or memory runs high, even while the popover
  is closed.
- **C. Empty Trash** — a safe, confirmable cleanup action with a Trash-size readout.

Each feature is independent: any one can ship or be deferred without blocking the others. No new
third-party dependencies. No Settings UI (fixed defaults), consistent with "nothing too crazy."

## Non-goals / scope boundaries

- **No menu-bar display change.** Temperature appears only inside the popover's CPU card; the
  menu-bar item stays the static glyph (preserves the locked "no live menu-bar value" decision).
- **No cache / temp-file deletion.** Only Empty Trash (via Finder). Cache cleaning was explicitly
  ruled out as risky.
- **No adjustable alert thresholds / Settings window.** Fixed sensible defaults only.
- **No per-app temperature or per-app alerts.**

---

## Feature A — CPU temperature

### Placement & display

- Shown in the **CPU card's secondary (`meta`) line**: the card's big `value` stays `23%`, and the
  `meta` line (today the static word `"live"`) becomes the temperature, e.g. `58°C`. Result reads
  `CPU` / `23%` / `58°C` stacked. **Assumption (default):** second-line style, not an inline
  `23% · 58°C`. Easy to switch later.
- Temperature reads **only while the popover is open**, inside the existing 1s `tick()`. No
  background cost; nothing changes while closed.
- If no usable sensor is found (see below), the `meta` line falls back to the existing `"live"`
  text — the feature degrades silently, never an error.

### Data source

Apple Silicon exposes **no public temperature API**. The established approach (Stats, macmon, iStat
Menus) is the private **`IOHIDEventSystemClient`** thermal-sensor interface:

1. Create a client (`IOHIDEventSystemClientCreate`).
2. Set a matching dictionary for thermal sensors: `PrimaryUsagePage = 0xff00`
   (`kHIDPage_AppleVendor`), `PrimaryUsage = 5` (`kHIDUsage_AppleVendor_TemperatureSensor`).
3. Copy the matching services (`IOHIDEventSystemClientCopyServices`).
4. For each service, read its name (`IOHIDServiceClientCopyProperty("Product")`) and its current
   temperature event (`IOHIDServiceClientCopyEvent` with `kIOHIDEventTypeTemperature`, then
   `IOHIDEventGetFloatValue`).

These symbols are **private** (not in the importable IOKit headers). For the SPM + Command-Line-Tools
toolchain, they are declared in a small **C shim target** (`CAppleSensors`) — a header with the
function prototypes, linking the IOKit framework, which the Swift code imports. This is consistent
with the project's "private/semi-private sensor access, isolate it" note for Milestone 2.

> **Private-API note.** This is acceptable for MacStats specifically: non-sandboxed, not distributed
> via the App Store, personal use. It would be a blocker only for App Store submission.

### Sensor selection — spike first

M-series chips expose **many** named thermal sensors (P-core / E-core / GPU clusters, etc.) and none
is simply labeled "CPU". The selection is therefore **spike-driven**:

1. First implementation step is a tiny diagnostic (a temporary `@Test` or a one-shot debug print)
   that dumps every matched sensor's **name + current value** on this M3.
2. From that list, choose the CPU-cluster sensors (commonly names beginning `Tp`/`Tc` for
   performance/efficiency cores) and define the reported "CPU temperature" as their **average**
   (rounded to a whole °C).
3. Sanity-check against a known reference (e.g. the `Stats` app, or `sudo powermetrics
   --samplers smc` for a one-off comparison).

The **sensor-selection + averaging logic is a pure function** in `MacStatsCore`
(`cpuTemperature(from sensors: [(name: String, celsius: Double)]) -> Double?`), unit-tested with
mock sensor lists. Only the raw IOHID read is impure (smoke-tested on-device).

### Architecture (Feature A)

| Unit | Responsibility | Depends on |
|------|----------------|------------|
| `CAppleSensors` (C target) | Declares private IOHID prototypes; links IOKit | IOKit |
| `AppleSensorReader.swift` (Core) | Impure: returns `[(name, celsius)]` from the live system | `CAppleSensors` |
| `CPUTemperature.swift` (Core) | Pure: `cpuTemperature(from:)` selection + averaging | — |
| `AppModel.tick()` | Calls reader while open, stores `cpuTempCelsius` | the above |
| `MetricsStore` | New `@Published cpuTempCelsius: Double?` | — |
| `OverviewView` | Renders temp in the CPU card's `meta` line | store |

---

## Feature B — Threshold alerts

### Monitoring model

- A **lightweight background sampler** runs while the popover is **closed**, on the (currently
  dormant) idle cadence of **~10s**. It reads only **system-wide CPU%** and **memory pressure** — no
  per-app scan, no sparkline writes.
- The sampler maintains its own CPU-tick baseline across idle samples (CPU% needs two samples; a
  ~10s window is fine for "sustained high CPU").
- While the popover is **open**, the existing 1s `tick()` also feeds the alert engine, so alerts
  remain live regardless of visibility.
- When alerts are **disabled**, the background sampler does not run (preserves zero idle cost).
  (Alerts default **on**; toggling is internal/simple — no Settings UI this pass.)

### Triggers (fixed defaults)

- **CPU:** sustained **> 85% for ≥ 30s**. A sustain window avoids firing on brief launch spikes.
- **Memory:** the kernel's **real pressure level** reaching **warning or critical**.

### Real memory-pressure source (also fixes a scan finding)

Replace the misleading **used-fraction** pressure heuristic with
the kernel's actual level, read via `sysctlbyname("kern.memorystatus_vm_pressure_level", …)`:

- Mapping (pure, tested): `1 → normal`, `2 → warning`, `4 → critical`, anything else → `normal`.
- `MemorySample.pressure` is now sourced from this level (the Memory **card** indicator improves as a
  side effect). `usedBytes` / `totalBytes` are unchanged (still from `readVMRaw`).
- **Fallback:** if `kern.memorystatus_vm_pressure_level` is restricted/unreadable on this OS, track
  the level instead via a `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])`
  that updates a cached level. The pure mapping and everything downstream are unaffected. The spike
  for Feature A is a good moment to also confirm which path works on this machine.

### Alert engine — pure state machine

`AlertMonitor` in `MacStatsCore` is a pure, testable type. It is fed samples and emits alert events;
it posts nothing itself.

```
struct AlertSample { cpuPercent: Double; pressure: MemoryPressure; time: Date }
enum AlertKind { case highCPU; case memoryPressure }

final class AlertMonitor {
    // config: cpuThreshold=85, cpuSustain=30s, cooldown=300s (defaults)
    func ingest(_ sample: AlertSample) -> [AlertKind]   // returns alerts to fire now
}
```

Behavior, per metric, independently:
- **Arm → fire:** CPU must stay above threshold continuously for the sustain window before firing;
  memory fires as soon as level is warning/critical (no sustain — pressure is already a sustained
  kernel signal).
- **Re-arm:** after firing, the metric will not fire again until it **recovers** (drops below
  threshold / back to normal) **and** a **cooldown** (~5 min) has elapsed. This yields one
  notification per episode.

Unit tests cover: below-threshold never fires; sustained CPU fires once after the window; a brief
spike under the window does not fire; no re-fire during cooldown; re-fire after recovery + cooldown;
memory warning/critical fires, normal does not.

### Notification shim

- `AlertNotifier` (app layer) posts via **`UNUserNotificationCenter`**. Requests authorization
  (`[.alert, .sound]`) once on launch; if denied, alerts silently no-op.
- Copy: e.g. *"High CPU usage — MacStats has seen CPU above 85% for the last 30 seconds."* /
  *"Memory pressure high — your Mac is low on available memory."*
- **Bundling caveat:** notifications require the bundled `MacStats.app` (with its bundle id); they do
  not work when running the bare `swift build` binary. Documented in README/CLAUDE.md.

### Architecture (Feature B)

| Unit | Responsibility |
|------|----------------|
| `readMemoryPressureLevel() -> Int` (Core) | Impure sysctl read |
| `memoryPressure(fromLevel:) -> MemoryPressure` (Core) | Pure mapping (tested) |
| `AlertMonitor` (Core) | Pure sustain/recovery/cooldown state machine (tested) |
| `AppModel` idle sampler | ~10s timer while closed: read CPU+pressure → `AlertMonitor` → notify |
| `AlertNotifier` (App) | `UNUserNotificationCenter` permission + posting |

---

## Feature C — Empty Trash

### Action

- "Empty Trash" runs `tell application "Finder" to empty the trash` via `NSAppleScript`, off the main
  thread (it can block). This empties **all** trashes, including external volumes — matching the real
  Finder menu.
- First use triggers macOS's **one-time Automation permission** prompt ("MacStats wants to control
  Finder"). The not-yet-authorized error (AppleScript error `-1743`) is handled gracefully: surface a
  short message pointing to **System Settings → Privacy & Security → Automation**, rather than
  failing silently.
- A **confirm dialog** precedes emptying (it is destructive) — same pattern as the existing Force
  Quit alert.

### Trash-size readout

- A compact row above the footer: `🗑  Trash — 2.4 GB   [Empty]` (when the Trash is empty: `Trash —
  empty`, with the button disabled).
- Size = sum of file sizes under `~/.Trash`, computed via a **pure helper**
  `directorySize(at: URL) -> UInt64` (unit-tested against a temp directory). Computed only while the
  popover is open. (Per-volume `.Trashes` are emptied by the Finder action but not summed in the
  readout this pass — noted as a possible later enhancement.)

### Architecture (Feature C)

| Unit | Responsibility |
|------|----------------|
| `directorySize(at:) -> UInt64` (Core) | Pure size sum (tested) |
| `TrashActions` (App) | `NSAppleScript` empty + authorization-error handling |
| `OverviewView` | Trash row + confirm dialog |
| `AppModel` | Reads `~/.Trash` size in `tick()`; exposes via store |

---

## Data flow & integration with `AppModel`

- `MetricsStore` gains: `cpuTempCelsius: Double?`, `trashBytes: UInt64?`. `MemorySample.pressure`
  now comes from the real level.
- `AppModel.tick()` (popover open): additionally reads CPU temp, memory pressure level, and Trash
  size; feeds `AlertMonitor`.
- `AppModel` idle sampler (popover closed, alerts enabled): ~10s timer reading CPU% + pressure only,
  feeding `AlertMonitor`; posts via `AlertNotifier`. Starts on `.idle`, stops on `.popoverOpen`.
- `setVisibility(.idle)` no longer fully goes dark when alerts are enabled — it swaps the fast tick
  for the slow alert sampler. This intentionally retires the previously-dead idle cadence.

## Testing strategy

Pure/unit tests (Swift Testing, via `./Scripts/test.sh`):
- `cpuTemperature(from:)` — averaging, sensor subset selection, empty → nil.
- `memoryPressure(fromLevel:)` — 1/2/4/unknown.
- `AlertMonitor` — the six behaviors listed above, for both metrics.
- `directorySize(at:)` — known files in a temp dir; empty dir → 0.

Smoke tests (on-device, sane-range / non-crashing):
- `AppleSensorReader` returns a list (possibly empty) without crashing.
- `readMemoryPressureLevel()` returns a known level value.

Existing `MemoryStatsTests` are updated for the new pressure source.

## Sequencing & risks

1. **Empty Trash** — lowest risk, self-contained. Build first.
2. **Threshold alerts** — medium; the `AlertMonitor` is pure and test-first. Includes the
   memory-pressure source swap.
3. **CPU temperature** — highest risk (private API + spike). Build last so it can be deferred/dropped
   without affecting 1–2. Spike step gates the rest of the feature.

Risks:
- **CPU temp sensors unreadable/unclear on this M3** → mitigation: spike first; graceful fallback to
  no temp.
- **Notification permission denied / unsigned binary** → mitigation: silent no-op; documented that
  the bundled app is required.
- **Automation permission denied for Finder** → mitigation: handled error with a pointer to Settings.

## Open assumptions

- CPU-temp display = second line (`58°C` under `23%`), not inline.
- Alerts default **on**; no user toggle UI this pass (internal flag only).
- CPU threshold 85% / 30s sustain / 5-min cooldown are reasonable defaults (easy to tune later).
