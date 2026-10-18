#!/bin/bash
# Review round 3 fixes: reviewer B's round-3 probe against a checkout (see README.md). Usage:
#   docs/research/2026-10-06-probes/r3-fixes/run.sh stability 100   # headless, real scans
#   docs/research/2026-10-06-probes/r3-fixes/run.sh synthetic       # frozen expanded app gains a process
# Env: SRC_ROOT=<checkout or source snapshot> (default: this repo). Builds in $TMPDIR, never in the repo.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
SRC="${SRC_ROOT:-$REPO}"
B="${TMPDIR:-/tmp}/macstats-r3-probe"
rm -rf "$B/Sources"
mkdir -p "$B/Sources/Probe"
cp "$HERE/Package.swift" "$B/"
cp -R "$SRC/Sources/MacStatsCore" "$SRC/Sources/CAppleSensors" "$B/Sources/"
for f in "$SRC"/Sources/MacStatsApp/*.swift; do
  [[ "$(basename "$f")" == MacStatsMain.swift ]] || cp "$f" "$B/Sources/Probe/"
done
cp "$HERE/main.swift" "$B/Sources/Probe/"
FLAG=()
if grep -q breakdownFirstRescanDelay "$SRC/Sources/MacStatsCore/RefreshScheduler.swift"; then
  FLAG=(-Xswiftc -DFIRST_RESCAN)
fi
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
(cd "$B" && swift build -c release ${FLAG[@]+"${FLAG[@]}"} 2>&1 | grep -E "error|Build" || true)
cd "$B"
"$B/.build/release/Probe" "$@" &
PID=$!
( sleep 300; kill "$PID" ) 2>/dev/null &
WATCH=$!
wait "$PID" || true
pkill -P "$WATCH" 2>/dev/null || true
kill "$WATCH" 2>/dev/null || true
