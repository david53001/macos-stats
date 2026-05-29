# MacStats — Milestone 1 (Foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A runnable, non-sandboxed macOS menu-bar app that shows live CPU %, Memory, Network speed, and Battery % — with a click-to-open overview popover containing one card per stat and a live Swift Charts sparkline, and an adaptive refresh that is near-free when idle.

**Architecture:** Swift Package Manager package with two targets: `MacStatsCore` (a library of pure value types, derivation functions, a ring buffer, an observable store, and thin syscall readers) and `MacStatsApp` (the SwiftUI `MenuBarExtra` app that wires readers → derivations → store → views on an adaptive timer). All non-trivial logic lives in pure functions in `MacStatsCore` and is unit-tested with XCTest (`swift test`); the syscall readers get plausibility "smoke" tests; SwiftUI views are verified by building and running. The app is assembled into a `.app` bundle (with `LSUIElement` so it has no Dock icon) by a shell script.

**Tech Stack:** Swift 6.2 (language mode v5), Swift Package Manager (Command Line Tools — no full Xcode), SwiftUI `MenuBarExtra`, Swift Charts, Mach/IOKit/`getifaddrs` system APIs, XCTest.

**Reference docs:** Design spec `docs/superpowers/specs/2026-05-29-macstats-menubar-design.md`; approved visual mockup `docs/mockups/menubar-mockup.html` (open in a browser — the popover/card/sparkline look is the build target).

**Scope note:** This milestone deliberately excludes CPU temperature (Milestone 2 — needs IOKit IOHID), per-app breakdowns/drill-in (Milestone 3), and Settings/customizable bar/alerts (Milestone 4). Memory "pressure" here is a simple used-fraction heuristic; the true `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` source is a later refinement.

---

## File Structure

```
MacStats/
  Package.swift                         # SPM manifest, 2 targets + test target
  .gitignore
  Resources/Info.plist                  # app bundle plist (LSUIElement = true)
  Scripts/bundle.sh                     # assemble MacStats.app from the built executable
  Sources/
    MacStatsCore/
      RingBuffer.swift                  # generic fixed-capacity buffer (history)
      CPUUsage.swift                    # CPUTicks + cpuBusyPercent()  [pure]
      MemoryStats.swift                 # VMRaw, MemorySample, memorySample()  [pure]
      NetworkThroughput.swift           # NetCounters, NetworkSample, networkThroughput()  [pure]
      BatteryParse.swift                # BatterySample, parseBattery()  [pure]
      RefreshScheduler.swift            # Visibility, refreshInterval()  [pure]
      SystemReaders.swift               # readCPUTicks/readVMRaw/readNetCounters/readBattery  [syscalls]
      MetricsStore.swift                # @MainActor ObservableObject: latest + history
    MacStatsApp/
      MacStatsApp.swift                 # @main App + MenuBarExtra + AppModel (timer wiring)
      MenuBarLabel.swift                # the text shown in the menu bar
      OverviewView.swift                # popover content: header + cards + footer
      StatCard.swift                    # one stat row (label, value, sparkline)
      Sparkline.swift                   # Swift Charts area+line mini chart
  Tests/
    MacStatsCoreTests/
      RingBufferTests.swift
      CPUUsageTests.swift
      MemoryStatsTests.swift
      NetworkThroughputTests.swift
      BatteryParseTests.swift
      RefreshSchedulerTests.swift
      MetricsStoreTests.swift
      SystemReadersSmokeTests.swift
```

---

### Task 1: Package scaffold, git init, build green

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/MacStatsCore/RingBuffer.swift` (temporary stub so the library target has a file)
- Create: `Sources/MacStatsApp/MacStatsApp.swift` (minimal static menu-bar app)

- [ ] **Step 1: Create `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacStats",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MacStatsCore"),
        .executableTarget(
            name: "MacStatsApp",
            dependencies: ["MacStatsCore"]
        ),
        .testTarget(
            name: "MacStatsCoreTests",
            dependencies: ["MacStatsCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
```

- [ ] **Step 2: Create `.gitignore`**

```gitignore
.build/
MacStats.app/
.superpowers/
.DS_Store
*.swiftpm
```

- [ ] **Step 3: Create a temporary stub `Sources/MacStatsCore/RingBuffer.swift`** (replaced with the real thing in Task 2; needed now so the target compiles)

```swift
// Replaced in Task 2.
public enum MacStatsCore {}
```

- [ ] **Step 4: Create minimal `Sources/MacStatsApp/MacStatsApp.swift`**

```swift
import SwiftUI

@main
struct MacStatsApp: App {
    var body: some Scene {
        MenuBarExtra("MacStats") {
            Text("MacStats is running.")
                .padding()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .padding(.bottom)
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 5: Create a placeholder test so the declared `testTarget` directory exists**

SPM validates every declared target's source directory *before* building, so the test target needs at least one file now. Create `Tests/MacStatsCoreTests/PlaceholderTests.swift` (deleted in Task 2 once a real test exists):

```swift
import XCTest

final class PlaceholderTests: XCTestCase {
    func testScaffoldBuilds() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 6: Build to verify the toolchain + structure**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 7: Initialize git and commit**

```bash
git init
git add Package.swift .gitignore Sources Tests docs
git commit -m "chore: scaffold MacStats SPM package with menu-bar app shell"
```

---

### Task 2: RingBuffer (history storage)

**Files:**
- Modify (replace stub): `Sources/MacStatsCore/RingBuffer.swift`
- Test: `Tests/MacStatsCoreTests/RingBufferTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MacStatsCore

final class RingBufferTests: XCTestCase {
    func testKeepsOnlyLastCapacityValuesInOrder() {
        var buf = RingBuffer<Int>(capacity: 3)
        buf.append(1); buf.append(2); buf.append(3); buf.append(4)
        XCTAssertEqual(buf.values, [2, 3, 4])
        XCTAssertEqual(buf.count, 3)
    }

    func testUnderCapacityKeepsAll() {
        var buf = RingBuffer<Int>(capacity: 5)
        buf.append(7); buf.append(8)
        XCTAssertEqual(buf.values, [7, 8])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RingBufferTests`
Expected: FAIL — `RingBuffer` not found / no member `values` (stub has no such type).

- [ ] **Step 3: Replace the stub with the implementation**

```swift
/// Fixed-capacity buffer that keeps the most recent `capacity` appended values.
public struct RingBuffer<Element> {
    private var storage: [Element] = []
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "capacity must be > 0")
        self.capacity = capacity
    }

    public mutating func append(_ element: Element) {
        storage.append(element)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    /// Oldest-to-newest.
    public var values: [Element] { storage }
    public var count: Int { storage.count }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RingBufferTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Remove the placeholder test (a real test now exists)**

```bash
git rm Tests/MacStatsCoreTests/PlaceholderTests.swift
```

- [ ] **Step 6: Commit**

```bash
git add Sources/MacStatsCore/RingBuffer.swift Tests/MacStatsCoreTests/RingBufferTests.swift
git commit -m "feat: add RingBuffer for metric history"
```

---

### Task 3: CPU usage derivation

**Files:**
- Create: `Sources/MacStatsCore/CPUUsage.swift`
- Test: `Tests/MacStatsCoreTests/CPUUsageTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MacStatsCore

final class CPUUsageTests: XCTestCase {
    func testHalfBusy() {
        let prev = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let cur  = CPUTicks(user: 25, system: 25, idle: 50, nice: 0)
        XCTAssertEqual(cpuBusyPercent(previous: prev, current: cur), 50, accuracy: 0.001)
    }

    func testNoTimeElapsedReturnsZero() {
        let t = CPUTicks(user: 10, system: 10, idle: 10, nice: 0)
        XCTAssertEqual(cpuBusyPercent(previous: t, current: t), 0, accuracy: 0.001)
    }

    func testClampedTo100() {
        let prev = CPUTicks(user: 0, system: 0, idle: 10, nice: 0)
        let cur  = CPUTicks(user: 100, system: 0, idle: 10, nice: 0)
        XCTAssertEqual(cpuBusyPercent(previous: prev, current: cur), 100, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CPUUsageTests`
Expected: FAIL — `CPUTicks` / `cpuBusyPercent` not found.

- [ ] **Step 3: Write the implementation**

```swift
/// Cumulative CPU tick counts (since boot) in the four Mach CPU states.
public struct CPUTicks: Equatable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }

    public var total: UInt64 { UInt64(user) + UInt64(system) + UInt64(idle) + UInt64(nice) }
    public var busy: UInt64 { UInt64(user) + UInt64(system) + UInt64(nice) }
}

/// Busy CPU percentage (0...100) between two cumulative tick snapshots.
public func cpuBusyPercent(previous: CPUTicks, current: CPUTicks) -> Double {
    let totalDelta = Double(current.total) - Double(previous.total)
    guard totalDelta > 0 else { return 0 }
    let busyDelta = Double(current.busy) - Double(previous.busy)
    return max(0, min(100, busyDelta / totalDelta * 100))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CPUUsageTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacStatsCore/CPUUsage.swift Tests/MacStatsCoreTests/CPUUsageTests.swift
git commit -m "feat: add CPU busy-percent derivation"
```

---

### Task 4: Memory stats derivation

**Files:**
- Create: `Sources/MacStatsCore/MemoryStats.swift`
- Test: `Tests/MacStatsCoreTests/MemoryStatsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MacStatsCore

final class MemoryStatsTests: XCTestCase {
    // pageSize 1 byte keeps the arithmetic obvious.
    func testUsedIsActivePlusWiredPlusCompressed() {
        let raw = VMRaw(free: 100, active: 30, inactive: 20, wired: 10, compressed: 5, pageSize: 1)
        let s = memorySample(raw: raw, totalBytes: 200)
        XCTAssertEqual(s.usedBytes, 45)          // 30 + 10 + 5
        XCTAssertEqual(s.totalBytes, 200)
        XCTAssertEqual(s.usedFraction, 0.225, accuracy: 0.0001)
        XCTAssertEqual(s.pressure, .normal)
    }

    func testWarningAndCriticalThresholds() {
        let warn = memorySample(raw: VMRaw(free: 0, active: 80, inactive: 0, wired: 0, compressed: 0, pageSize: 1), totalBytes: 100)
        XCTAssertEqual(warn.pressure, .warning)  // 0.80 > 0.75
        let crit = memorySample(raw: VMRaw(free: 0, active: 95, inactive: 0, wired: 0, compressed: 0, pageSize: 1), totalBytes: 100)
        XCTAssertEqual(crit.pressure, .critical) // 0.95 > 0.90
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MemoryStatsTests`
Expected: FAIL — `VMRaw` / `memorySample` not found.

- [ ] **Step 3: Write the implementation**

```swift
/// Raw VM page counts from the kernel (counts are in pages; multiply by pageSize for bytes).
public struct VMRaw: Equatable {
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var pageSize: UInt64

    public init(free: UInt64, active: UInt64, inactive: UInt64, wired: UInt64, compressed: UInt64, pageSize: UInt64) {
        self.free = free; self.active = active; self.inactive = inactive
        self.wired = wired; self.compressed = compressed; self.pageSize = pageSize
    }
}

public enum MemoryPressure: Equatable { case normal, warning, critical }

public struct MemorySample: Equatable {
    public var usedBytes: UInt64
    public var totalBytes: UInt64
    public var pressure: MemoryPressure

    public init(usedBytes: UInt64, totalBytes: UInt64, pressure: MemoryPressure) {
        self.usedBytes = usedBytes; self.totalBytes = totalBytes; self.pressure = pressure
    }

    public var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }
}

/// Approximates Activity Monitor's "memory used" as (active + wired + compressed).
/// NOTE: pressure here is a used-fraction heuristic; a real memory-pressure source
/// (DISPATCH_SOURCE_TYPE_MEMORYPRESSURE) is a later refinement.
public func memorySample(raw: VMRaw, totalBytes: UInt64) -> MemorySample {
    let used = (raw.active + raw.wired + raw.compressed) * raw.pageSize
    let frac = totalBytes > 0 ? Double(used) / Double(totalBytes) : 0
    let pressure: MemoryPressure = frac > 0.90 ? .critical : (frac > 0.75 ? .warning : .normal)
    return MemorySample(usedBytes: used, totalBytes: totalBytes, pressure: pressure)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MemoryStatsTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacStatsCore/MemoryStats.swift Tests/MacStatsCoreTests/MemoryStatsTests.swift
git commit -m "feat: add memory-usage derivation"
```

---

### Task 5: Network throughput derivation

**Files:**
- Create: `Sources/MacStatsCore/NetworkThroughput.swift`
- Test: `Tests/MacStatsCoreTests/NetworkThroughputTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MacStatsCore

final class NetworkThroughputTests: XCTestCase {
    func testBytesPerSecond() {
        let prev = NetCounters(rxBytes: 1_000, txBytes: 500)
        let cur  = NetCounters(rxBytes: 3_000, txBytes: 1_500)
        let s = networkThroughput(previous: prev, current: cur, secondsElapsed: 2)
        XCTAssertEqual(s.downBytesPerSec, 1_000, accuracy: 0.001) // (3000-1000)/2
        XCTAssertEqual(s.upBytesPerSec, 500, accuracy: 0.001)     // (1500-500)/2
    }

    func testZeroElapsedReturnsZero() {
        let c = NetCounters(rxBytes: 10, txBytes: 10)
        let s = networkThroughput(previous: c, current: c, secondsElapsed: 0)
        XCTAssertEqual(s.downBytesPerSec, 0)
        XCTAssertEqual(s.upBytesPerSec, 0)
    }

    func testCounterResetClampsToZero() {
        let prev = NetCounters(rxBytes: 5_000, txBytes: 5_000)
        let cur  = NetCounters(rxBytes: 10, txBytes: 10) // counter wrapped/reset
        let s = networkThroughput(previous: prev, current: cur, secondsElapsed: 1)
        XCTAssertEqual(s.downBytesPerSec, 0)
        XCTAssertEqual(s.upBytesPerSec, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NetworkThroughputTests`
Expected: FAIL — `NetCounters` / `networkThroughput` not found.

- [ ] **Step 3: Write the implementation**

```swift
/// Cumulative interface byte counters (since boot).
public struct NetCounters: Equatable {
    public var rxBytes: UInt64
    public var txBytes: UInt64
    public init(rxBytes: UInt64, txBytes: UInt64) {
        self.rxBytes = rxBytes; self.txBytes = txBytes
    }
}

public struct NetworkSample: Equatable {
    public var downBytesPerSec: Double
    public var upBytesPerSec: Double
    public init(downBytesPerSec: Double, upBytesPerSec: Double) {
        self.downBytesPerSec = downBytesPerSec; self.upBytesPerSec = upBytesPerSec
    }
}

/// Throughput between two cumulative counter samples. Clamps to 0 if a counter
/// went backwards (interface reset) or no time elapsed.
public func networkThroughput(previous: NetCounters, current: NetCounters, secondsElapsed: Double) -> NetworkSample {
    guard secondsElapsed > 0 else { return NetworkSample(downBytesPerSec: 0, upBytesPerSec: 0) }
    let down = current.rxBytes >= previous.rxBytes ? Double(current.rxBytes - previous.rxBytes) : 0
    let up   = current.txBytes >= previous.txBytes ? Double(current.txBytes - previous.txBytes) : 0
    return NetworkSample(downBytesPerSec: down / secondsElapsed, upBytesPerSec: up / secondsElapsed)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter NetworkThroughputTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacStatsCore/NetworkThroughput.swift Tests/MacStatsCoreTests/NetworkThroughputTests.swift
git commit -m "feat: add network throughput derivation"
```

---

### Task 6: Battery parsing

**Files:**
- Create: `Sources/MacStatsCore/BatteryParse.swift`
- Test: `Tests/MacStatsCoreTests/BatteryParseTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import IOKit.ps
@testable import MacStatsCore

final class BatteryParseTests: XCTestCase {
    func testParsesPercentAndTime() {
        let dict: [String: Any] = [
            kIOPSCurrentCapacityKey as String: 84,
            kIOPSMaxCapacityKey as String: 100,
            kIOPSIsChargingKey as String: false,
            kIOPSTimeToEmptyKey as String: 134,
        ]
        let s = parseBattery(dict)
        XCTAssertEqual(s?.percent, 84)
        XCTAssertEqual(s?.isCharging, false)
        XCTAssertEqual(s?.timeToEmptyMinutes, 134)
    }

    func testChargingHasNoTimeToEmpty() {
        let dict: [String: Any] = [
            kIOPSCurrentCapacityKey as String: 50,
            kIOPSMaxCapacityKey as String: 100,
            kIOPSIsChargingKey as String: true,
            kIOPSTimeToEmptyKey as String: -1,
        ]
        let s = parseBattery(dict)
        XCTAssertEqual(s?.percent, 50)
        XCTAssertEqual(s?.isCharging, true)
        XCTAssertNil(s?.timeToEmptyMinutes)
    }

    func testMissingCapacityReturnsNil() {
        XCTAssertNil(parseBattery([:]))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BatteryParseTests`
Expected: FAIL — `BatterySample` / `parseBattery` not found.

- [ ] **Step 3: Write the implementation**

```swift
import IOKit.ps

public struct BatterySample: Equatable {
    public var percent: Int
    public var isCharging: Bool
    /// Estimated minutes until empty; nil while charging or when unknown.
    public var timeToEmptyMinutes: Int?

    public init(percent: Int, isCharging: Bool, timeToEmptyMinutes: Int?) {
        self.percent = percent; self.isCharging = isCharging
        self.timeToEmptyMinutes = timeToEmptyMinutes
    }
}

/// Parses one IOPowerSources description dictionary into a BatterySample.
/// Returns nil if the dictionary has no usable capacity (e.g. a desktop with no battery).
public func parseBattery(_ d: [String: Any]) -> BatterySample? {
    guard let current = d[kIOPSCurrentCapacityKey as String] as? Int,
          let maxCap = d[kIOPSMaxCapacityKey as String] as? Int, maxCap > 0 else {
        return nil
    }
    let percent = Int((Double(current) / Double(maxCap) * 100).rounded())
    let charging = (d[kIOPSIsChargingKey as String] as? Bool) ?? false
    let rawTTE = d[kIOPSTimeToEmptyKey as String] as? Int
    let timeToEmpty = (charging || (rawTTE ?? -1) < 0) ? nil : rawTTE
    return BatterySample(percent: percent, isCharging: charging, timeToEmptyMinutes: timeToEmpty)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BatteryParseTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacStatsCore/BatteryParse.swift Tests/MacStatsCoreTests/BatteryParseTests.swift
git commit -m "feat: add battery power-source parsing"
```

---

### Task 7: Refresh scheduler cadence

**Files:**
- Create: `Sources/MacStatsCore/RefreshScheduler.swift`
- Test: `Tests/MacStatsCoreTests/RefreshSchedulerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MacStatsCore

final class RefreshSchedulerTests: XCTestCase {
    func testIdleIsSlow() {
        XCTAssertEqual(refreshInterval(for: .idle), 3.0, accuracy: 0.001)
    }
    func testOpenIsOneSecond() {
        XCTAssertEqual(refreshInterval(for: .popoverOpen), 1.0, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RefreshSchedulerTests`
Expected: FAIL — `Visibility` / `refreshInterval` not found.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Whether the user is currently looking at the popover.
public enum Visibility: Equatable {
    case idle          // popover closed — only menu-bar values matter
    case popoverOpen   // popover open — refresh fast
}

/// The adaptive refresh interval (seconds) for a given visibility.
/// Idle is slow & cheap; open is 1s. (Milestone 3 adds a drilled-in case.)
public func refreshInterval(for visibility: Visibility) -> TimeInterval {
    switch visibility {
    case .idle: return 3.0
    case .popoverOpen: return 1.0
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RefreshSchedulerTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacStatsCore/RefreshScheduler.swift Tests/MacStatsCoreTests/RefreshSchedulerTests.swift
git commit -m "feat: add adaptive refresh interval logic"
```

---

### Task 8: System readers (syscalls) + smoke tests

These call the kernel and can't be unit-tested with fixed inputs, so the tests assert the live values are *plausible* on the real machine (they actually run during `swift test`).

**Files:**
- Create: `Sources/MacStatsCore/SystemReaders.swift`
- Test: `Tests/MacStatsCoreTests/SystemReadersSmokeTests.swift`

- [ ] **Step 1: Write the failing smoke test**

```swift
import XCTest
@testable import MacStatsCore

final class SystemReadersSmokeTests: XCTestCase {
    func testCPUTicksAccumulate() {
        XCTAssertGreaterThan(readCPUTicks().total, 0)
    }

    func testVMHasPageSizeAndTotal() {
        let raw = readVMRaw()
        XCTAssertGreaterThan(raw.pageSize, 0)
        XCTAssertGreaterThan(raw.active + raw.wired, 0)
    }

    func testNetCountersAreMonotonic() {
        let a = readNetCounters()
        let b = readNetCounters()
        XCTAssertGreaterThanOrEqual(b.rxBytes, a.rxBytes)
        XCTAssertGreaterThanOrEqual(b.txBytes, a.txBytes)
    }

    func testBatteryIsNilOrInRange() {
        if let s = readBattery() {
            XCTAssert((0...100).contains(s.percent))
        }
        // nil is acceptable (e.g. a desktop Mac with no battery)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SystemReadersSmokeTests`
Expected: FAIL — `readCPUTicks` / `readVMRaw` / `readNetCounters` / `readBattery` not found.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import Darwin
import IOKit.ps

/// Reads cumulative aggregate CPU ticks via host_statistics(HOST_CPU_LOAD_INFO).
public func readCPUTicks() -> CPUTicks {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return CPUTicks(user: 0, system: 0, idle: 0, nice: 0) }
    // cpu_ticks is a 4-tuple indexed by CPU_STATE_{USER,SYSTEM,IDLE,NICE} = 0,1,2,3
    return CPUTicks(
        user: info.cpu_ticks.0,
        system: info.cpu_ticks.1,
        idle: info.cpu_ticks.2,
        nice: info.cpu_ticks.3
    )
}

/// Reads VM page statistics via host_statistics64(HOST_VM_INFO64).
public func readVMRaw() -> VMRaw {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    var pageSize: vm_size_t = 0
    host_page_size(mach_host_self(), &pageSize)
    guard kr == KERN_SUCCESS else {
        return VMRaw(free: 0, active: 0, inactive: 0, wired: 0, compressed: 0, pageSize: UInt64(pageSize))
    }
    return VMRaw(
        free: UInt64(stats.free_count),
        active: UInt64(stats.active_count),
        inactive: UInt64(stats.inactive_count),
        wired: UInt64(stats.wire_count),
        compressed: UInt64(stats.compressor_page_count),
        pageSize: UInt64(pageSize)
    )
}

/// Sums byte counters across all non-loopback link-layer interfaces via getifaddrs.
public func readNetCounters() -> NetCounters {
    var rx: UInt64 = 0
    var tx: UInt64 = 0
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0 else { return NetCounters(rxBytes: 0, txBytes: 0) }
    defer { freeifaddrs(ifap) }
    var ptr = ifap
    while let cur = ptr {
        if let addr = cur.pointee.ifa_addr, Int32(addr.pointee.sa_family) == AF_LINK {
            let name = String(cString: cur.pointee.ifa_name)
            if !name.hasPrefix("lo"), let raw = cur.pointee.ifa_data {
                let data = raw.assumingMemoryBound(to: if_data.self)
                rx += UInt64(data.pointee.ifi_ibytes)
                tx += UInt64(data.pointee.ifi_obytes)
            }
        }
        ptr = cur.pointee.ifa_next
    }
    return NetCounters(rxBytes: rx, txBytes: tx)
}

/// Reads the first usable power source via IOKit. Returns nil if no battery.
public func readBattery() -> BatterySample? {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
        return nil
    }
    for source in sources {
        if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
           let sample = parseBattery(desc) {
            return sample
        }
    }
    return nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SystemReadersSmokeTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacStatsCore/SystemReaders.swift Tests/MacStatsCoreTests/SystemReadersSmokeTests.swift
git commit -m "feat: add kernel/IOKit system readers with smoke tests"
```

---

### Task 9: MetricsStore (observable state)

**Files:**
- Create: `Sources/MacStatsCore/MetricsStore.swift`
- Test: `Tests/MacStatsCoreTests/MetricsStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MacStatsCore

@MainActor
final class MetricsStoreTests: XCTestCase {
    func testKeepsLatestAndBoundedHistory() {
        let store = MetricsStore(historyCapacity: 2)
        store.update(cpuPercent: 10, memory: nil, network: nil, battery: nil)
        store.update(cpuPercent: 20, memory: nil, network: nil, battery: nil)
        store.update(cpuPercent: 30, memory: nil, network: nil, battery: nil)
        XCTAssertEqual(store.cpuPercent, 30)
        XCTAssertEqual(store.cpuHistory, [20, 30]) // capacity 2
    }

    func testMemoryHistoryTracksUsedFraction() {
        let store = MetricsStore(historyCapacity: 5)
        let mem = MemorySample(usedBytes: 50, totalBytes: 100, pressure: .normal)
        store.update(cpuPercent: 0, memory: mem, network: nil, battery: nil)
        XCTAssertEqual(store.memHistory, [0.5])
        XCTAssertEqual(store.memory?.usedBytes, 50)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MetricsStoreTests`
Expected: FAIL — `MetricsStore` not found.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import Combine

/// The single source of truth the UI binds to. Holds the latest sample of each
/// metric plus a bounded history for sparklines. Main-actor isolated (UI state).
@MainActor
public final class MetricsStore: ObservableObject {
    @Published public private(set) var cpuPercent: Double = 0
    @Published public private(set) var memory: MemorySample?
    @Published public private(set) var network: NetworkSample?
    @Published public private(set) var battery: BatterySample?

    @Published public private(set) var cpuHistory: [Double] = []      // percent 0...100
    @Published public private(set) var memHistory: [Double] = []      // used fraction 0...1
    @Published public private(set) var netDownHistory: [Double] = []  // bytes/sec

    private var cpuBuf: RingBuffer<Double>
    private var memBuf: RingBuffer<Double>
    private var netBuf: RingBuffer<Double>

    public init(historyCapacity: Int = 60) {
        cpuBuf = RingBuffer(capacity: historyCapacity)
        memBuf = RingBuffer(capacity: historyCapacity)
        netBuf = RingBuffer(capacity: historyCapacity)
    }

    public func update(cpuPercent: Double, memory: MemorySample?, network: NetworkSample?, battery: BatterySample?) {
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.network = network
        self.battery = battery

        cpuBuf.append(cpuPercent); cpuHistory = cpuBuf.values
        if let memory { memBuf.append(memory.usedFraction); memHistory = memBuf.values }
        if let network { netBuf.append(network.downBytesPerSec); netDownHistory = netBuf.values }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MetricsStoreTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacStatsCore/MetricsStore.swift Tests/MacStatsCoreTests/MetricsStoreTests.swift
git commit -m "feat: add observable MetricsStore with bounded history"
```

---

### Task 10: Sparkline + StatCard views

UI — verified by building (no unit test). Matches the card/sparkline look in the mockup.

**Files:**
- Create: `Sources/MacStatsApp/Sparkline.swift`
- Create: `Sources/MacStatsApp/StatCard.swift`

- [ ] **Step 1: Create `Sources/MacStatsApp/Sparkline.swift`**

```swift
import SwiftUI
import Charts

/// A compact area+line chart for a metric's recent history.
struct Sparkline: View {
    let values: [Double]
    let color: Color
    let maxValue: Double   // upper bound for the Y scale (0 if dynamic)

    var body: some View {
        let upper = max(maxValue, values.max() ?? 1, 1)
        Chart(Array(values.enumerated()), id: \.offset) { index, value in
            AreaMark(x: .value("i", index), y: .value("v", value))
                .foregroundStyle(
                    LinearGradient(colors: [color.opacity(0.45), color.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                )
            LineMark(x: .value("i", index), y: .value("v", value))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...upper)
        .frame(height: 36)
    }
}
```

- [ ] **Step 2: Create `Sources/MacStatsApp/StatCard.swift`**

```swift
import SwiftUI

/// One row in the overview popover: label + big value + secondary line + sparkline.
struct StatCard: View {
    let label: String
    let value: String
    let meta: String
    let color: Color
    let history: [Double]
    let maxValue: Double

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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/MacStatsApp/Sparkline.swift Sources/MacStatsApp/StatCard.swift
git commit -m "feat: add Sparkline and StatCard views"
```

---

### Task 11: Wire the app — AppModel, MenuBarLabel, OverviewView

**Files:**
- Create: `Sources/MacStatsApp/MenuBarLabel.swift`
- Create: `Sources/MacStatsApp/OverviewView.swift`
- Modify (replace): `Sources/MacStatsApp/MacStatsApp.swift`

- [ ] **Step 1: Create `Sources/MacStatsApp/MenuBarLabel.swift`**

```swift
import SwiftUI
import MacStatsCore

/// The text shown in the menu bar. Milestone 1: CPU %. (Temp arrives in Milestone 2.)
struct MenuBarLabel: View {
    @ObservedObject var store: MetricsStore
    var body: some View {
        Text("\(Int(store.cpuPercent.rounded()))%")
            .monospacedDigit()
    }
}
```

- [ ] **Step 2: Create `Sources/MacStatsApp/OverviewView.swift`**

```swift
import SwiftUI
import MacStatsCore

/// The popover content: header, a card per stat, footer.
struct OverviewView: View {
    @ObservedObject var store: MetricsStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MacStats").font(.headline)
                Spacer()
                Text("every 1s").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 6)

            StatCard(label: "CPU",
                     value: "\(Int(store.cpuPercent.rounded()))%",
                     meta: "live",
                     color: .green,
                     history: store.cpuHistory,
                     maxValue: 100)

            Divider()
            StatCard(label: "Memory",
                     value: memoryValue,
                     meta: memoryMeta,
                     color: .blue,
                     history: store.memHistory,
                     maxValue: 1.0)

            Divider()
            StatCard(label: "Network",
                     value: networkValue,
                     meta: networkMeta,
                     color: .purple,
                     history: store.netDownHistory,
                     maxValue: 0)

            Divider()
            StatCard(label: "Battery",
                     value: batteryValue,
                     meta: batteryMeta,
                     color: .yellow,
                     history: [],
                     maxValue: 1.0)

            Divider()
            HStack {
                Button("Quit") { NSApplication.shared.terminate(nil) }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .frame(width: 320)
    }

    private func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }
    private func rate(_ bps: Double) -> String {
        bps >= 1_048_576 ? String(format: "%.1f MB/s", bps / 1_048_576)
                         : String(format: "%.0f KB/s", bps / 1024)
    }

    private var memoryValue: String {
        guard let m = store.memory else { return "—" }
        return "\(gb(m.usedBytes)) / \(gb(m.totalBytes)) GB"
    }
    private var memoryMeta: String {
        switch store.memory?.pressure {
        case .normal: return "🟢 normal"
        case .warning: return "🟡 warning"
        case .critical: return "🔴 critical"
        case nil: return ""
        }
    }
    private var networkValue: String {
        guard let n = store.network else { return "—" }
        return "↓ \(rate(n.downBytesPerSec))"
    }
    private var networkMeta: String {
        guard let n = store.network else { return "" }
        return "↑ \(rate(n.upBytesPerSec))"
    }
    private var batteryValue: String {
        guard let b = store.battery else { return "—" }
        return "\(b.percent)%"
    }
    private var batteryMeta: String {
        guard let b = store.battery else { return "no battery" }
        if b.isCharging { return "charging" }
        if let t = b.timeToEmptyMinutes { return "\(t / 60)h \(t % 60)m left" }
        return "on battery"
    }
}
```

- [ ] **Step 3: Replace `Sources/MacStatsApp/MacStatsApp.swift` with the full wiring**

```swift
import SwiftUI
import MacStatsCore

/// Owns the store, the syscall pipeline, and the adaptive refresh timer.
@MainActor
final class AppModel: ObservableObject {
    let store = MetricsStore(historyCapacity: 60)

    private var timer: Timer?
    private var visibility: Visibility = .idle
    private var prevCPU = readCPUTicks()
    private var prevNet = readNetCounters()
    private var prevTime = Date()

    init() {
        tick()           // seed an immediate sample
        scheduleTimer()
    }

    func setVisibility(_ newValue: Visibility) {
        guard newValue != visibility else { return }
        visibility = newValue
        scheduleTimer()
        if newValue == .popoverOpen { tick() } // refresh right away on open
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = refreshInterval(for: visibility)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
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
    }
}

@main
struct MacStatsApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            OverviewView(store: model.store)
                .onAppear { model.setVisibility(.popoverOpen) }
                .onDisappear { model.setVisibility(.idle) }
        } label: {
            MenuBarLabel(store: model.store)
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 5: Quick run (bare executable — will show a Dock icon for now, fixed in Task 12)**

Run: `swift run MacStatsApp`
Expected: a menu-bar item showing a CPU `%` appears; clicking it opens the popover with CPU/Memory/Network/Battery cards and a live CPU sparkline that moves each second. Press Ctrl-C in the terminal to stop.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacStatsApp/MenuBarLabel.swift Sources/MacStatsApp/OverviewView.swift Sources/MacStatsApp/MacStatsApp.swift
git commit -m "feat: wire adaptive refresh pipeline into menu-bar UI"
```

---

### Task 12: App bundle (no Dock icon) + run script

**Files:**
- Create: `Resources/Info.plist`
- Create: `Scripts/bundle.sh`

- [ ] **Step 1: Create `Resources/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>MacStats</string>
    <key>CFBundleDisplayName</key>     <string>MacStats</string>
    <key>CFBundleIdentifier</key>      <string>com.macstats.MacStats</string>
    <key>CFBundleExecutable</key>      <string>MacStats</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
```

- [ ] **Step 2: Create `Scripts/bundle.sh`**

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"

swift build -c "$CONFIG"

BIN="$ROOT/.build/$CONFIG/MacStatsApp"
APP="$ROOT/MacStats.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/MacStats"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "Built $APP"
```

- [ ] **Step 3: Make it executable and build the bundle**

```bash
chmod +x Scripts/bundle.sh
./Scripts/bundle.sh
```

Expected: prints `Built /Users/davidghermansteinberg/Desktop/Home/Code/MacStats/MacStats.app`.

- [ ] **Step 4: Launch the bundled app and verify behavior**

```bash
open MacStats.app
```

Expected (manual check, this is the Milestone 1 acceptance test):
- A menu-bar item appears next to the clock showing CPU `%`, and **no Dock icon** appears (because `LSUIElement` is set).
- Clicking it opens the popover with four cards — CPU, Memory, Network, Battery — each with value + meta line.
- The **CPU sparkline animates** roughly once per second while the popover is open; Memory/Network sparklines fill in over time.
- Closing the popover and reopening shows it kept history.
- To quit: open the popover → **Quit**. (Or `pkill MacStats`.)

- [ ] **Step 5: Run the full test suite one more time**

Run: `swift test`
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Resources/Info.plist Scripts/bundle.sh
git commit -m "feat: bundle MacStats.app as a menu-bar agent (no Dock icon)"
```

---

## Milestone 1 Acceptance Criteria

- `swift test` passes (RingBuffer, CPU, Memory, Network, Battery, Scheduler, Store unit tests + reader smoke tests).
- `./Scripts/bundle.sh && open MacStats.app` launches a Dock-iconless menu-bar app.
- Menu-bar item shows live CPU %; popover shows live CPU/Memory/Network/Battery with animating sparklines.
- Idle (popover closed) refreshes every 3s; open refreshes every 1s.

---

## Roadmap — Subsequent Milestones (each gets its own writing-plans run)

**Milestone 2 — Hard sensors (isolated):**
- Add a `CSystemBridge` C target exposing `IOHIDEventSystemClient` thermal sensors; a `SensorReader` that discovers CPU-temp sensor keys at runtime (keys vary by chip) and degrades gracefully (hide temp if none found).
- Battery health (cycle count, max/design capacity) + live watts (Amperage×Voltage) via `AppleSmartBattery` IOKit registry.
- Update `MenuBarLabel` to show `58° 23%`, and the CPU/Battery cards to show temp/health/watts.

**Milestone 3 — Per-app breakdown + drill-in:**
- `ProcessCollector` (per-process CPU via `proc_pid_rusage` deltas; memory via `phys_footprint`); approximate per-app energy from CPU+wakeups.
- Add `.drilledIn(MetricKind)` to `Visibility`; only scan processes when drilled in.
- `DetailView` (back chevron, larger chart, top-process list) + **Quit** (`kill(pid, SIGTERM)`) and **Free Memory** quick actions.

**Milestone 4 — Settings, customizable bar, alerts:**
- SwiftUI `Settings` scene (General / Menu Bar / Alerts), launch-at-login.
- Configurable menu-bar metrics (which 1–3 show, text vs mini-graph).
- `AlertEngine` (thresholds + debounce) → `UNUserNotificationCenter` notifications.
- Replace the memory-pressure heuristic with a real `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` source.

**Deferred to v2+:** per-app network (no clean public API), Disk stats, GPU/fans/raw sensors, multiple menu-bar items, persisted history.
