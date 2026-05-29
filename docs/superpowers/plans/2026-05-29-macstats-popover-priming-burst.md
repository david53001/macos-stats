# Instant Popover Graph (Priming Burst) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On popover open, fill each sparkline with real samples within ~1 second (and eliminate the ~1s blank/"0%"/"—" window) by collecting a fast priming burst before settling into the normal 1s cadence.

**Architecture:** Add a pure, unit-tested open-phase rule to `MacStatsCore` (`openPhaseInterval(samplesSinceOpen:)`) that returns a fast burst interval for the first N samples after opening, then the existing steady interval. `AppModel` replaces its single repeating `Timer` with a self-rescheduling one-shot timer driven by that rule.

**Tech Stack:** Swift 6.2 (language mode v5), Swift Package Manager, Swift Testing (`import Testing`, run via `./Scripts/test.sh`), SwiftUI `MenuBarExtra`.

**Spec:** `docs/superpowers/specs/2026-05-29-macstats-popover-priming-burst-design.md`

---

## File Structure

- **Modify** `Sources/MacStatsCore/RefreshScheduler.swift` — add `burstInterval`/`burstSamples` constants and the pure `openPhaseInterval(samplesSinceOpen:)` rule. `Visibility` and `refreshInterval(for:)` are left as-is; the rule reuses `refreshInterval(for: .popoverOpen)` as its steady value (no duplicated 1.0s literal).
- **Modify** `Tests/MacStatsCoreTests/RefreshSchedulerTests.swift` — add tests for the new rule. Existing tests stay unchanged and green.
- **Modify** `Sources/MacStatsApp/MacStatsApp.swift` — track `samplesSinceOpen`; replace the repeating timer with a one-shot self-rescheduling timer that uses `openPhaseInterval(samplesSinceOpen:)`.

Two tasks: Task 1 is the testable Core rule (full TDD). Task 2 wires it into the app's timer (UI glue — verified by a green build, green existing tests, and a human acceptance check, since real-`Timer`/syscall code is not unit-testable here).

---

### Task 1: Open-phase priming-burst rule (Core, TDD)

**Files:**
- Modify: `Sources/MacStatsCore/RefreshScheduler.swift`
- Test: `Tests/MacStatsCoreTests/RefreshSchedulerTests.swift`

- [ ] **Step 1: Write the failing tests**

Append these two tests inside the existing `@Suite struct RefreshSchedulerTests { ... }` in `Tests/MacStatsCoreTests/RefreshSchedulerTests.swift` (add them just before the closing brace):

```swift
    @Test func burstWhileFillingThenSteady() {
        // The first `burstSamples` samples come fast (the priming burst)…
        #expect(abs(openPhaseInterval(samplesSinceOpen: 0) - 0.1) < 0.001)
        #expect(abs(openPhaseInterval(samplesSinceOpen: burstSamples - 1) - 0.1) < 0.001)
        // …then it settles to the steady open cadence (1s).
        #expect(abs(openPhaseInterval(samplesSinceOpen: burstSamples) - 1.0) < 0.001)
        #expect(abs(openPhaseInterval(samplesSinceOpen: burstSamples + 5) - 1.0) < 0.001)
    }

    @Test func burstSpansAboutOneSecond() {
        // burstSamples points at burstInterval apart should fill ~1 second.
        #expect(abs(Double(burstSamples) * burstInterval - 1.0) < 0.001)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./Scripts/test.sh --filter RefreshSchedulerTests`
Expected: BUILD FAILURE — `cannot find 'openPhaseInterval' in scope` (and `burstSamples` / `burstInterval` not found). This is the expected "red": the symbols don't exist yet.

- [ ] **Step 3: Write the minimal implementation**

Append to `Sources/MacStatsCore/RefreshScheduler.swift` (after the existing `refreshInterval(for:)` function):

```swift
/// Open-phase priming burst. When the popover opens, the sparklines start empty, so for
/// the first `burstSamples` samples we collect rapidly (`burstInterval` apart) to fill the
/// graph with real data within ~1 second, then settle to the normal open cadence.
/// These two constants are the single knob for the burst's feel.
public let burstInterval: TimeInterval = 0.1   // ~100ms between priming samples
public let burstSamples: Int = 10              // ~1s of burst ⇒ ~10 real points

/// Interval until the next sample while the popover is open, given how many samples have
/// already been collected since it opened. Fast during the burst, then the steady cadence.
public func openPhaseInterval(samplesSinceOpen: Int) -> TimeInterval {
    samplesSinceOpen < burstSamples
        ? burstInterval
        : refreshInterval(for: .popoverOpen)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./Scripts/test.sh --filter RefreshSchedulerTests`
Expected: PASS — all `RefreshSchedulerTests` tests pass (the two new ones plus the existing `idleIsSlow` / `openIsOneSecond`).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacStatsCore/RefreshScheduler.swift Tests/MacStatsCoreTests/RefreshSchedulerTests.swift
git commit -m "feat: add open-phase priming-burst refresh rule

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Drive AppModel's timer with the burst rule

**Files:**
- Modify: `Sources/MacStatsApp/MacStatsApp.swift:6-58` (the `AppModel` class)

No unit test: `AppModel` is `@MainActor` UI glue around a real `Timer` and live syscalls, which isn't unit-testable on this toolchain. The behavior is verified by a green build, green existing tests, and a human acceptance check (Step 5).

- [ ] **Step 1: Replace `AppModel` with the burst-driven version**

In `Sources/MacStatsApp/MacStatsApp.swift`, replace the entire `AppModel` class (the block from `final class AppModel: ObservableObject {` through its closing `}`, currently lines 6–58) with:

```swift
final class AppModel: ObservableObject {
    let store = MetricsStore(historyCapacity: 60)

    private var timer: Timer?
    private var visibility: MacStatsCore.Visibility = .idle
    private var samplesSinceOpen = 0
    private var prevCPU = readCPUTicks()
    private var prevNet = readNetCounters()
    private var prevTime = Date()

    func setVisibility(_ newValue: MacStatsCore.Visibility) {
        guard newValue != visibility else { return }
        visibility = newValue
        switch newValue {
        case .popoverOpen:
            // Re-baseline now so the first sample is an accurate short-window delta rather
            // than an average over however long the popover sat closed. Then start the
            // priming burst from sample 0.
            samplesSinceOpen = 0
            prevCPU = readCPUTicks()
            prevNet = readNetCounters()
            prevTime = Date()
            scheduleNextTick()
        case .idle:
            timer?.invalidate()
            timer = nil
            store.reset() // each open session starts with a fresh sparkline
        }
    }

    /// Schedules the next sample as a one-shot timer. The interval is short during the
    /// opening burst (fills the sparkline with real data fast) and settles to the steady
    /// cadence afterward — see `openPhaseInterval`.
    private func scheduleNextTick() {
        timer?.invalidate()
        let interval = openPhaseInterval(samplesSinceOpen: samplesSinceOpen)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        // A one-shot timer fired after `setVisibility(.idle)` could still be in flight;
        // bail rather than collect or reschedule.
        guard visibility == .popoverOpen else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(prevTime)
        let curCPU = readCPUTicks()
        let curNet = readNetCounters()

        let cpu = cpuBusyPercent(previous: prevCPU, current: curCPU)
        let net = networkThroughput(previous: prevNet, current: curNet, secondsElapsed: elapsed)
        let mem = memorySample(raw: readVMRaw(), totalBytes: ProcessInfo.processInfo.physicalMemory)
        let bat = readBattery()

        store.update(cpuPercent: cpu, memory: mem, network: net, battery: bat)
        prevCPU = curCPU
        prevNet = curNet
        prevTime = now

        samplesSinceOpen += 1
        scheduleNextTick()
    }
}
```

Note: the old `scheduleTimer()` method is fully replaced by `scheduleNextTick()`; `refreshInterval(for:)` is no longer called from `AppModel` but remains valid public Core API (still used by `openPhaseInterval` and its tests) — do not delete it. The `@main struct MacStatsApp` below (lines 60–74) is unchanged.

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors or warnings.

- [ ] **Step 3: Run the full test suite to verify nothing regressed**

Run: `./Scripts/test.sh`
Expected: PASS — all 23 tests pass (the prior 21 plus the 2 added in Task 1).

- [ ] **Step 4: Bundle the app for manual acceptance**

Run: `./Scripts/bundle.sh && open MacStats.app`
Expected: `Built .../MacStats.app` and the menu-bar item appears.

- [ ] **Step 5: Human acceptance check (manual)**

Click the menu-bar item and confirm:
- No blank / "0%" / "—" flash on open — values appear effectively instantly (~100ms).
- Each sparkline fills with real points within ~1 second.
- After ~1s, values update once per second as before.
- Close and reopen → a fresh sparkline that fills the same way.

(If the burst looks too noisy or too slow, the only knob is `burstInterval` / `burstSamples` in `RefreshScheduler.swift`.)

- [ ] **Step 6: Commit**

```bash
git add Sources/MacStatsApp/MacStatsApp.swift
git commit -m "feat: prime popover sparklines with a fast burst on open

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Notes for the implementer

- **Run tests only via `./Scripts/test.sh`** — a bare `swift test` can't find the Swift Testing framework on this Command-Line-Tools-only machine.
- **Commit messages** end with the `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` trailer (shown above).
- **Don't touch** the views (`OverviewView`, `StatCard`, `Sparkline`), `MenuBarLabel`, or any other reader — rapid `@Published` updates already drive Swift Charts to redraw, which is the fill effect. The header's "every 1s" text describes steady state and stays as-is.
