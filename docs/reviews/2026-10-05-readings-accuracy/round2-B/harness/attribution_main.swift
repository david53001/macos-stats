import AppKit
import Darwin
// Attribution dump: replicates procScanTick's anchors + ProcessAttributor.
let raw = readRawProcesses()
let infos = NSWorkspace.shared.runningApplications.map { app in
    RunningAppInfo(pid: Int32(app.processIdentifier), hasBundleIdentifier: app.bundleIdentifier != nil,
                   isBackgroundOnly: app.activationPolicy == .prohibited) }
let anchors = attributionAnchors(infos)
let owners = ProcessAttributor().owners(for: raw, appPIDs: anchors.apps, fallbackAppPIDs: anchors.fallbacks)
func appName(_ p: Int32) -> String {
    p == BreakdownGroup.otherProcesses ? "Other processes" : (NSRunningApplication(processIdentifier: p)?.localizedName ?? "PID \(p)")
}
print("real anchors: \(anchors.apps.count), fallbacks: \(anchors.fallbacks.count)")
for f in anchors.fallbacks.sorted() { print("  fallback anchor \(f) \(appName(f)) bundle=\(NSRunningApplication(processIdentifier: f)?.bundleIdentifier ?? "nil")") }
for p in raw.sorted(by: { (owners[$0.pid]!, $0.pid) < (owners[$1.pid]!, $1.pid) }) {
    let o = owners[p.pid]!
    let r = responsiblePID(for: p.pid) ?? -9
    print(String(format: "%6d ppid=%6d resp=%6d  %-40@ -> %@", p.pid, p.ppid, r, (processName(p.pid) ?? "?") as NSString, "\(appName(o)) [\(o)]"))
}
