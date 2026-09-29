#!/bin/bash
# Build and install MacStats (release) into ~/Applications so Spotlight indexes it.
# After this, typing "MacStats" in Spotlight finds the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# bundle.sh assembles straight into ~/Applications/MacStats.app — the single canonical copy.
"$ROOT/Scripts/bundle.sh" release

APP="$HOME/Applications/MacStats.app"

# Register with Launch Services + Spotlight now, rather than waiting for the next scan.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" || true
mdimport "$APP" || true

echo "Installed $APP — type \"MacStats\" in Spotlight to launch."
