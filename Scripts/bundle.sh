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
