#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"

swift build -c "$CONFIG"

BIN="$ROOT/.build/$CONFIG/MacStatsApp"
APP="$ROOT/MacStats.app"

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
