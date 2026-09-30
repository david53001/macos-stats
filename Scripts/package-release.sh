#!/bin/bash
# Builds the release app into dist/ and zips it as the GitHub release asset that
# install.sh downloads. Publish with:
#   gh release create vX.Y.Z dist/MacStats.app.zip --title "MacStats X.Y.Z" --notes "..."
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"

rm -rf "$DIST"
mkdir -p "$DIST"
MACSTATS_APP="$DIST/MacStats.app" "$ROOT/Scripts/bundle.sh" release
ditto -c -k --keepParent "$DIST/MacStats.app" "$DIST/MacStats.app.zip"
echo "Packaged $DIST/MacStats.app.zip"
