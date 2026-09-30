# Battery status improvements — progress note (2026-09-30)

**Where:** branch `feat/battery-status`, git worktree
`/Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats/.claude/worktrees/battery`
(branched from `feat/polish-perf` at `85d66d6`). A parallel session built the opacity setting on
`feat/opacity-setting`. **First step when resuming:** rebase/merge the latest `feat/polish-perf` (or
wherever the opacity work landed) into this branch. That work adds `SettingsView`, a footer gear and
RootView routing, and may touch `OverviewView.swift` / `RootView.swift`.

Build/test/run: `swift build`, `./Scripts/test.sh` (not bare `swift test`),
`./Scripts/bundle.sh && open ~/Applications/MacStats.app`.

## What the user asked for
The Battery card shows the percentage correctly, but:
1. **Time until empty is poor.** It should hold up when some apps use more power than others.
2. **Charging isn't detected.** When plugged in it should say "Charging".
3. **Time until full** should be shown while charging.
4. "etc.": other useful battery info.

The UI must match the rest of MacStats: same cards, fonts, colours and push transition. The user said
"go ahead", so no approval step is needed. Only code so far is two throwaway probes; **no app code
changed yet.**

## Root causes found (current code)
- `Sources/MacStatsCore/BatteryParse.swift` `parseBattery` only reads `Current Capacity`, `Max Capacity`,
  `Is Charging` and `Time to Empty`. It ignores `Power Source State`, `Is Charged` and `Time to Full Charge`.
- `Sources/MacStatsApp/OverviewView.swift` `batteryMeta`: when the Mac is plugged in but *not* charging
  (full at 100 %, or charging paused by Optimized Charging / a charge limit), it falls through to
  **"on battery"**. That is the "doesn't detect charging" bug. The Mac was in this exact state during
  the probe: `Power Source State = AC Power`, `Is Charged = 1`, `Is Charging = 0`.
- Nothing shows time-to-full.
- Time-to-empty is macOS's `kIOPSTimeToEmptyKey`. It is based on roughly the last minute of power draw,
  so it jumps whenever an app gets busy. It also reads -1 ("calculating") for a while after unplugging,
  and the card then says "on battery".
- The battery is only read at launch, on hover and on open, then every 10 s while open
  (`AppModel` in `Sources/MacStatsApp/MacStatsApp.swift`). There is no power-source change
  notification, so plugging or unplugging is not picked up promptly.

## Probe findings (Mac15,12 = M3 MacBook Air, macOS 26.6.2, 30 W USB-C adapter)
- **IORegistry `AppleSmartBattery`** (via `IOServiceGetMatchingService` + `IORegistryEntryCreateCFProperty`):
  - Keys: `Amperage`/`InstantAmperage` (mA; negative = discharging), `Voltage` (mV),
    `AppleRawCurrentCapacity` and `AppleRawMaxCapacity` (mAh), `DesignCapacity` (4563 mAh),
    `NominalChargeCapacity`, `CycleCount` (126), `Temperature` (centi-°C, 3002 = 30.0 °C),
    `AvgTimeToEmpty`/`AvgTimeToFull` (min; 65535 = n/a), `ExternalConnected`, `IsCharging`,
    `FullyCharged`, `UpdateTime` (unix s), `AdapterDetails` {`Watts` = 30, `Name`}.
  - Signed values arrive as UInt64. Read them with `Int64(bitPattern: n.uint64Value)`.
  - `PowerTelemetryData` dict (Apple Silicon only): `SystemLoad` (mW, whole-Mac draw), `BatteryPower`
    (mW, signed; negative = discharging), `SystemPowerIn` (mW from the adapter), and
    `AccumulatedSystemLoad` / `SystemLoadAccumulatorCount`. Those two are running sums, so
    Δaccum/Δcount gives the exact average draw between two reads.
  - **Values refresh only about every 60 s.** `UpdateTime` steps and every value changes with it.
    Reading every 10 s is fine, but de-duplicate samples by `UpdateTime`.
  - **Cost:** three ints plus the telemetry dict ≈ **21 µs** per read; the full property dict ≈ 270 µs.
    Cache the registry entry, as `CPUTemperatureReader` does.
- **Plugged in and "full", yet discharging:** the adapter supplied ~0.09 W while the battery supplied
  4–11 W (`ChargerData.NotChargingReason` and `ChargerInhibitReason` were nonzero). macOS lets a full
  battery drift down. So "AC Power" does **not** mean the battery isn't draining. Show this state
  the way macOS does ("Fully charged" / "Plugged in"), not as "on battery".
- **IOPowerSources dict** (public API) keys present: `Power Source State` ("AC Power"/"Battery Power"),
  `Is Charging`, `Is Charged`, `Time to Empty`, `Time to Full Charge`, `Current` (mA),
  `BatteryHealth` ("Good"), `LPM Active` (Low Power Mode). `IOPSCopyExternalPowerAdapterDetails()`
  returns adapter `Watts`/`Name`.
- **Per-app energy is feasible and real:** `proc_pid_rusage(pid, RUSAGE_INFO_V6, …)` gives `ri_energy_nj`
  (CPU energy per process, in nanojoules). Watts = Δnj / 1e9 / Δs. It reads 393 of 706 processes
  (the user's own) in ~3 ms. This counts CPU energy only, not GPU or display. The design spec called
  per-app energy "approximate", but this is a measured value.

## Plan (remaining work, in order)
1. **Core model** (`BatteryParse.swift` + `BatteryParseTests.swift`):
   - Add a `BatteryState` enum: `charging`, `charged` (plugged in and full), `notCharging` (plugged in,
     paused or limited), `discharging`.
   - Add to `BatterySample`: `timeToFullMinutes`, `systemWatts`, signed `batteryWatts`, `adapterWatts`,
     raw mAh (current/max/design), `cycleCount`, `healthPercent`, `temperatureC`.
   - Parse `Power Source State`, `Is Charged` and `Time to Full Charge`, treating -1/0 as unknown.
     Unit-test every state with fixture dicts.
2. **`AppleSmartBatteryReader`** (Core): caches the registry entry and reads single properties,
   including `PowerTelemetryData`. Falls back to `Voltage × Amperage` when telemetry is missing (Intel).
3. **`BatteryEstimator`** (Core, pure, tested):
   - Keep a time-aware exponential moving average of the discharge draw:
     α = 1 − exp(−Δt/τ), with τ ≈ 5 min.
   - Feed it only when `UpdateTime` changes.
   - Reset it on any state change (plug/unplug). Seed it with the gauge's current reading so there's
     no long "calculating…" period.
   - Time-to-empty = remaining mAh ÷ smoothed mA. This averages the mix of heavy and light apps
     instead of the last minute.
   - Time-to-full: use macOS's `Time to Full Charge` first; if that is unknown, use remaining gap ÷
     smoothed charge current.
4. **AppModel wiring:**
   - `IOPSNotificationCreateRunLoopSource` → re-read the battery immediately on plug/unplug or a
     percent change, whether the popover is open or closed. Remove the source on deinit.
   - Also read the battery in the 10 s idle sampler (costs ~21 µs), so the estimator has history
     when the popover opens.
5. **Battery card UI** (`OverviewView.swift`), same style as now:
   - Meta line by state: "2h 15m left" / "1h 05m to full" / "fully charged" / "not charging" /
     "calculating…".
   - Add current watts.
   - Keep the existing `BatteryGauge` (green while charging), optionally with a bolt glyph.
   - The meta column is only ~120 pt at `.caption2`, so keep strings short.
6. **Optional, larger:** make the Battery card tappable, with the same push transition as CPU/Memory,
   into a **Battery detail screen**:
   - A details card with Status, Time left/to full, Power (W), Adapter (e.g. "30 W USB-C"),
     Health (max capacity %, cycles) and Temperature.
   - Below it, apps ranked by energy (W, from `ri_energy_nj`), reusing `BreakdownView`'s row style
     (`AppRow`).
   - The per-process scan runs only while this screen is open, like the existing breakdowns.
7. Build, run `./Scripts/test.sh`, bundle, then screenshot the popover:
   `osascript -e 'tell application "System Events" to tell process "MacStats" to click menu bar item 1 of menu bar 2'`
   then `screencapture -x out.png`.
8. Update `CLAUDE.md` Status (Milestone 2 battery health/watts), commit, and tell the user.

## Quick re-check commands
`pmset -g batt` · `ioreg -rn AppleSmartBattery -w0 | grep -E 'Amperage|Voltage|RawCurrentCapacity|UpdateTime|PowerTelemetryData'`
