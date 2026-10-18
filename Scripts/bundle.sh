#!/bin/bash
# Builds MacStats and assembles + signs MacStats.app.
#   Scripts/bundle.sh [debug|release]
# MACSTATS_APP           destination (default ~/Applications/MacStats.app; package-release.sh
#                        builds into dist/). Only the default destination quits a running copy.
# MACSTATS_SWIFT_FLAGS   extra `swift build` arguments (the Sparkle end-to-end test uses this).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
source "$ROOT/Scripts/sdk-env.sh"

# shellcheck disable=SC2086
swift build -c "$CONFIG" ${MACSTATS_SWIFT_FLAGS:-}
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c "$CONFIG" ${MACSTATS_SWIFT_FLAGS:-} --show-bin-path)"
BIN="$BIN_DIR/MacStatsApp"
# Install straight into ~/Applications — the single canonical copy. Assembling in the
# repo root left a second MacStats.app that drifted out of date with the installed one.
APP="${MACSTATS_APP:-$HOME/Applications/MacStats.app}"

# Quit any running copy so a relaunch picks up the new build instead of the old process.
[ -z "${MACSTATS_APP:-}" ] && { pkill -x MacStats 2>/dev/null || true; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/MacStats"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Sparkle (auto-updates): the executable finds it through its @executable_path/../Frameworks
# rpath (Package.swift). ditto keeps the framework's symlinks. Its XPC services are only for
# sandboxed apps (MacStats isn't; Sparkle's docs say they may be removed then), so they go.
FW="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$BIN_DIR/Sparkle.framework" "$FW"
rm -rf "$FW/XPCServices" "$FW/Versions/B/XPCServices"

# SwiftPM also bakes in rpaths to folders on this Mac: its build folder (…/PackageFrameworks,
# searched first) and the Command Line Tools' Swift folders. Sparkle is the only @rpath library
# (the Swift runtime is in /usr/lib/swift since macOS 12), so drop every absolute rpath except
# /usr/lib/swift: the app can only load the embedded Sparkle and carries no path from this Mac.
EXE="$APP/Contents/MacOS/MacStats"
if otool -L "$EXE" | awk 'NR > 1 { print $1 }' | grep '^@rpath/' | grep -qv '^@rpath/Sparkle.framework/'; then
    echo "error: a new @rpath library needs one of the rpaths removed below:" >&2
    otool -L "$EXE" | grep '@rpath/' >&2
    exit 1
fi
otool -l "$EXE" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' |
while read -r RPATH; do
    case "$RPATH" in
        /usr/lib/swift) ;;
        /*) install_name_tool -delete_rpath "$RPATH" "$EXE" ;;
    esac
done

"$ROOT/Scripts/sign-app.sh" "$APP"
echo "Built $APP"
