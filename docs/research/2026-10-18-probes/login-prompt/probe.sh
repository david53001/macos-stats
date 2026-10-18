#!/bin/bash
# Live probe of the "Open MacStats at login?" card (README.md next to this file).
#
#   probe.sh <src-worktree> <out-dir> <scenarios.swift> [seed-script]
#   PROBE_SCENARIO=basic|welcome probe.sh …        (default basic)
#
# Copies the worktree to <out-dir>/work (no .git/docs/.build), adds Probe.swift + the scenarios,
# gives the copy its own bundle id (com.macstats.MacStats.probe), a dead feed and no update checks,
# stubs Finder (no Automation prompt) and the login-item service (LaunchAtLogin never calls
# SMAppService: Return on the card is safe), builds it with -DPROBE -DSPARKLE_E2E_TEST (no
# notification prompt), runs the scenario in light then dark appearance, prints the logs, and
# deletes the copy, its defaults, caches and Launch Services entry. Never touches the real app.
set -euo pipefail
SRC="$1"; OUT="$2"; SCEN="$3"; SEED="${4:-}"
T="$(cd "$(dirname "$0")" && pwd)"
ID=com.macstats.MacStats.probe
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd -P)"
W="$OUT/work"; mkdir -p "$W"
PID=""
cleanup_defaults() { defaults delete $ID >/dev/null 2>&1 || true; rm -f "$HOME/Library/Preferences/$ID.plist"; }
cleanup() {
    set +e
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    pkill -f "$W/app/MacStats.app/" 2>/dev/null
    cleanup_defaults
    rm -rf "$HOME/Library/Caches/$ID" "$HOME/Library/HTTPStorages/$ID" "$HOME/Library/Saved Application State/$ID.savedState"
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -u "$W/app/MacStats.app" 2>/dev/null
    rm -rf "$W"
}
trap cleanup EXIT

rsync -a --delete --exclude .build --exclude .git --exclude docs --exclude dist "$SRC/" "$W/src/"
cd "$W/src"
cp "$T/Probe.swift" Sources/MacStatsApp/Probe.swift
cp "$SCEN" Sources/MacStatsApp/ProbeScenarios.swift
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Set :SUFeedURL http://127.0.0.1:9/appcast.xml" \
    -c "Set :SUEnableAutomaticChecks false" Resources/Info.plist
python3 - <<'PY'
import sys
def patch(path, pairs):
    s = open(path).read()
    for old, new in pairs:
        if old not in s:
            sys.exit(f"probe.sh: can't patch {path}: {old[:50]!r} not found")
        s = s.replace(old, new, 1)
    open(path, 'w').write(s)
    return s

# Finder stubbed: no Automation prompt for the probe id.
p = 'Sources/MacStatsApp/TrashActions.swift'
s = open(p).read()
for sig, ret in [('static func trashSize() -> UInt64? {', 'return 0'),
                 ('static func trashSize() -> TrashReading {', 'return .bytes(0)')]:
    if sig in s:
        s = s.replace(sig, sig + f'\n        #if PROBE\n        {ret}\n        #endif', 1)
        break
else:
    sys.exit("probe.sh: Finder stub failed")
open(p, 'w').write(s)

patch('Sources/MacStatsApp/MacStatsMain.swift', [
    ('_model = StateObject(wrappedValue: model)',
     '_model = StateObject(wrappedValue: model)\n        #if PROBE\n        Probe.start(model: model)\n        #endif'),
])

# The login-item service stubbed: the probe's Return on the card must never register a real
# login item. Every SMAppService.mainApp call is replaced; the check below proves none is left.
s = patch('Sources/MacStatsApp/LoginItem.swift', [
    ('@Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status',
     '@Published private(set) var status: SMAppService.Status = LaunchAtLogin.probeStatus\n'
     '    /// PROBE stub (probe.sh): stands in for the system login-item record.\n'
     '    static var probeStatus: SMAppService.Status = .notRegistered'),
    ('let current = SMAppService.mainApp.status', 'let current = Self.probeStatus'),
    ('''            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }''', '''            Self.probeStatus = enabled ? Probe.loginResult : .notRegistered
            if Self.probeStatus == .notFound { throw NSError(domain: "probe", code: 1) }'''),
    ('SMAppService.openSystemSettingsLoginItems()', 'Probe.note("stub: openSystemSettingsLoginItems")'),
])
code = [l for l in s.splitlines() if not l.lstrip().startswith('//')]
if any('SMAppService.mainApp' in l or 'openSystemSettingsLoginItems()' in l for l in code):
    sys.exit("probe.sh: a real SMAppService call is left in LoginItem.swift")
PY
if grep -rn "SMAppService\.mainApp\|openSystemSettingsLoginItems()" Sources/MacStatsApp | grep -v ':[0-9]*: *//'; then
    echo "probe.sh: a real login-item call is left (above); refusing to build" >&2; exit 1
fi
MACSTATS_APP="$W/app/MacStats.app" MACSTATS_SWIFT_FLAGS="--scratch-path $W/build -Xswiftc -DPROBE -Xswiftc -DSPARKLE_E2E_TEST" \
    ./Scripts/bundle.sh release > "$W/build.log" 2>&1 || { tail -40 "$W/build.log"; exit 1; }
for AP in light dark; do
    cleanup_defaults
    defaults write $ID launchAtLoginPromptUses -int 4
    [ -n "$SEED" ] && bash "$SEED" $ID
    PROBE_OUT="$OUT" PROBE_APPEARANCE=$AP PROBE_SCENARIO="${PROBE_SCENARIO:-basic}" "$W/app/MacStats.app/Contents/MacOS/MacStats" > "$OUT/stderr-$AP.log" 2>&1 &
    PID=$!
    for _ in $(seq 1 360); do kill -0 $PID 2>/dev/null || break; sleep 0.5; done
    kill $PID 2>/dev/null || true
    PID=""
    echo "== $AP"; cat "$OUT/probe-$AP.log" || true
done
