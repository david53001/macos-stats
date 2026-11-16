#!/bin/bash
# Off-screen CPU probe for the open panel (README.md). Usage, from anywhere:
#   docs/research/2026-11-16-probes/open-cost/run.sh [<git-ref>] [<overview-interval> <breakdown-interval>]
# Builds the app's views from <git-ref> (default: the working tree) in $TMPDIR, renders the real
# OverviewView and BreakdownView in windows at desktop level + 1, ordered back, never activated,
# feeds the store at the given cadences and prints the probe process's CPU (% of one core).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
REF="${1:-}"
OV="${2:-1.0}"; BD="${3:-2.0}"
B="${TMPDIR:-/tmp}/macstats-open-cost-probe"
SRC="$B/src"
rm -rf "$B/Sources" "$SRC"
mkdir -p "$B/Sources/Probe" "$SRC"
if [[ -n "$REF" ]]; then
  git -C "$REPO" archive "$REF" Sources | tar -x -C "$SRC"
else
  cp -R "$REPO/Sources" "$SRC/"
fi
cp "$HERE/Package.swift" "$B/"
cp -R "$SRC/Sources/MacStatsCore" "$SRC/Sources/CAppleSensors" "$B/Sources/"
for f in "$SRC"/Sources/MacStatsApp/*.swift; do
  [[ "$(basename "$f")" == MacStatsMain.swift ]] || cp "$f" "$B/Sources/Probe/"
done
cp "$HERE/main.swift" "$B/Sources/Probe/"
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
(cd "$B" && swift build -c release 2>&1 | grep -E "error|Build" || true)
"$B/.build/release/Probe" "$OV" "$BD" &
PID=$!
( sleep 240; kill "$PID" ) 2>/dev/null &
WATCH=$!
wait "$PID" || true
pkill -P "$WATCH" 2>/dev/null || true
kill "$WATCH" 2>/dev/null || true
