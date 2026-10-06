#!/bin/bash
# Headless stability probe (see README.md). Usage, from anywhere:
#   docs/research/2026-10-06-probes/stability/run.sh [seconds=90] [app=Code]
# Env: SRC_ROOT=<a MacStats checkout to measure> (default: this repo);
#      BASELINE=1 when that checkout predates the stability work (e.g. 1ed61cf).
# Compiles the checkout's Sources/MacStatsCore with main.swift into $TMPDIR (never the repo),
# then runs it under a kill timeout. No window, no UI.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
SRC="${SRC_ROOT:-$REPO}"
SECS="${1:-90}"
APP="${2:-Code}"
OUT="${TMPDIR:-/tmp}/macstats-stability-probe"
mkdir -p "$OUT"
FLAGS=()
if [[ "${BASELINE:-0}" == 1 ]]; then FLAGS=(-D BASELINE); fi
if grep -q breakdownFirstRescanDelay "$SRC/Sources/MacStatsCore/RefreshScheduler.swift"; then FLAGS+=(-D FIRST_RESCAN); fi
# shellcheck disable=SC2046
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -O ${FLAGS[@]+"${FLAGS[@]}"} \
  -o "$OUT/probe" $(ls "$SRC"/Sources/MacStatsCore/*.swift | grep -v AppleSensorReader) "$HERE/main.swift"
cd "$REPO"
"$OUT/probe" "$SECS" "$APP" &
PID=$!
( sleep $((SECS + 40)); kill "$PID" ) 2>/dev/null &
WATCH=$!
wait "$PID" || true
pkill -P "$WATCH" 2>/dev/null || true
kill "$WATCH" 2>/dev/null || true
