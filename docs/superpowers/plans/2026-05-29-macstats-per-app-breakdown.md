# Per-App Breakdown (Drill-In) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user click the CPU or Memory card in the overview popover to drill into a ranked, app-grouped breakdown of that resource, and right-click an app to Quit or Force Quit it.

**Architecture:** A pure, testable core (`MacStatsCore`) holds new value types and three pure functions — `processCPUPercent` (per-process CPU delta math), `owningAppPID` (maps a process to its owning GUI app by walking the parent chain), and `aggregate` (groups processes by app, sums, sorts). A thin syscall reader (`readRawProcesses`) enumerates the current user's processes. The app target (`MacStatsApp`) builds the GUI-app identity set from `NSWorkspace`/`NSRunningApplication`, runs the per-process scan on a **dedicated 1s timer that exists only while a breakdown is open** (kept separate from the existing sparkline/priming-burst tick so that delicate code is untouched), and renders the list with a right-click context menu.

**Tech Stack:** Swift 6 (language mode v5), SwiftUI `MenuBarExtra` (`.window`), `MacStatsCore` library, Swift Testing (`import Testing`), `libproc` via the `Darwin` module, AppKit `NSRunningApplication`. Build with SwiftPM (`swift build`); tests via `./Scripts/test.sh`.

---

## Spec

Design spec: [`docs/superpowers/specs/2026-05-29-macstats-per-app-breakdown-design.md`](../specs/2026-05-29-macstats-per-app-breakdown-design.md)
Approved mockup: [`docs/mockups/per-app-breakdown-mockup.html`](../../mockups/per-app-breakdown-mockup.html)

**Refinements made during planning (consistent with the spec's intent):**
- The per-process scan runs on a **dedicated `Timer` (1s, repeating)** owned by `AppModel`, started on drill-in and invalidated on exit — rather than extending the `Visibility` enum. Same observable behavior (scan only while a breakdown is open, ~1s cadence) without disturbing the tuned priming-burst code in `tick()`.
- **Per-process memory** uses `proc_taskinfo.pti_resident_size` (RSS) — one `proc_pidinfo` call also yields CPU time — instead of `ri_phys_footprint`. Simpler; phys-footprint is a possible v2 accuracy upgrade.
- **Quit / Force Quit** use `NSRunningApplication.terminate()` / `forceTerminate()` (correct Cmd-Q save-prompt semantics), validated on-device rather than unit-tested.

## Preconditions

- The working tree currently has **unrelated uncommitted changes** from the priming-burst work. Before starting, commit or stash those so this feature starts from a clean tree, then create a feature branch:

  ```bash
  git status                       # confirm what's dirty
  git stash push -u -m "wip: priming-burst (pre-breakdown)"   # OR commit it
  git checkout -b macstats-per-app-breakdown
  ```

- Each task's commit step stages **only that task's files by explicit path** (never `git add -A`) so nothing unrelated is swept in.
- Verify the baseline is green before Task 1: `swift build` and `./Scripts/test.sh` both pass (21 existing tests).

## File Structure

**Create (Core — pure, testable):**
- `Sources/MacStatsCore/ProcessBreakdown.swift` — value types (`BreakdownMetric`, `RawProcess`, `ProcessUsage`, `AppUsage`) + pure functions (`processCPUPercent`, `owningAppPID`, `aggregate`).
- `Sources/MacStatsCore/ProcessReader.swift` — `readRawProcesses()` syscall wrapper (libproc).

**Create (App — UI / wiring, on-device validated):**
- `Sources/MacStatsApp/ProcessActions.swift` — `quit` / `forceQuit` via `NSRunningApplication`.
- `Sources/MacStatsApp/BreakdownView.swift` — drill-in list: header, rows, usage bars, right-click menu, Force-Quit confirmation, measuring state.
- `Sources/MacStatsApp/RootView.swift` — switches Overview ↔ Breakdown; owns the popover open/close wiring.

**Create (Tests):**
- `Tests/MacStatsCoreTests/ProcessBreakdownTests.swift`
- `Tests/MacStatsCoreTests/ProcessReaderSmokeTests.swift`

**Modify:**
- `Sources/MacStatsCore/MetricsStore.swift` — add breakdown state (`breakdown`, `breakdownMeasuring`, `activeBreakdownMetric`) + methods.
- `Sources/MacStatsApp/MacStatsApp.swift` — `AppModel` gains the breakdown pipeline; `body` uses `RootView`.
- `Sources/MacStatsApp/StatCard.swift` — optional tap + trailing chevron.
- `Sources/MacStatsApp/OverviewView.swift` — pass `onSelect` to the CPU & Memory cards only.

---

### Task 1: Core value types + `processCPUPercent`

**Files:**
- Create: `Sources/MacStatsCore/ProcessBreakdown.swift`
- Test: `Tests/MacStatsCoreTests/ProcessBreakdownTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/MacStatsCoreTests/ProcessBreakdownTests.swift`:

```swift
import Testing
@testable import MacStatsCore

@Suite struct ProcessBreakdownTests {
    // MARK: processCPUPercent
    @Test func oneCoreFullyBusyOverOneSecond() {
        // 1s of CPU time in 1s wall-clock == 100%
        let pct = processCPUPercent(previousCPUTimeNs: 0, currentCPUTimeNs: 1_000_000_000, elapsedSeconds: 1.0)
        #expect(abs(pct - 100) < 0.001)
    }

    @Test func multiCoreCanExceed100() {
        // 2s of CPU time in 1s wall-clock == 200% (two cores)
        let pct = processCPUPercent(previousCPUTimeNs: 0, currentCPUTimeNs: 2_000_000_000, elapsedSeconds: 1.0)
        #expect(abs(pct - 200) < 0.001)
    }

    @Test func zeroElapsedReturnsZero() {
        #expect(processCPUPercent(previousCPUTimeNs: 0, currentCPUTimeNs: 5, elapsedSeconds: 0) == 0)
    }

    @Test func counterResetReturnsZero() {
        // current < previous (pid reused / counter reset) → 0, never negative
        #expect(processCPUPercent(previousCPUTimeNs: 100, currentCPUTimeNs: 50, elapsedSeconds: 1.0) == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./Scripts/test.sh --filter ProcessBreakdownTests`
Expected: FAIL — `cannot find 'processCPUPercent' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/MacStatsCore/ProcessBreakdown.swift`:

```swift
import Foundation

/// Which resource a breakdown ranks apps by.
public enum BreakdownMetric: Equatable {
    case cpu
    case memory
}

/// Raw per-process reading straight from libproc (one entry per user process).
public struct RawProcess: Equatable {
    public let pid: Int32
    public let ppid: Int32
    public let cpuTimeNs: UInt64    // cumulative user+system CPU time, nanoseconds
    public let memoryBytes: UInt64  // resident size (RSS)

    public init(pid: Int32, ppid: Int32, cpuTimeNs: UInt64, memoryBytes: UInt64) {
        self.pid = pid; self.ppid = ppid; self.cpuTimeNs = cpuTimeNs; self.memoryBytes = memoryBytes
    }
}

/// A single process's usage, already attributed to its owning GUI app.
public struct ProcessUsage: Equatable {
    public let pid: Int32
    public let appPID: Int32       // owning GUI app's pid (the grouping key)
    public let cpuPercent: Double
    public let memoryBytes: UInt64

    public init(pid: Int32, appPID: Int32, cpuPercent: Double, memoryBytes: UInt64) {
        self.pid = pid; self.appPID = appPID; self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes
    }
}

/// One app's summed usage across all of its processes.
public struct AppUsage: Equatable, Identifiable {
    public let appPID: Int32
    public let pids: [Int32]
    public let cpuPercent: Double
    public let memoryBytes: UInt64

    public var id: Int32 { appPID }

    public init(appPID: Int32, pids: [Int32], cpuPercent: Double, memoryBytes: UInt64) {
        self.appPID = appPID; self.pids = pids; self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes
    }

    public func value(for metric: BreakdownMetric) -> Double {
        switch metric {
        case .cpu: return cpuPercent
        case .memory: return Double(memoryBytes)
        }
    }
}

/// A process's CPU percentage between two cumulative CPU-time samples.
/// May exceed 100 on multiple cores (Activity-Monitor convention).
public func processCPUPercent(previousCPUTimeNs: UInt64, currentCPUTimeNs: UInt64, elapsedSeconds: Double) -> Double {
    guard elapsedSeconds > 0, currentCPUTimeNs >= previousCPUTimeNs else { return 0 }
    let deltaNs = Double(currentCPUTimeNs - previousCPUTimeNs)
    return max(0, deltaNs / (elapsedSeconds * 1_000_000_000) * 100)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./Scripts/test.sh --filter ProcessBreakdownTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacStatsCore/ProcessBreakdown.swift Tests/MacStatsCoreTests/ProcessBreakdownTests.swift
git commit -m "feat: add per-process breakdown value types + CPU% delta math"
```

---

### Task 2: `owningAppPID` (parent-chain walk)

**Files:**
- Modify: `Sources/MacStatsCore/ProcessBreakdown.swift`
- Test: `Tests/MacStatsCoreTests/ProcessBreakdownTests.swift:append`

- [ ] **Step 1: Write the failing test**

Append these tests inside `ProcessBreakdownTests`:

```swift
    // MARK: owningAppPID
    @Test func processThatIsItselfAnApp() {
        #expect(owningAppPID(for: 100, ppid: [100: 1], appPIDs: [100]) == 100)
    }

    @Test func helperAttributedToParentApp() {
        // 300 → parent 200 → parent 100 (an app)
        let ppid: [Int32: Int32] = [300: 200, 200: 100, 100: 1]
        #expect(owningAppPID(for: 300, ppid: ppid, appPIDs: [100]) == 100)
    }

    @Test func orphanProcessReturnsNil() {
        // chain reaches launchd (1), which is not an app
        let ppid: [Int32: Int32] = [500: 1]
        #expect(owningAppPID(for: 500, ppid: ppid, appPIDs: [100]) == nil)
    }

    @Test func brokenChainReturnsNil() {
        // parent pid not present in the map
        #expect(owningAppPID(for: 700, ppid: [700: 650], appPIDs: [100]) == nil)
    }

    @Test func cyclicChainReturnsNilNotHang() {
        let ppid: [Int32: Int32] = [10: 11, 11: 10]
        #expect(owningAppPID(for: 10, ppid: ppid, appPIDs: [999]) == nil)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./Scripts/test.sh --filter ProcessBreakdownTests`
Expected: FAIL — `cannot find 'owningAppPID' in scope`.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/MacStatsCore/ProcessBreakdown.swift`:

```swift
/// Walks the parent-pid chain from `pid` upward until it reaches a pid that is a known
/// GUI app (`appPIDs`). Returns that app's pid, or nil if the chain ends without hitting
/// an app (e.g. a system daemon reparented to launchd). Guards against cycles and gaps.
public func owningAppPID(for pid: Int32, ppid: [Int32: Int32], appPIDs: Set<Int32>) -> Int32? {
    var current = pid
    var seen = Set<Int32>()
    while true {
        if appPIDs.contains(current) { return current }
        if seen.contains(current) { return nil }      // cycle guard
        seen.insert(current)
        guard let parent = ppid[current], parent != current else { return nil }
        current = parent
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./Scripts/test.sh --filter ProcessBreakdownTests`
Expected: PASS (9 tests total in the suite).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacStatsCore/ProcessBreakdown.swift Tests/MacStatsCoreTests/ProcessBreakdownTests.swift
git commit -m "feat: attribute processes to owning GUI app via parent-chain walk"
```

---

### Task 3: `aggregate` (group by app, sum, sort)

**Files:**
- Modify: `Sources/MacStatsCore/ProcessBreakdown.swift`
- Test: `Tests/MacStatsCoreTests/ProcessBreakdownTests.swift:append`

- [ ] **Step 1: Write the failing test**

Append these tests inside `ProcessBreakdownTests`:

```swift
    // MARK: aggregate
    @Test func groupsAndSumsByApp() {
        let procs = [
            ProcessUsage(pid: 1, appPID: 100, cpuPercent: 10, memoryBytes: 1_000),
            ProcessUsage(pid: 2, appPID: 100, cpuPercent: 5,  memoryBytes: 2_000),  // same app
            ProcessUsage(pid: 3, appPID: 200, cpuPercent: 30, memoryBytes: 500),
        ]
        let result = aggregate(procs, by: .cpu)
        #expect(result.count == 2)
        let chrome = result.first { $0.appPID == 100 }!
        #expect(abs(chrome.cpuPercent - 15) < 0.001)
        #expect(chrome.memoryBytes == 3_000)
        #expect(Set(chrome.pids) == [1, 2])
    }

    @Test func sortedDescendingByCPU() {
        let procs = [
            ProcessUsage(pid: 1, appPID: 100, cpuPercent: 10, memoryBytes: 9_000),
            ProcessUsage(pid: 2, appPID: 200, cpuPercent: 30, memoryBytes: 1_000),
        ]
        let result = aggregate(procs, by: .cpu)
        #expect(result.map(\.appPID) == [200, 100])    // 30% before 10%
    }

    @Test func sortedDescendingByMemory() {
        let procs = [
            ProcessUsage(pid: 1, appPID: 100, cpuPercent: 99, memoryBytes: 1_000),
            ProcessUsage(pid: 2, appPID: 200, cpuPercent: 1,  memoryBytes: 8_000),
        ]
        let result = aggregate(procs, by: .memory)
        #expect(result.map(\.appPID) == [200, 100])    // 8000 bytes before 1000
    }

    @Test func emptyInputYieldsEmpty() {
        #expect(aggregate([], by: .cpu).isEmpty)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./Scripts/test.sh --filter ProcessBreakdownTests`
Expected: FAIL — `cannot find 'aggregate' in scope`.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/MacStatsCore/ProcessBreakdown.swift`:

```swift
/// Groups already-attributed process usages by their owning app, sums CPU% and memory,
/// and returns the apps sorted descending by the chosen metric. Input is assumed to be
/// pre-filtered to app-owned processes (callers skip processes whose `owningAppPID` is nil),
/// so the result contains only user apps.
public func aggregate(_ processes: [ProcessUsage], by metric: BreakdownMetric) -> [AppUsage] {
    var byApp: [Int32: (pids: [Int32], cpu: Double, mem: UInt64)] = [:]
    for p in processes {
        var entry = byApp[p.appPID] ?? (pids: [], cpu: 0, mem: 0)
        entry.pids.append(p.pid)
        entry.cpu += p.cpuPercent
        entry.mem += p.memoryBytes
        byApp[p.appPID] = entry
    }
    let apps = byApp.map { appPID, e in
        AppUsage(appPID: appPID, pids: e.pids, cpuPercent: e.cpu, memoryBytes: e.mem)
    }
    return apps.sorted { $0.value(for: metric) > $1.value(for: metric) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./Scripts/test.sh --filter ProcessBreakdownTests`
Expected: PASS (13 tests total in the suite).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacStatsCore/ProcessBreakdown.swift Tests/MacStatsCoreTests/ProcessBreakdownTests.swift
git commit -m "feat: aggregate per-process usage into ranked per-app list"
```

---

### Task 4: `readRawProcesses` (libproc syscall reader)

**Files:**
- Create: `Sources/MacStatsCore/ProcessReader.swift`
- Test: `Tests/MacStatsCoreTests/ProcessReaderSmokeTests.swift`

> Like `SystemReadersSmokeTests`, this can't assert exact values — it just confirms the
> syscall path returns sane data on the dev machine (includes the test process itself).

- [ ] **Step 1: Write the failing test**

Create `Tests/MacStatsCoreTests/ProcessReaderSmokeTests.swift`:

```swift
import Testing
import Darwin
@testable import MacStatsCore

@Suite struct ProcessReaderSmokeTests {
    @Test func returnsCurrentProcessWithSaneFields() {
        let procs = readRawProcesses()
        #expect(!procs.isEmpty)

        let me = procs.first { $0.pid == getpid() }
        #expect(me != nil)                       // our own process is listed
        #expect(me?.ppid ?? 0 > 0)               // has a parent
        // CPU time is cumulative-since-launch (could be small but non-negative); memory > 0.
        #expect((me?.memoryBytes ?? 0) > 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./Scripts/test.sh --filter ProcessReaderSmokeTests`
Expected: FAIL — `cannot find 'readRawProcesses' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/MacStatsCore/ProcessReader.swift`:

```swift
import Foundation
import Darwin

/// Enumerates the current user's processes via libproc and reads each one's cumulative
/// CPU time, resident memory, and parent pid. Other users' processes are skipped (we can
/// only act on our own, and they shouldn't appear in a "your apps" list). Best-effort:
/// processes that disappear mid-scan or refuse a read are simply omitted.
public func readRawProcesses() -> [RawProcess] {
    let uid = getuid()

    // First call sizes the buffer (bytes), then fetch with headroom for races.
    let sizeBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard sizeBytes > 0 else { return [] }
    let capacity = Int(sizeBytes) / MemoryLayout<pid_t>.size + 64
    var pids = [pid_t](repeating: 0, count: capacity)
    let gotBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard gotBytes > 0 else { return [] }
    let count = Int(gotBytes) / MemoryLayout<pid_t>.size

    var result: [RawProcess] = []
    result.reserveCapacity(count)
    let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)

    for i in 0..<count {
        let pid = pids[i]
        guard pid > 0 else { continue }

        var bsd = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize,
              bsd.pbi_uid == uid else { continue }

        var task = proc_taskinfo()
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else { continue }

        result.append(RawProcess(
            pid: pid,
            ppid: Int32(bitPattern: bsd.pbi_ppid),
            cpuTimeNs: task.pti_total_user + task.pti_total_system,
            memoryBytes: task.pti_resident_size
        ))
    }
    return result
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./Scripts/test.sh --filter ProcessReaderSmokeTests`
Expected: PASS (1 test).

> If a libproc symbol (`proc_listpids`, `proc_pidinfo`, `proc_bsdinfo`, `proc_taskinfo`,
> `PROC_PIDTBSDINFO`, `PROC_PIDTASKINFO`, `PROC_ALL_PIDS`) fails to resolve, it means the
> Darwin module didn't surface `<libproc.h>`/`<sys/proc_info.h>`. Fix: add `import Darwin`
> (already present) — these are part of Darwin on macOS 14. No C shim has been needed for
> the existing `host_statistics`/`getifaddrs` readers, and none is expected here.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacStatsCore/ProcessReader.swift Tests/MacStatsCoreTests/ProcessReaderSmokeTests.swift
git commit -m "feat: read per-process cpu/memory/ppid via libproc"
```

---

### Task 5: `MetricsStore` breakdown state

**Files:**
- Modify: `Sources/MacStatsCore/MetricsStore.swift`
- Test: `Tests/MacStatsCoreTests/MetricsStoreTests.swift:append`

- [ ] **Step 1: Write the failing test**

Append to `Tests/MacStatsCoreTests/MetricsStoreTests.swift` (inside its existing `@Suite`; tests are `@MainActor` because `MetricsStore` is main-actor isolated):

```swift
    @MainActor @Test func breakdownLifecycle() {
        let store = MetricsStore()

        store.beginBreakdown(metric: .cpu)
        #expect(store.activeBreakdownMetric == .cpu)
        #expect(store.breakdownMeasuring == true)        // CPU needs two samples
        #expect(store.breakdown.isEmpty)

        store.setBreakdown([AppUsage(appPID: 1, pids: [1], cpuPercent: 12, memoryBytes: 0)], measuring: false)
        #expect(store.breakdown.count == 1)
        #expect(store.breakdownMeasuring == false)

        store.clearBreakdown()
        #expect(store.activeBreakdownMetric == nil)
        #expect(store.breakdown.isEmpty)
        #expect(store.breakdownMeasuring == false)
    }

    @MainActor @Test func beginMemoryBreakdownIsNotMeasuring() {
        let store = MetricsStore()
        store.beginBreakdown(metric: .memory)
        #expect(store.breakdownMeasuring == false)       // memory is instantaneous
    }

    @MainActor @Test func resetClearsBreakdown() {
        let store = MetricsStore()
        store.beginBreakdown(metric: .cpu)
        store.reset()
        #expect(store.activeBreakdownMetric == nil)
        #expect(store.breakdown.isEmpty)
    }
```

> If `MetricsStoreTests` uses free-standing `@Test` functions rather than methods on a
> `@Suite struct`, declare these as top-level `@MainActor @Test func …` instead — match
> the file's existing structure.

- [ ] **Step 2: Run test to verify it fails**

Run: `./Scripts/test.sh --filter MetricsStoreTests`
Expected: FAIL — `value of type 'MetricsStore' has no member 'beginBreakdown'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/MacStatsCore/MetricsStore.swift`, add these published properties after the existing `netDownHistory` published line (around line 15):

```swift
    @Published public private(set) var breakdown: [AppUsage] = []
    @Published public private(set) var breakdownMeasuring: Bool = false
    @Published public private(set) var activeBreakdownMetric: BreakdownMetric?
```

Add these methods inside the class (e.g. after `update(...)`):

```swift
    /// Enter a drill-in for `metric`. CPU starts in the "measuring" state (it needs two
    /// samples for a delta); memory is instantaneous so it isn't.
    public func beginBreakdown(metric: BreakdownMetric) {
        activeBreakdownMetric = metric
        breakdown = []
        breakdownMeasuring = (metric == .cpu)
    }

    /// Publish a fresh scan's grouped result for the active breakdown.
    public func setBreakdown(_ apps: [AppUsage], measuring: Bool) {
        breakdown = apps
        breakdownMeasuring = measuring
    }

    /// Leave the drill-in (back button or popover closed).
    public func clearBreakdown() {
        activeBreakdownMetric = nil
        breakdown = []
        breakdownMeasuring = false
    }
```

In the existing `reset()` method, add a call to clear the breakdown too (so closing the popover returns to a clean overview). Add this line inside `reset()`:

```swift
        clearBreakdown()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./Scripts/test.sh --filter MetricsStoreTests`
Expected: PASS (existing tests + 3 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacStatsCore/MetricsStore.swift Tests/MacStatsCoreTests/MetricsStoreTests.swift
git commit -m "feat: hold active per-app breakdown state in MetricsStore"
```

---

### Task 6: `ProcessActions` (Quit / Force Quit)

**Files:**
- Create: `Sources/MacStatsApp/ProcessActions.swift`

> AppKit termination isn't cleanly unit-testable; verified on-device in Task 11.

- [ ] **Step 1: Write the implementation**

Create `Sources/MacStatsApp/ProcessActions.swift`:

```swift
import AppKit

/// Quit actions for an app, addressed by its GUI app pid (the breakdown's group key).
/// `terminate()` is a graceful request — the app runs its normal quit, including any
/// unsaved-work prompt (like ⌘Q). `forceTerminate()` kills it immediately.
enum ProcessActions {
    static func quit(appPID: Int32) {
        NSRunningApplication(processIdentifier: pid_t(appPID))?.terminate()
    }

    static func forceQuit(appPID: Int32) {
        NSRunningApplication(processIdentifier: pid_t(appPID))?.forceTerminate()
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `Build complete!` (no errors).

- [ ] **Step 3: Commit**

```bash
git add Sources/MacStatsApp/ProcessActions.swift
git commit -m "feat: add Quit/Force Quit process actions via NSRunningApplication"
```

---

### Task 7: `AppModel` breakdown pipeline

**Files:**
- Modify: `Sources/MacStatsApp/MacStatsApp.swift`

> This wires the scan loop: a dedicated 1s timer that runs only while a breakdown is open.
> Timer + syscall behavior is verified on-device (Task 11); the build is the gate here.

- [ ] **Step 1: Add the breakdown state and pipeline to `AppModel`**

In `Sources/MacStatsApp/MacStatsApp.swift`, add these stored properties to `AppModel` (after `private var samplesSinceOpen = 0`):

```swift
    /// Dedicated per-process scan loop — exists only while a breakdown is open, so the
    /// expensive enumeration never runs otherwise. Kept separate from the sparkline `tick`.
    private var procTimer: Timer?
    private var previousProcCPU: [Int32: UInt64] = [:]   // pid → last cumulative CPU ns
    private var lastProcScan: Date?
```

- [ ] **Step 2: Add enter/exit/scan methods**

Add these methods to `AppModel`:

```swift
    func enterBreakdown(_ metric: MacStatsCore.BreakdownMetric) {
        store.beginBreakdown(metric: metric)
        previousProcCPU = [:]
        lastProcScan = nil
        procScanTick()   // first scan establishes the CPU baseline (CPU stays "measuring")
        procTimer?.invalidate()
        procTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.procScanTick() }
        }
    }

    func exitBreakdown() {
        procTimer?.invalidate()
        procTimer = nil
        previousProcCPU = [:]
        lastProcScan = nil
        store.clearBreakdown()
    }

    private func procScanTick() {
        guard let metric = store.activeBreakdownMetric else { return }
        let now = Date()
        let raw = readRawProcesses()

        // GUI apps the user is running = our "user apps only" universe + the grouping anchors.
        let appPIDs = Set(NSWorkspace.shared.runningApplications.compactMap { app -> Int32? in
            app.processIdentifier > 0 ? Int32(app.processIdentifier) : nil
        })
        let ppidMap = Dictionary(raw.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        let cpuByPID = Dictionary(raw.map { ($0.pid, $0.cpuTimeNs) }, uniquingKeysWith: { a, _ in a })

        let haveBaseline = lastProcScan != nil
        let elapsed = lastProcScan.map { now.timeIntervalSince($0) } ?? 0

        var usages: [ProcessUsage] = []
        for p in raw {
            guard let appPID = owningAppPID(for: p.pid, ppid: ppidMap, appPIDs: appPIDs) else { continue }
            let cpu = haveBaseline
                ? processCPUPercent(previousCPUTimeNs: previousProcCPU[p.pid] ?? p.cpuTimeNs,
                                    currentCPUTimeNs: p.cpuTimeNs, elapsedSeconds: elapsed)
                : 0
            usages.append(ProcessUsage(pid: p.pid, appPID: appPID, cpuPercent: cpu, memoryBytes: p.memoryBytes))
        }

        previousProcCPU = cpuByPID
        lastProcScan = now

        // CPU has no real values until the second scan; keep showing "Measuring…" until then.
        let measuring = (metric == .cpu && !haveBaseline)
        store.setBreakdown(aggregate(usages, by: metric), measuring: measuring)
    }
```

- [ ] **Step 3: Stop the scan when the popover closes**

In `setVisibility(_:)`, in the `.idle` case (which already invalidates the tick timer and calls `store.reset()`), add a call to stop the breakdown loop. Change the `.idle` case body to:

```swift
        case .idle:
            timer?.invalidate()
            timer = nil
            exitBreakdown()   // stop per-process scanning + clear nav state
            store.reset()     // each open session starts with a fresh sparkline
```

- [ ] **Step 4: Verify it builds**

Run: `swift build`
Expected: `Build complete!`

> `RootView` (Task 10) calls `enterBreakdown`/`exitBreakdown`; the build will still
> succeed now because they're `internal` methods that simply aren't called yet.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacStatsApp/MacStatsApp.swift
git commit -m "feat: per-process scan loop in AppModel, gated to open breakdowns"
```

---

### Task 8: Tappable `StatCard` with chevron

**Files:**
- Modify: `Sources/MacStatsApp/StatCard.swift`

- [ ] **Step 1: Add an optional tap handler + chevron**

Replace the contents of `Sources/MacStatsApp/StatCard.swift` with:

```swift
import SwiftUI

/// One row in the overview popover: label + big value + secondary line + sparkline.
/// When `onTap` is set, the whole row is clickable and shows a trailing chevron
/// (used for the CPU and Memory cards, which drill into a per-app breakdown).
struct StatCard: View {
    let label: String
    let value: String
    let meta: String
    let color: Color
    let history: [Double]
    let maxValue: Double
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3).fontWeight(.semibold)
                    .monospacedDigit()
                Text(meta)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 118, alignment: .leading)

            Sparkline(values: history, color: color, maxValue: maxValue)

            if onTap != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `Build complete!` (existing `StatCard(...)` call sites still compile — `onTap` defaults to nil).

- [ ] **Step 3: Commit**

```bash
git add Sources/MacStatsApp/StatCard.swift
git commit -m "feat: make StatCard optionally tappable with a chevron"
```

---

### Task 9: `BreakdownView` (drill-in list)

**Files:**
- Create: `Sources/MacStatsApp/BreakdownView.swift`

- [ ] **Step 1: Write the view**

Create `Sources/MacStatsApp/BreakdownView.swift`:

```swift
import SwiftUI
import AppKit
import MacStatsCore

/// The drill-in: a back header with the live total, then the ranked app list.
/// Right-click a row for Quit / Force Quit (Force Quit confirms first).
struct BreakdownView: View {
    @ObservedObject var store: MetricsStore
    let metric: BreakdownMetric
    let onBack: () -> Void

    @State private var forceQuitTarget: AppUsage?

    private var title: String { metric == .cpu ? "CPU" : "Memory" }

    private var liveTotal: String {
        switch metric {
        case .cpu:
            return "\(Int(store.cpuPercent.rounded()))% used"
        case .memory:
            guard let m = store.memory else { return "—" }
            return "\(gb(m.usedBytes)) / \(gb(m.totalBytes)) GB"
        }
    }

    /// Top app's value — used to scale the usage bars (sorted desc, so it's the first row).
    private var maxValue: Double { store.breakdown.first?.value(for: metric) ?? 1 }

    var body: some View {
        VStack(spacing: 0) {
            // header
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").fontWeight(.bold)
                        Text(title).fontWeight(.bold)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Text(liveTotal).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 8)
            Divider()

            if store.breakdownMeasuring {
                measuring
            } else if store.breakdown.isEmpty {
                Text("No apps").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.breakdown) { app in
                            AppRow(app: app, metric: metric, maxValue: maxValue)
                                .contextMenu {
                                    Button("Quit") { ProcessActions.quit(appPID: app.appPID) }
                                    Divider()
                                    Button("Force Quit", role: .destructive) { forceQuitTarget = app }
                                }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 300)   // ~8 rows visible, scroll for the rest
            }

            Divider()
            HStack {
                Button("Quit") { NSApplication.shared.terminate(nil) }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .frame(width: 320)
        .alert("Force quit \u{201C}\(appName(forceQuitTarget?.appPID))\u{201D}?",
               isPresented: Binding(get: { forceQuitTarget != nil },
                                    set: { if !$0 { forceQuitTarget = nil } })) {
            Button("Cancel", role: .cancel) { forceQuitTarget = nil }
            Button("Force Quit", role: .destructive) {
                if let t = forceQuitTarget { ProcessActions.forceQuit(appPID: t.appPID) }
                forceQuitTarget = nil
            }
        } message: {
            Text("The app will quit immediately and you\u{2019}ll lose any unsaved changes.")
        }
    }

    private var measuring: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Measuring\u{2026}").font(.callout).fontWeight(.semibold)
            Text("Sampling CPU usage").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 44)
    }

    private func appName(_ appPID: Int32?) -> String {
        guard let appPID else { return "this app" }
        return NSRunningApplication(processIdentifier: pid_t(appPID))?.localizedName ?? "PID \(appPID)"
    }

    private func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }
}

/// One app row: icon, name, usage bar, value. Name/icon resolved from the live app list.
private struct AppRow: View {
    let app: AppUsage
    let metric: BreakdownMetric
    let maxValue: Double

    var body: some View {
        let running = NSRunningApplication(processIdentifier: pid_t(app.appPID))
        let name = running?.localizedName ?? "PID \(app.appPID)"
        let color: Color = metric == .cpu ? .green : .blue

        HStack(spacing: 11) {
            icon(for: running)
                .resizable().frame(width: 24, height: 24).cornerRadius(6)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.callout).lineLimit(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(color)
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
                .frame(height: 4)
            }
            Spacer(minLength: 8)
            Text(valueText).font(.callout).fontWeight(.semibold)
                .monospacedDigit().foregroundStyle(.primary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var fraction: Double {
        guard maxValue > 0 else { return 0 }
        return min(1, app.value(for: metric) / maxValue)
    }

    private var valueText: String {
        switch metric {
        case .cpu:
            return "\(Int(app.cpuPercent.rounded()))%"
        case .memory:
            let mb = Double(app.memoryBytes) / 1_048_576
            return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
        }
    }

    private func icon(for running: NSRunningApplication?) -> Image {
        if let ns = running?.icon { return Image(nsImage: ns) }
        return Image(systemName: "app.dashed")
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/MacStatsApp/BreakdownView.swift
git commit -m "feat: add per-app breakdown drill-in view with right-click quit"
```

---

### Task 10: Navigation — `RootView` + wire the overview

**Files:**
- Create: `Sources/MacStatsApp/RootView.swift`
- Modify: `Sources/MacStatsApp/OverviewView.swift`
- Modify: `Sources/MacStatsApp/MacStatsApp.swift`

- [ ] **Step 1: Add `onSelect` to `OverviewView` and use it on CPU & Memory only**

In `Sources/MacStatsApp/OverviewView.swift`, add a stored closure to the struct (after `@ObservedObject var store: MetricsStore`):

```swift
    /// Drill into a category's per-app breakdown. Only CPU & Memory pass this in.
    var onSelect: (BreakdownMetric) -> Void
```

Change the **CPU** `StatCard(...)` to add a trailing `onTap`:

```swift
            StatCard(label: "CPU",
                     value: "\(Int(store.cpuPercent.rounded()))%",
                     meta: "live",
                     color: .green,
                     history: store.cpuHistory,
                     maxValue: 100,
                     onTap: { onSelect(.cpu) })
```

Change the **Memory** `StatCard(...)` to add:

```swift
                     maxValue: 1.0,
                     onTap: { onSelect(.memory) })
```

(Leave the Network and Battery cards exactly as they are — no `onTap`, so no chevron.)

- [ ] **Step 2: Create `RootView`**

Create `Sources/MacStatsApp/RootView.swift`:

```swift
import SwiftUI
import MacStatsCore

/// Top of the popover. Shows the overview, or the drill-in when a breakdown is active.
/// Owns the popover open/close lifecycle that drives the refresh pipeline.
struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let metric = model.store.activeBreakdownMetric {
                BreakdownView(store: model.store, metric: metric,
                              onBack: { model.exitBreakdown() })
            } else {
                OverviewView(store: model.store,
                             onSelect: { model.enterBreakdown($0) })
            }
        }
        .onAppear { model.setVisibility(.popoverOpen) }
        .onDisappear { model.setVisibility(.idle) }
    }
}
```

- [ ] **Step 3: Point the app at `RootView`**

In `Sources/MacStatsApp/MacStatsApp.swift`, replace the `MenuBarExtra` content closure. Change:

```swift
        MenuBarExtra {
            OverviewView(store: model.store)
                .onAppear { model.setVisibility(.popoverOpen) }
                .onDisappear { model.setVisibility(.idle) }
        } label: {
```

to:

```swift
        MenuBarExtra {
            RootView(model: model)
        } label: {
```

- [ ] **Step 4: Verify it builds**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 5: Run the full test suite (no regressions)**

Run: `./Scripts/test.sh`
Expected: PASS — the original 21 tests plus the new breakdown tests, all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacStatsApp/RootView.swift Sources/MacStatsApp/OverviewView.swift Sources/MacStatsApp/MacStatsApp.swift
git commit -m "feat: wire overview cards to per-app breakdown drill-in"
```

---

### Task 11: Bundle + on-device verification

**Files:** none (verification only)

> The collectors, grouping, and store are unit-tested; the syscall reader is smoke-tested.
> What remains can only be confirmed by running the real menu-bar app, per the project's
> "UI validated visually / sensors validated on-device" approach.

- [ ] **Step 1: Build the app bundle and launch**

Run:
```bash
./Scripts/bundle.sh && open MacStats.app
```
Expected: the menu-bar item appears (no Dock icon).

- [ ] **Step 2: Verify the overview affordances**

- [ ] Click the menu-bar item → overview popover opens.
- [ ] **CPU** and **Memory** cards show a `›` chevron; **Network** and **Battery** do not.

- [ ] **Step 3: Verify the CPU breakdown**

- [ ] Click the CPU card → content swaps to the CPU list; a brief **"Measuring…"** spinner shows, then a ranked list of apps appears (top consumers first, usage bars scaled, value in %).
- [ ] Only recognizable user apps appear (no `kernel_task` / root daemons).
- [ ] Multi-process apps (e.g. Chrome, if running) appear as **one** row with summed usage.
- [ ] The list scrolls; the header shows `‹ CPU` and a live `…% used` total.
- [ ] Click `‹ CPU` (back) → returns to the overview.

- [ ] **Step 4: Verify the Memory breakdown**

- [ ] Click the Memory card → list appears **immediately** (no "Measuring…"), values in GB/MB, sorted by memory, bars blue.

- [ ] **Step 5: Verify the actions**

- [ ] Right-click a row → menu shows **Quit** and (red) **Force Quit**.
- [ ] **Quit** a safe test app (e.g. Calculator) → it closes gracefully; the row drops out within ~1s.
- [ ] **Force Quit** → a confirmation alert appears first; confirming kills the app; Cancel does nothing.

- [ ] **Step 6: Verify the performance gate**

- [ ] Close the popover. In Activity Monitor, confirm MacStats sits near ~0% CPU when idle (per-process scanning only happens while a breakdown is open).

- [ ] **Step 7: Final commit (if any verification fixes were needed)**

```bash
git add -A
git commit -m "fix: address per-app breakdown on-device verification findings"
```

(Skip if no fixes were required.)

---

## Self-Review

**Spec coverage:**
- Trigger & in-popover drill-in on CPU/Memory only → Tasks 8 (chevron/tap), 10 (RootView swap, only CPU/Memory get `onSelect`). ✔
- Apps grouped, one row, summed → Tasks 2 (`owningAppPID`), 3 (`aggregate`), 9 (rows). ✔
- Sorted descending, top ~8 + scroll → Task 3 (sort), Task 9 (`ScrollView` `maxHeight: 300`). ✔
- User apps only → Task 7 (`appPIDs` from `NSWorkspace`; processes with no owning app skipped). ✔
- CPU % (can exceed 100) + Measuring state → Tasks 1 (math), 5 (flag), 7 (first-scan baseline), 9 (spinner). ✔
- Memory in GB/MB, instant (no measuring) → Tasks 5, 7, 9. ✔
- Right-click → Quit / Force Quit; Force Quit confirms only → Tasks 6 (actions), 9 (contextMenu + alert). ✔
- Scan only while open, 1s → Task 7 (dedicated timer started on enter, invalidated on exit/idle). ✔
- Network/Battery unchanged → Task 10 (no `onSelect` passed). ✔
- Edge cases (process exits, broken/cyclic chains, counter reset, empty list) → Tasks 1, 2, 9. ✔

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every test step shows the command and expected result. ✔

**Type consistency:** `BreakdownMetric`, `RawProcess`, `ProcessUsage`, `AppUsage` (with `value(for:)` and `id`) defined in Task 1 and used unchanged in Tasks 3, 5, 7, 9. `processCPUPercent`/`owningAppPID`/`aggregate` signatures defined in Tasks 1–3 match their call sites in Task 7. `readRawProcesses` (Task 4) returns `[RawProcess]` consumed in Task 7. Store methods `beginBreakdown`/`setBreakdown`/`clearBreakdown` + `activeBreakdownMetric`/`breakdown`/`breakdownMeasuring` defined in Task 5 and used in Tasks 7, 9, 10. `ProcessActions.quit/forceQuit(appPID:)` (Task 6) match Task 9 call sites. ✔
