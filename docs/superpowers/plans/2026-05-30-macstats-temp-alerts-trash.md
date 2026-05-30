# CPU Temperature, Threshold Alerts & Empty Trash — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three small features to MacStats — an Empty Trash action with a Trash-size readout, high-CPU/high-memory threshold notifications, and a CPU temperature reading in the CPU card.

**Architecture:** Pure logic (size summing, alert state machine, pressure mapping, temperature selection) lives in `MacStatsCore` and is unit-tested with Swift Testing. Impure readers (sysctl, private IOKit thermal sensors, AppleScript, UserNotifications) are thin wrappers, smoke-tested or manually verified. The `AppModel` orchestrator gains a slow background "alert sampler" that runs while the popover is closed.

**Tech Stack:** Swift 6 (language mode v5), SwiftUI, AppKit, `UNUserNotificationCenter`, `NSAppleScript`, private `IOHIDEventSystemClient` (via a C shim target), `sysctlbyname`. Build: SPM (Command-Line-Tools only). Tests: `./Scripts/test.sh` (Swift Testing; `--filter <Name>` to scope).

**Spec:** `docs/superpowers/specs/2026-05-30-macstats-temp-alerts-trash-design.md`

---

## File Structure

**New (Core):**
- `Sources/MacStatsCore/DiskUtils.swift` — pure `directorySize(at:)`.
- `Sources/MacStatsCore/AlertMonitor.swift` — `AlertKind`, `AlertSample`, pure `AlertMonitor` state machine.
- `Sources/MacStatsCore/CPUTemperature.swift` — pure `cpuTemperature(from:)` + `cpuSensorPrefixes`.
- `Sources/MacStatsCore/AppleSensorReader.swift` — impure `readAppleThermalSensors()`.

**New (C shim):**
- `Sources/CAppleSensors/include/CAppleSensors.h` — private IOHID prototypes.
- `Sources/CAppleSensors/shim.c` — empty translation unit (SPM needs one source).

**New (App):**
- `Sources/MacStatsApp/TrashActions.swift` — `NSAppleScript` empty + error handling.
- `Sources/MacStatsApp/AlertNotifier.swift` — `UNUserNotificationCenter` shim.

**Modified:**
- `Package.swift` — add `CAppleSensors` target; `MacStatsCore` depends on it.
- `Sources/MacStatsCore/MemoryStats.swift` — `memoryPressure(fromLevel:)`; `memorySample(…, pressureLevel:)`.
- `Sources/MacStatsCore/SystemReaders.swift` — `readMemoryPressureLevel()`.
- `Sources/MacStatsCore/MetricsStore.swift` — `cpuTempCelsius`, `trashBytes`, `trashMessage`; updated `update`/`reset`.
- `Sources/MacStatsApp/MacStatsApp.swift` — `AppModel`: alert sampler, feed monitor, read temp/trash/pressure, `emptyTrash()`.
- `Sources/MacStatsApp/OverviewView.swift` — CPU card temp line; Trash row + confirm.
- `Sources/MacStatsApp/RootView.swift` — pass `onEmptyTrash` to `OverviewView`.
- `Tests/MacStatsCoreTests/MemoryStatsTests.swift` — updated for the new pressure source.
- `README.md`, `CLAUDE.md` — document the three features + notification/automation caveats.

**Test files (new):**
- `Tests/MacStatsCoreTests/DiskUtilsTests.swift`
- `Tests/MacStatsCoreTests/AlertMonitorTests.swift`
- `Tests/MacStatsCoreTests/MemoryPressureTests.swift`
- `Tests/MacStatsCoreTests/CPUTemperatureTests.swift`
- `Tests/MacStatsCoreTests/AppleSensorReaderSmokeTests.swift`

---

# Phase 1 — Empty Trash (lowest risk, self-contained)

### Task 1: Pure `directorySize(at:)`

**Files:**
- Create: `Sources/MacStatsCore/DiskUtils.swift`
- Test: `Tests/MacStatsCoreTests/DiskUtilsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import MacStatsCore

@Suite struct DiskUtilsTests {
    @Test func sumsRegularFileSizes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstats-disk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("hello".utf8).write(to: dir.appendingPathComponent("a.txt"))   // 5 bytes
        try Data("12345".utf8).write(to: dir.appendingPathComponent("b.txt"))   // 5 bytes

        #expect(directorySize(at: dir) == 10)
    }

    @Test func emptyDirectoryIsZero() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstats-disk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(directorySize(at: dir) == 0)
    }

    @Test func missingDirectoryIsZero() {
        let dir = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(directorySize(at: dir) == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./Scripts/test.sh --filter DiskUtilsTests`
Expected: FAIL — `cannot find 'directorySize' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Total logical size (bytes) of regular files anywhere under `url`. Returns 0 if `url`
/// is missing or unreadable. Uses logical file size (`.fileSizeKey`), not allocated blocks,
/// so the value is deterministic and matches "size of the files in here".
public func directorySize(at url: URL) -> UInt64 {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }

    var total: UInt64 = 0
    for case let fileURL as URL in enumerator {
        guard let values = try? fileURL.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              let size = values.fileSize else { continue }
        total += UInt64(size)
    }
    return total
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./Scripts/test.sh --filter DiskUtilsTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacStatsCore/DiskUtils.swift Tests/MacStatsCoreTests/DiskUtilsTests.swift
git commit -m "feat(core): add directorySize for trash-size readout"
```

---

### Task 2: `TrashActions` — empty via Finder

**Files:**
- Create: `Sources/MacStatsApp/TrashActions.swift`

No unit test (it controls Finder; verified manually in Task 8 / on-device). Keep it thin.

- [ ] **Step 1: Write the implementation**

```swift
import Foundation

/// Empties the Trash by asking Finder (covers all volumes, like the real menu item).
/// There is no public FileManager API to empty the Trash, so we script Finder.
enum TrashActions {
    /// Returns nil on success, or a short user-facing message on failure.
    static func emptyTrash() -> String? {
        let script = NSAppleScript(source: "tell application \"Finder\" to empty the trash")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        guard let error else { return nil }

        let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        if code == -1743 {
            return "MacStats needs permission to control Finder. Enable it in "
                 + "System Settings → Privacy & Security → Automation, then try again."
        }
        return "Couldn’t empty the Trash (error \(code))."
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: Build complete (no errors).

- [ ] **Step 3: Commit**

```bash
git add Sources/MacStatsApp/TrashActions.swift
git commit -m "feat(app): add TrashActions.emptyTrash via Finder"
```

---

### Task 3: Wire Trash size + Empty into the store, AppModel, and UI

**Files:**
- Modify: `Sources/MacStatsCore/MetricsStore.swift`
- Modify: `Sources/MacStatsApp/MacStatsApp.swift`
- Modify: `Sources/MacStatsApp/RootView.swift`
- Modify: `Sources/MacStatsApp/OverviewView.swift`

- [ ] **Step 1: Add trash state to `MetricsStore`**

In `MetricsStore.swift`, add published properties after `netDownHistory`:

```swift
    @Published public private(set) var trashBytes: UInt64?
    @Published public var trashMessage: String?      // set when an Empty Trash attempt fails
```

Extend `update(...)` — add a `cpuTemp` parameter (unused until Task 13) and a `trashBytes`
parameter, both defaulted so existing call sites keep compiling. The `cpuTemp` parameter is
accepted now but NOT yet stored (the `cpuTempCelsius` property arrives in Task 13); only
`trashBytes` is stored in this task:

```swift
    public func update(cpuPercent: Double, memory: MemorySample?, network: NetworkSample?,
                       battery: BatterySample?, cpuTemp: Double? = nil, trashBytes: UInt64? = nil) {
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.network = network
        self.battery = battery
        self.trashBytes = trashBytes
        // (cpuTemp is wired to a published property in Task 13)

        cpuBuf.append(cpuPercent); cpuHistory = cpuBuf.values
        if let memory { memBuf.append(memory.usedFraction); memHistory = memBuf.values }
        if let network { netBuf.append(network.downBytesPerSec); netDownHistory = netBuf.values }
    }
```

And in `reset()`, after the buffer resets, add:

```swift
        trashBytes = nil
        trashMessage = nil
```

- [ ] **Step 2: Add Trash reading + emptying to `AppModel`**

In `MacStatsApp.swift`, inside `tick()`, replace the `store.update(...)` call so it passes the trash size:

```swift
        let trash = directorySize(at: FileManager.default.homeDirectoryForCurrentUser
                                       .appendingPathComponent(".Trash"))
        store.update(cpuPercent: cpu, memory: mem, network: net, battery: bat, trashBytes: trash)
```

Add an `emptyTrash()` method to `AppModel` (anywhere among its methods):

```swift
    func emptyTrash() {
        DispatchQueue.global(qos: .userInitiated).async {
            let message = TrashActions.emptyTrash()
            Task { @MainActor in self.store.trashMessage = message }
        }
    }
```

- [ ] **Step 3: Pass an `onEmptyTrash` closure through `RootView`**

In `RootView.swift`, update the `OverviewView` call:

```swift
                OverviewView(store: store,
                             onSelect: { model.enterBreakdown($0) },
                             onEmptyTrash: { model.emptyTrash() })
```

- [ ] **Step 4: Add the Trash row + confirm to `OverviewView`**

In `OverviewView.swift`, add the closure property near `onSelect`:

```swift
    var onEmptyTrash: () -> Void
```

Add confirm state at the top of the struct:

```swift
    @State private var showEmptyConfirm = false
```

Insert a Trash row directly above the final footer `HStack` (between the Battery card's trailing `Divider()` and the footer `Divider()`):

```swift
            Divider()
            HStack(spacing: 11) {
                Image(systemName: "trash")
                    .font(.callout).foregroundStyle(.secondary).frame(width: 24)
                Text("Trash").font(.callout)
                Spacer()
                Text(trashValue).font(.callout).fontWeight(.semibold).monospacedDigit()
                Button("Empty") { showEmptyConfirm = true }
                    .disabled((store.trashBytes ?? 0) == 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
```

Add the formatting helper and confirm/error alerts. Add this computed property next to `memoryValue`:

```swift
    private var trashValue: String {
        guard let bytes = store.trashBytes, bytes > 0 else { return "empty" }
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
```

Attach the alerts to the outer `VStack` (after `.frame(width: 320)`):

```swift
        .confirmationDialog("Empty the Trash?", isPresented: $showEmptyConfirm, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { onEmptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items in the Trash will be permanently deleted.")
        }
        .alert("Couldn’t empty the Trash",
               isPresented: Binding(get: { store.trashMessage != nil },
                                    set: { if !$0 { store.trashMessage = nil } })) {
            Button("OK", role: .cancel) { store.trashMessage = nil }
        } message: {
            Text(store.trashMessage ?? "")
        }
```

- [ ] **Step 5: Verify build + existing tests still pass**

Run: `swift build`
Expected: Build complete.
Run: `./Scripts/test.sh`
Expected: PASS (49 existing tests + 3 new DiskUtils = 52).

- [ ] **Step 6: Commit**

```bash
git add Sources/MacStatsCore/MetricsStore.swift Sources/MacStatsApp/MacStatsApp.swift Sources/MacStatsApp/RootView.swift Sources/MacStatsApp/OverviewView.swift
git commit -m "feat(app): show Trash size and add Empty Trash action"
```

---

# Phase 2 — Threshold alerts

### Task 4: Real memory-pressure mapping (pure)

**Files:**
- Modify: `Sources/MacStatsCore/MemoryStats.swift`
- Create: `Tests/MacStatsCoreTests/MemoryPressureTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MacStatsCore

@Suite struct MemoryPressureTests {
    @Test func mapsKernelLevels() {
        #expect(memoryPressure(fromLevel: 1) == .normal)
        #expect(memoryPressure(fromLevel: 2) == .warning)
        #expect(memoryPressure(fromLevel: 4) == .critical)
    }
    @Test func unknownLevelIsNormal() {
        #expect(memoryPressure(fromLevel: 0) == .normal)
        #expect(memoryPressure(fromLevel: 99) == .normal)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./Scripts/test.sh --filter MemoryPressureTests`
Expected: FAIL — `cannot find 'memoryPressure' in scope`.

- [ ] **Step 3: Implement the mapping + change `memorySample`**

In `MemoryStats.swift`, add the pure mapping (kernel pressure levels mirror `DISPATCH_MEMORYPRESSURE_*`: 1 normal, 2 warning, 4 critical):

```swift
/// Maps the kernel's `kern.memorystatus_vm_pressure_level` to our enum.
public func memoryPressure(fromLevel level: Int) -> MemoryPressure {
    switch level {
    case 2: return .warning
    case 4: return .critical
    default: return .normal   // 1 (normal) and anything unexpected
    }
}
```

Change `memorySample` to take the real level instead of guessing from the used fraction:

```swift
/// Approximates Activity Monitor's "memory used" as (active + wired + compressed).
/// Pressure comes from the kernel's real pressure level (see `memoryPressure(fromLevel:)`),
/// not a used-fraction heuristic.
public func memorySample(raw: VMRaw, totalBytes: UInt64, pressureLevel: Int) -> MemorySample {
    let used = (raw.active + raw.wired + raw.compressed) * raw.pageSize
    return MemorySample(usedBytes: used, totalBytes: totalBytes,
                        pressure: memoryPressure(fromLevel: pressureLevel))
}
```

- [ ] **Step 4: Update the existing `MemoryStatsTests` for the new signature**

Replace the whole body of `Tests/MacStatsCoreTests/MemoryStatsTests.swift` with:

```swift
import Testing
@testable import MacStatsCore

@Suite struct MemoryStatsTests {
    // pageSize 1 byte keeps the arithmetic obvious.
    @Test func usedIsActivePlusWiredPlusCompressed() {
        let raw = VMRaw(free: 100, active: 30, inactive: 20, wired: 10, compressed: 5, pageSize: 1)
        let s = memorySample(raw: raw, totalBytes: 200, pressureLevel: 1)
        #expect(s.usedBytes == 45)          // 30 + 10 + 5
        #expect(s.totalBytes == 200)
        #expect(abs(s.usedFraction - 0.225) < 0.0001)
        #expect(s.pressure == .normal)
    }

    @Test func pressureComesFromKernelLevel() {
        let raw = VMRaw(free: 0, active: 95, inactive: 0, wired: 0, compressed: 0, pageSize: 1)
        // Used fraction is 0.95, but pressure follows the kernel level, not the fraction.
        #expect(memorySample(raw: raw, totalBytes: 100, pressureLevel: 1).pressure == .normal)
        #expect(memorySample(raw: raw, totalBytes: 100, pressureLevel: 2).pressure == .warning)
        #expect(memorySample(raw: raw, totalBytes: 100, pressureLevel: 4).pressure == .critical)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./Scripts/test.sh --filter MemoryPressureTests`
Expected: PASS (2 tests).
Run: `./Scripts/test.sh --filter MemoryStatsTests`
Expected: PASS (2 tests).

(Build will still fail at the app layer until Task 6 updates the `memorySample` call site — that's fine; the filtered Core tests compile and pass. If `swift build` is run now it will error on the old call site; Task 6 fixes it. Do not run a bare `swift build` between Task 4 and Task 6.)

- [ ] **Step 6: Commit**

```bash
git add Sources/MacStatsCore/MemoryStats.swift Tests/MacStatsCoreTests/MemoryPressureTests.swift Tests/MacStatsCoreTests/MemoryStatsTests.swift
git commit -m "feat(core): source memory pressure from the real kernel level"
```

---

### Task 5: `readMemoryPressureLevel()` (impure sysctl reader)

**Files:**
- Modify: `Sources/MacStatsCore/SystemReaders.swift`
- Modify: `Tests/MacStatsCoreTests/SystemReadersSmokeTests.swift`

- [ ] **Step 1: Add the reader**

In `SystemReaders.swift`, add:

```swift
/// Reads the kernel's current memory-pressure level via sysctl.
/// Returns 1 (normal), 2 (warning), or 4 (critical); 1 on failure.
public func readMemoryPressureLevel() -> Int {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let ok = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
    return ok ? Int(level) : 1
}
```

- [ ] **Step 2: Add a smoke test**

Append to `SystemReadersSmokeTests.swift` (inside the suite):

```swift
    @Test func memoryPressureLevelIsKnown() {
        let level = readMemoryPressureLevel()
        #expect([1, 2, 4].contains(level))
    }
```

- [ ] **Step 3: Run the smoke test**

Run: `./Scripts/test.sh --filter SystemReadersSmokeTests`
Expected: PASS. (If this fails because the sysctl is restricted on this OS, see the spec's fallback note — switch to a `DispatchSource.makeMemoryPressureSource` cached level. Record the outcome and proceed.)

- [ ] **Step 4: Commit**

```bash
git add Sources/MacStatsCore/SystemReaders.swift Tests/MacStatsCoreTests/SystemReadersSmokeTests.swift
git commit -m "feat(core): read real memory-pressure level via sysctl"
```

---

### Task 6: `AlertMonitor` state machine (pure, TDD)

**Files:**
- Create: `Sources/MacStatsCore/AlertMonitor.swift`
- Create: `Tests/MacStatsCoreTests/AlertMonitorTests.swift`
- Modify: `Sources/MacStatsApp/MacStatsApp.swift` (fix the `memorySample` call site from Task 4)

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import MacStatsCore

@Suite struct AlertMonitorTests {
    // Small windows so timing is fast & deterministic.
    private func monitor() -> AlertMonitor {
        var c = AlertMonitor.Config()
        c.cpuThreshold = 85; c.cpuSustain = 30; c.cooldown = 300
        return AlertMonitor(config: c)
    }
    private func t(_ s: Double) -> Date { Date(timeIntervalSinceReferenceDate: s) }
    private func sample(cpu: Double, _ p: MemoryPressure, at s: Double) -> AlertSample {
        AlertSample(cpuPercent: cpu, pressure: p, time: t(s))
    }

    @Test func belowThresholdNeverFires() {
        let m = monitor()
        for s in stride(from: 0.0, through: 100, by: 10) {
            #expect(m.ingest(sample(cpu: 50, .normal, at: s)) == [])
        }
    }

    @Test func sustainedCPUFiresOnceAfterWindow() {
        let m = monitor()
        #expect(m.ingest(sample(cpu: 90, .normal, at: 0)) == [])    // just crossed
        #expect(m.ingest(sample(cpu: 90, .normal, at: 20)) == [])   // 20s < 30s sustain
        #expect(m.ingest(sample(cpu: 90, .normal, at: 30)) == [.highCPU])  // 30s sustained
        #expect(m.ingest(sample(cpu: 90, .normal, at: 40)) == [])   // already fired, not recovered
    }

    @Test func briefSpikeUnderWindowDoesNotFire() {
        let m = monitor()
        #expect(m.ingest(sample(cpu: 90, .normal, at: 0)) == [])
        #expect(m.ingest(sample(cpu: 50, .normal, at: 10)) == [])   // dropped before sustain
        #expect(m.ingest(sample(cpu: 90, .normal, at: 20)) == [])   // window restarts
        #expect(m.ingest(sample(cpu: 90, .normal, at: 45)) == [])   // only 25s since restart
    }

    @Test func cpuRefiresOnlyAfterRecoveryAndCooldown() {
        let m = monitor()
        #expect(m.ingest(sample(cpu: 90, .normal, at: 0)) == [])
        #expect(m.ingest(sample(cpu: 90, .normal, at: 30)) == [.highCPU])   // fires
        #expect(m.ingest(sample(cpu: 50, .normal, at: 40)) == [])          // recovery (re-arm)
        #expect(m.ingest(sample(cpu: 90, .normal, at: 50)) == [])          // above again
        #expect(m.ingest(sample(cpu: 90, .normal, at: 90)) == [])          // sustained, but cooldown not up (90 < 30+300)
        #expect(m.ingest(sample(cpu: 90, .normal, at: 360)) == [.highCPU]) // recovered + cooldown elapsed
    }

    @Test func memoryWarningAndCriticalFireOnceUntilRecovery() {
        let m = monitor()
        #expect(m.ingest(sample(cpu: 0, .normal, at: 0)) == [])
        #expect(m.ingest(sample(cpu: 0, .warning, at: 10)) == [.memoryPressure])  // fires immediately
        #expect(m.ingest(sample(cpu: 0, .critical, at: 20)) == [])                // no recovery yet
        #expect(m.ingest(sample(cpu: 0, .normal, at: 30)) == [])                  // recovery (re-arm)
        #expect(m.ingest(sample(cpu: 0, .critical, at: 400)) == [.memoryPressure]) // recovered + cooldown
    }

    @Test func bothCanFireInOneSample() {
        let m = monitor()
        _ = m.ingest(sample(cpu: 90, .normal, at: 0))
        let fired = m.ingest(sample(cpu: 90, .warning, at: 30))
        #expect(fired == [.highCPU, .memoryPressure])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./Scripts/test.sh --filter AlertMonitorTests`
Expected: FAIL — `cannot find 'AlertMonitor' in scope`.

- [ ] **Step 3: Implement `AlertMonitor`**

```swift
import Foundation

/// Which threshold was crossed.
public enum AlertKind: Equatable { case highCPU, memoryPressure }

/// One observation fed to the monitor.
public struct AlertSample: Equatable {
    public let cpuPercent: Double
    public let pressure: MemoryPressure
    public let time: Date
    public init(cpuPercent: Double, pressure: MemoryPressure, time: Date) {
        self.cpuPercent = cpuPercent; self.pressure = pressure; self.time = time
    }
}

/// Decides when to fire CPU / memory alerts. Pure: feed it samples, it returns the alerts
/// to fire now. Each metric fires once per episode — it must recover, then wait out a
/// cooldown, before it can fire again.
public final class AlertMonitor {
    public struct Config {
        public var cpuThreshold: Double = 85
        public var cpuSustain: TimeInterval = 30
        public var cooldown: TimeInterval = 300
        public init() {}
    }

    private let config: Config
    public init(config: Config = Config()) { self.config = config }

    // CPU state
    private var cpuAboveSince: Date?
    private var cpuArmed = true
    private var cpuLastFired: Date?
    // Memory state
    private var memArmed = true
    private var memLastFired: Date?

    public func ingest(_ s: AlertSample) -> [AlertKind] {
        var fired: [AlertKind] = []
        if checkCPU(s) { fired.append(.highCPU) }
        if checkMemory(s) { fired.append(.memoryPressure) }
        return fired
    }

    private func checkCPU(_ s: AlertSample) -> Bool {
        if s.cpuPercent > config.cpuThreshold {
            if cpuAboveSince == nil { cpuAboveSince = s.time }
            let sustained = s.time.timeIntervalSince(cpuAboveSince!) >= config.cpuSustain
            let cooled = cpuLastFired.map { s.time.timeIntervalSince($0) >= config.cooldown } ?? true
            if cpuArmed && sustained && cooled {
                cpuLastFired = s.time; cpuArmed = false
                return true
            }
        } else {
            cpuAboveSince = nil
            cpuArmed = true   // recovered → may fire again (after cooldown)
        }
        return false
    }

    private func checkMemory(_ s: AlertSample) -> Bool {
        if s.pressure == .warning || s.pressure == .critical {
            let cooled = memLastFired.map { s.time.timeIntervalSince($0) >= config.cooldown } ?? true
            if memArmed && cooled {
                memLastFired = s.time; memArmed = false
                return true
            }
        } else {
            memArmed = true   // back to normal → re-arm
        }
        return false
    }
}
```

- [ ] **Step 4: Fix the `memorySample` call site in `AppModel`**

In `MacStatsApp.swift`, in `tick()`, change the memory line to pass the real level:

```swift
        let mem = memorySample(raw: readVMRaw(),
                               totalBytes: ProcessInfo.processInfo.physicalMemory,
                               pressureLevel: readMemoryPressureLevel())
```

- [ ] **Step 5: Run tests + build**

Run: `./Scripts/test.sh --filter AlertMonitorTests`
Expected: PASS (6 tests).
Run: `swift build`
Expected: Build complete (call site fixed).

- [ ] **Step 6: Commit**

```bash
git add Sources/MacStatsCore/AlertMonitor.swift Tests/MacStatsCoreTests/AlertMonitorTests.swift Sources/MacStatsApp/MacStatsApp.swift
git commit -m "feat(core): add AlertMonitor sustain/recovery/cooldown state machine"
```

---

### Task 7: `AlertNotifier` (UserNotifications shim)

**Files:**
- Create: `Sources/MacStatsApp/AlertNotifier.swift`

- [ ] **Step 1: Write the implementation**

```swift
import Foundation
import UserNotifications
import MacStatsCore

/// Posts threshold alerts as user notifications. Asks permission once; if denied,
/// posting silently no-ops. Requires the bundled app (not the bare SPM binary).
@MainActor
final class AlertNotifier {
    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ kind: AlertKind) {
        let content = UNMutableNotificationContent()
        switch kind {
        case .highCPU:
            content.title = "High CPU usage"
            content.body = "CPU has been above 85% for the last 30 seconds."
        case .memoryPressure:
            content.title = "Memory pressure high"
            content.body = "Your Mac is low on available memory."
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add Sources/MacStatsApp/AlertNotifier.swift
git commit -m "feat(app): add AlertNotifier user-notification shim"
```

---

### Task 8: Background alert sampler in `AppModel`

**Files:**
- Modify: `Sources/MacStatsApp/MacStatsApp.swift`

- [ ] **Step 1: Add monitor, notifier, sampler state to `AppModel`**

Add stored properties near the other private vars:

```swift
    private let alertMonitor = AlertMonitor()
    private let notifier = AlertNotifier()
    private let alertsEnabled = true            // no Settings UI yet; default on
    private var alertTimer: Timer?
    private var alertBaselineCPU: CPUTicks?      // baseline for the slow idle CPU sample
```

- [ ] **Step 2: Request notification permission + start sampling at launch**

Add an initializer to `AppModel` (it currently has none):

```swift
    init() {
        notifier.requestAuthorization()
        startAlertSampler()
    }
```

- [ ] **Step 3: Implement the sampler (runs while the popover is closed)**

Add these methods to `AppModel`:

```swift
    /// Slow background sampler: reads only system-wide CPU% + memory pressure (no per-app
    /// scan, no sparkline writes) and feeds the alert monitor. Runs while the popover is closed.
    private func startAlertSampler() {
        guard alertsEnabled else { return }
        alertTimer?.invalidate()
        alertBaselineCPU = readCPUTicks()
        alertTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval(for: .idle),
                                          repeats: true) { [weak self] _ in
            Task { @MainActor in self?.alertSampleTick() }
        }
    }

    private func stopAlertSampler() {
        alertTimer?.invalidate()
        alertTimer = nil
        alertBaselineCPU = nil
    }

    private func alertSampleTick() {
        let current = readCPUTicks()
        defer { alertBaselineCPU = current }
        guard let baseline = alertBaselineCPU else { return }   // need two samples
        let cpu = cpuBusyPercent(previous: baseline, current: current)
        let pressure = memoryPressure(fromLevel: readMemoryPressureLevel())
        fireAlerts(cpu: cpu, pressure: pressure)
    }

    /// Feeds the monitor and posts whatever it returns. Shared by the idle sampler and the
    /// open-popover tick, so alerts fire regardless of visibility.
    private func fireAlerts(cpu: Double, pressure: MemoryPressure) {
        guard alertsEnabled else { return }
        let alerts = alertMonitor.ingest(AlertSample(cpuPercent: cpu, pressure: pressure, time: Date()))
        for alert in alerts { notifier.post(alert) }
    }
```

> Note `refreshInterval(for: .idle)` is 3.0s today. The spec calls for ~10s. Change
> `RefreshScheduler.swift`'s `.idle` case from `3.0` to `10.0`, and update its test
> `RefreshSchedulerTests.idleIsSlow` to expect `10.0`. Do this in this step (small, contained):
>
> In `RefreshScheduler.swift`: `case .idle: return 10.0`
> In `RefreshSchedulerTests.swift`: `#expect(abs(refreshInterval(for: .idle) - 10.0) < 0.001)`

- [ ] **Step 4: Toggle samplers on visibility changes + feed monitor while open**

In `setVisibility(_:)`, update both cases:

```swift
        case .popoverOpen:
            stopAlertSampler()
            samplesSinceOpen = 0
            snapshots = [Snapshot(time: Date(), cpu: readCPUTicks(), net: readNetCounters())]
            scheduleNextTick()
        case .idle:
            timer?.invalidate()
            timer = nil
            exitBreakdown()
            store.reset()
            startAlertSampler()
```

In `tick()`, after computing `cpu` and `mem`, feed the monitor (so alerts stay live while open):

```swift
        fireAlerts(cpu: cpu, pressure: mem.pressure)
```

(Place it after the `store.update(...)` line. `mem` is the `MemorySample` already computed in `tick()`.)

- [ ] **Step 5: Build + full test run**

Run: `swift build`
Expected: Build complete.
Run: `./Scripts/test.sh`
Expected: PASS (existing + new; `RefreshSchedulerTests.idleIsSlow` now asserts 10.0).

- [ ] **Step 6: Commit**

```bash
git add Sources/MacStatsApp/MacStatsApp.swift Sources/MacStatsCore/RefreshScheduler.swift Tests/MacStatsCoreTests/RefreshSchedulerTests.swift
git commit -m "feat(app): background alert sampler feeding AlertMonitor + notifications"
```

---

### Task 9: Manual on-device verification of alerts

**Files:** none (manual).

- [ ] **Step 1: Build + run the bundled app**

Run: `./Scripts/bundle.sh && open MacStats.app`
Expected: Menu-bar icon appears; macOS prompts for notification permission on first launch — allow it.

- [ ] **Step 2: Trigger a high-CPU alert**

Run a CPU burner for ~40s (longer than the 30s sustain), e.g.:
`yes > /dev/null & yes > /dev/null & sleep 40; kill %1 %2`
Expected: a "High CPU usage" notification appears within ~30–40s, and only once per episode.

- [ ] **Step 3: Record the result**

Note pass/fail in the task tracker. If notifications don't appear, confirm the app is the bundled `.app` (not the bare binary) and that permission was granted.

---

# Phase 3 — CPU temperature (spike-first; can be deferred without affecting Phases 1–2)

### Task 10: Add the `CAppleSensors` C shim target

**Files:**
- Create: `Sources/CAppleSensors/include/CAppleSensors.h`
- Create: `Sources/CAppleSensors/shim.c`
- Modify: `Package.swift`

- [ ] **Step 1: Write the C header (private IOHID prototypes)**

`Sources/CAppleSensors/include/CAppleSensors.h`:

```c
#ifndef CAPPLESENSORS_H
#define CAPPLESENSORS_H

#include <CoreFoundation/CoreFoundation.h>

typedef CFTypeRef IOHIDEventSystemClientRef;
typedef CFTypeRef IOHIDServiceClientRef;
typedef CFTypeRef IOHIDEventRef;

// Private IOKit thermal-sensor API (resolved from the IOKit framework at link time).
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
CFStringRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type,
                                          int32_t options, int64_t options2);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#endif
```

`Sources/CAppleSensors/shim.c`:

```c
#include "CAppleSensors.h"
// Intentionally empty: this target only declares prototypes and links IOKit.
```

- [ ] **Step 2: Wire the target into `Package.swift`**

Replace the `targets:` array so `CAppleSensors` exists and `MacStatsCore` depends on it:

```swift
    targets: [
        .target(
            name: "CAppleSensors",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(name: "MacStatsCore", dependencies: ["CAppleSensors"]),
        .executableTarget(
            name: "MacStatsApp",
            dependencies: ["MacStatsCore"]
        ),
        .testTarget(
            name: "MacStatsCoreTests",
            dependencies: ["MacStatsCore"]
        ),
    ],
```

- [ ] **Step 3: Verify the package builds with the new C module**

Run: `swift build`
Expected: Build complete (the C module compiles; nothing imports it yet).

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/CAppleSensors
git commit -m "build: add CAppleSensors C shim for private IOHID thermal API"
```

---

### Task 11: `readAppleThermalSensors()` + on-device sensor spike

**Files:**
- Create: `Sources/MacStatsCore/AppleSensorReader.swift`
- Create: `Tests/MacStatsCoreTests/AppleSensorReaderSmokeTests.swift`

- [ ] **Step 1: Implement the reader**

```swift
import Foundation
import CoreFoundation
import CAppleSensors

/// Reads Apple thermal sensors via the private IOHIDEventSystemClient API.
/// Returns (sensor name, °C) pairs. Empty if the API yields nothing (graceful no-temp).
///
/// CF memory note: the matched services array is owned by us (Copy). Adjust the
/// retain/release bridging below until it both compiles and runs without leaking/crashing.
public func readAppleThermalSensors() -> [(name: String, celsius: Double)] {
    let kIOHIDEventTypeTemperature: Int64 = 15
    let temperatureField: Int32 = Int32(kIOHIDEventTypeTemperature << 16)   // 983040

    let matching: [String: Int] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]

    guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return [] }
    IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
    guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClientRef] else {
        return []
    }

    var result: [(name: String, celsius: Double)] = []
    for service in services {
        guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String,
              let event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0)
        else { continue }
        let celsius = IOHIDEventGetFloatValue(event, temperatureField)
        result.append((name: name, celsius: celsius))
    }
    return result
}
```

> If the `as? [IOHIDServiceClientRef]` cast or the CF return bridging fails to compile,
> iterate: `IOHIDServiceClientRef` is `CFTypeRef`; you may need
> `(services as NSArray) as? [AnyObject]` and `unsafeBitCast`, or to treat the create/copy
> results as `Unmanaged<…>` and `.takeRetainedValue()`. Resolve until `swift build` is clean.

- [ ] **Step 2: Add a smoke test (must not crash; list may be empty)**

```swift
import Testing
@testable import MacStatsCore

@Suite struct AppleSensorReaderSmokeTests {
    @Test func returnsSensorsWithoutCrashing() {
        let sensors = readAppleThermalSensors()
        // May be empty on some machines; values, when present, should be physically sane.
        for s in sensors where s.celsius != 0 {
            #expect(s.celsius > -50 && s.celsius < 150)
        }
        _ = sensors  // primarily a does-not-crash check
    }
}
```

- [ ] **Step 3: Build + run the smoke test**

Run: `swift build`
Expected: Build complete.
Run: `./Scripts/test.sh --filter AppleSensorReaderSmokeTests`
Expected: PASS.

- [ ] **Step 4: SPIKE — dump sensor names on this M3**

Add a TEMPORARY test to the smoke file to print every sensor (Swift Testing shows stdout):

```swift
    @Test func dumpSensors() {
        for s in readAppleThermalSensors().sorted(by: { $0.name < $1.name }) {
            print("SENSOR \(s.name) = \(s.celsius)")
        }
    }
```

Run: `./Scripts/test.sh --filter AppleSensorReaderSmokeTests 2>&1 | grep SENSOR`
Expected: a list of sensor names with values. Identify the CPU-cluster sensors (commonly names
beginning `Tp` for performance cores, `Te`/`Tc` for efficiency cores; values should sit roughly
30–90°C under load). **Record the chosen prefixes** — they feed Task 12's `cpuSensorPrefixes`.
Then DELETE the temporary `dumpSensors` test.

- [ ] **Step 5: Commit (reader + smoke test, spike test removed)**

```bash
git add Sources/MacStatsCore/AppleSensorReader.swift Tests/MacStatsCoreTests/AppleSensorReaderSmokeTests.swift
git commit -m "feat(core): read Apple thermal sensors via private IOHID API"
```

---

### Task 12: Pure `cpuTemperature(from:)` selection + averaging (TDD)

**Files:**
- Create: `Sources/MacStatsCore/CPUTemperature.swift`
- Create: `Tests/MacStatsCoreTests/CPUTemperatureTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import MacStatsCore

@Suite struct CPUTemperatureTests {
    @Test func averagesCPUClusterSensors() {
        let sensors: [(name: String, celsius: Double)] = [
            ("Tp01", 50), ("Tp05", 60),   // CPU cluster (prefix Tp)
            ("Tg0H", 70),                  // GPU — ignored
        ]
        // average of 50 and 60 = 55
        #expect(cpuTemperature(from: sensors) == 55)
    }

    @Test func ignoresOutOfRangeReadings() {
        let sensors: [(name: String, celsius: Double)] = [
            ("Tp01", 0), ("Tp02", 200), ("Tp03", 40),   // 0 and 200 are nonsense
        ]
        #expect(cpuTemperature(from: sensors) == 40)
    }

    @Test func emptyOrNoMatchReturnsNil() {
        #expect(cpuTemperature(from: []) == nil)
        #expect(cpuTemperature(from: [("Tg0H", 70), ("Ta0p", 30)]) == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./Scripts/test.sh --filter CPUTemperatureTests`
Expected: FAIL — `cannot find 'cpuTemperature' in scope`.

- [ ] **Step 3: Implement**

```swift
/// Sensor-name prefixes treated as CPU-cluster temperatures. Confirmed against this machine
/// in the Task 11 spike; adjust here if the dump shows different CPU names.
public let cpuSensorPrefixes = ["Tp", "Tc", "Te"]

/// Average CPU temperature (°C, rounded) from a set of named thermal sensors, or nil if no
/// CPU-cluster sensor reports a physically sane value.
public func cpuTemperature(from sensors: [(name: String, celsius: Double)]) -> Double? {
    let cpu = sensors.filter { sensor in
        cpuSensorPrefixes.contains { sensor.name.hasPrefix($0) }
    }
    let valid = cpu.filter { $0.celsius > 0 && $0.celsius < 150 }
    guard !valid.isEmpty else { return nil }
    let avg = valid.map(\.celsius).reduce(0, +) / Double(valid.count)
    return avg.rounded()
}
```

> If the Task 11 spike showed different CPU-cluster prefixes on this M3, update
> `cpuSensorPrefixes` accordingly (and the test names if needed) before moving on.

- [ ] **Step 4: Run tests to verify they pass**

Run: `./Scripts/test.sh --filter CPUTemperatureTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacStatsCore/CPUTemperature.swift Tests/MacStatsCoreTests/CPUTemperatureTests.swift
git commit -m "feat(core): select & average CPU-cluster thermal sensors"
```

---

### Task 13: Show temperature in the CPU card

**Files:**
- Modify: `Sources/MacStatsCore/MetricsStore.swift`
- Modify: `Sources/MacStatsApp/MacStatsApp.swift`
- Modify: `Sources/MacStatsApp/OverviewView.swift`

- [ ] **Step 1: Add `cpuTempCelsius` to `MetricsStore`**

In `MetricsStore.swift`, add the published property (near `trashBytes`):

```swift
    @Published public private(set) var cpuTempCelsius: Double?
```

In `update(...)`, add the assignment (the `cpuTemp` parameter already exists from Task 3):

```swift
        self.cpuTempCelsius = cpuTemp
```

In `reset()`, add:

```swift
        cpuTempCelsius = nil
```

- [ ] **Step 2: Read temperature in `AppModel.tick()`**

In `MacStatsApp.swift`, in `tick()`, compute the temp and pass it to `update`:

```swift
        let temp = cpuTemperature(from: readAppleThermalSensors())
```

Update the `store.update(...)` call to include it (it already passes `trashBytes`):

```swift
        store.update(cpuPercent: cpu, memory: mem, network: net, battery: bat,
                     cpuTemp: temp, trashBytes: trash)
```

- [ ] **Step 3: Render temp in the CPU card's meta line**

In `OverviewView.swift`, change the CPU `StatCard`'s `meta` argument from `"live"` to `cpuMeta`:

```swift
            StatCard(label: "CPU",
                     value: "\(Int(store.cpuPercent.rounded()))%",
                     meta: cpuMeta,
                     color: .green,
                     history: store.cpuHistory,
                     maxValue: 100,
                     onTap: { onSelect(.cpu) })
```

Add the computed property (next to `memoryMeta`):

```swift
    private var cpuMeta: String {
        guard let t = store.cpuTempCelsius else { return "live" }
        return "\(Int(t))°C"
    }
```

- [ ] **Step 4: Build + full test run**

Run: `swift build`
Expected: Build complete.
Run: `./Scripts/test.sh`
Expected: PASS (all suites).

- [ ] **Step 5: On-device check**

Run: `./Scripts/bundle.sh && open MacStats.app`
Open the popover. Expected: the CPU card's second line shows a temperature like `58°C` (or
falls back to `live` if no sensor was found). Sanity-check the number against a reference tool if
available.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacStatsCore/MetricsStore.swift Sources/MacStatsApp/MacStatsApp.swift Sources/MacStatsApp/OverviewView.swift
git commit -m "feat(app): show CPU temperature in the CPU card"
```

---

# Phase 4 — Documentation

### Task 14: Update README & CLAUDE.md

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update `README.md`**

- Move CPU temperature, alerts, and Empty Trash from "Planned" to "Built" in the Features list.
- Add a line under "Building from source": *"Threshold notifications require the bundled
  `MacStats.app` (not the bare `swift build` binary), and Empty Trash asks once for permission to
  control Finder."*
- In the Roadmap table, note Milestone 2 (CPU temp) and part of Milestone 4 (alerts) are now partly built.

- [ ] **Step 2: Update `CLAUDE.md`**

- In the Status section, add a bullet: *"✅ CPU temperature (CPU card), high-CPU/memory threshold
  alerts (background sampler + notifications), and Empty Trash built (2026-05-30)."*
- Note the idle cadence is now 10s and actually used (background alert sampler), and that
  memory pressure now uses the real kernel level.

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: document CPU temp, alerts, and Empty Trash"
```

---

## Final verification

- [ ] `./Scripts/test.sh` — all suites pass (expect ~63 tests: 49 original + DiskUtils 3 + MemoryPressure 2 + AlertMonitor 6 + CPUTemperature 3 + smoke additions; MemoryStats stays 2 after rewrite).
- [ ] `./Scripts/bundle.sh && open MacStats.app` — popover shows CPU temp + Trash size; Empty Trash works (with the Finder permission prompt); a sustained CPU load produces a notification.
- [ ] No `swift build` warnings introduced.

## Notes for the executor

- **Phases are independent.** If Phase 3 (CPU temp) hits an unresolvable wall with the private API
  on this machine, Phases 1–2 still ship; the CPU card simply keeps showing `live`. Don't let temp
  block the rest.
- **Build-order caveat:** between Task 4 and Task 6, a bare `swift build` will fail on the old
  `memorySample` call site — that's expected; run filtered Core tests instead until Task 6 fixes it.
- **CF bridging** in Task 11 is the one place to expect iteration; let the compiler guide the exact
  `Unmanaged`/cast form.
