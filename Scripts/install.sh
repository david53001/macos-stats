#!/bin/bash
# Build, bundle, and install MacStats into ~/Applications so Spotlight indexes it.
# After this, typing "MacStats" in Spotlight finds the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Build + assemble MacStats.app (release).
"$ROOT/Scripts/bundle.sh" release

DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/MacStats.app"
cp -R "$ROOT/MacStats.app" "$DEST/MacStats.app"

# Register with Launch Services + Spotlight now, rather than waiting for the next scan.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$DEST/MacStats.app" || true
mdimport "$DEST/MacStats.app" || true

echo "Installed $DEST/MacStats.app — type \"MacStats\" in Spotlight to launch."
