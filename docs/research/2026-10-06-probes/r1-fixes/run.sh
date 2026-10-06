#!/bin/bash
# Off-screen checks of the review-round-1 fixes (see README.md). Usage, from anywhere:
#   docs/research/2026-10-06-probes/r1-fixes/run.sh
# Copies the CURRENT Sources/{MacStatsCore,CAppleSensors} and Sources/MacStatsApp/*.swift (minus the
# @main) into $TMPDIR/macstats-r1-probe, builds there, runs under a kill timeout. Windows sit at desktop
# level + 1, ordered back, never activated, closed right after.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
B="${TMPDIR:-/tmp}/macstats-r1-probe"
rm -rf "$B/Sources"
mkdir -p "$B/Sources/Probe" "$HERE/out"
cp "$REPO/docs/research/2026-10-06-probes/tour-render/Package.swift" "$B/"
cp -R "$REPO/Sources/MacStatsCore" "$REPO/Sources/CAppleSensors" "$B/Sources/"
for f in "$REPO"/Sources/MacStatsApp/*.swift; do
  [[ "$(basename "$f")" == MacStatsMain.swift ]] || cp "$f" "$B/Sources/Probe/"
done
cp "$HERE/main.swift" "$B/Sources/Probe/"
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
(cd "$B" && swift build -c release 2>&1 | grep -E "error|Build" || true)
cd "$REPO"
"$B/.build/release/Probe" "$HERE/out" &
PID=$!
( sleep 120; kill "$PID" ) 2>/dev/null &
WATCH=$!
wait "$PID" || true
pkill -P "$WATCH" 2>/dev/null || true
kill "$WATCH" 2>/dev/null || true
