#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"

swift build -c "$CONFIG"

BIN="$ROOT/.build/$CONFIG/MacStatsApp"
# Install straight into ~/Applications — the single canonical copy. Assembling in the
# repo root left a second MacStats.app that drifted out of date with the installed one.
APP="$HOME/Applications/MacStats.app"

# Quit any running copy so a relaunch picks up the new build instead of the old process.
pkill -x MacStats 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacStats"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc re-sign the assembled bundle so the signature seals Info.plist + Resources.
# The linker only ad-hoc signs the bare executable, leaving "Info.plist=not bound" once
# we add it here — which makes TCC ignore NSAppleEventsUsageDescription and silently deny
# the Apple events to Finder that power the Trash size readout and Empty Trash.
codesign --force --sign - "$APP"

echo "Built $APP"
