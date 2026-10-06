#!/bin/bash
# Review round 2 fixes: headless stability probe (see README.md). Usage, from anywhere:
#   docs/research/2026-10-06-probes/r2-fixes/run.sh [seconds=150]
# Env: SRC_ROOT=<a MacStats checkout or source snapshot to measure> (default: this repo);
#      R2BASE=1 when that checkout predates the round-2 fixes (66141b1).
# Compiles the checkout's Sources/MacStatsCore with main.swift into $TMPDIR (never the repo),
# then runs it under a kill timeout. No window, no UI.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
SRC="${SRC_ROOT:-$REPO}"
SECS="${1:-150}"
OUT="${TMPDIR:-/tmp}/macstats-r2-probe"
mkdir -p "$OUT"
FLAGS=()
if [[ "${R2BASE:-0}" == 1 ]]; then FLAGS=(-D R2BASE); fi
# shellcheck disable=SC2046
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -O ${FLAGS[@]+"${FLAGS[@]}"} \
  -o "$OUT/probe" $(ls "$SRC"/Sources/MacStatsCore/*.swift | grep -v AppleSensorReader) "$HERE/main.swift"
cd "$REPO"
"$OUT/probe" "$SECS" &
PID=$!
( sleep $((SECS + 40)); kill "$PID" ) 2>/dev/null &
WATCH=$!
wait "$PID" || true
pkill -P "$WATCH" 2>/dev/null || true
kill "$WATCH" 2>/dev/null || true
