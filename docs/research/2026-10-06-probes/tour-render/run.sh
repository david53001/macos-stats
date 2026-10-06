#!/bin/bash
# Off-screen tour render probe (see README.md). Usage, from anywhere:
#   docs/research/2026-10-06-probes/tour-render/run.sh            # captures + out/insets.txt
#   docs/research/2026-10-06-probes/tour-render/run.sh --cost     # 20 s tour off, 20 s on step 1: CPU
#   docs/research/2026-10-06-probes/tour-render/run.sh --no-tour  # 20 s with the tour host compiled out of the view
# Copies the CURRENT Sources/{MacStatsCore,CAppleSensors} and Sources/MacStatsApp/*.swift (minus the
# @main, MacStatsMain.swift) into $TMPDIR/macstats-tour-probe, builds there, and runs under a kill
# timeout. Windows sit at desktop level + 1, ordered back, never activated, closed after capture.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
B="${TMPDIR:-/tmp}/macstats-tour-probe"
rm -rf "$B/Sources"
OUT="${OUT:-$HERE/out}"   # where captures go (OUT=<dir> to keep another round's captures)
mkdir -p "$B/Sources/Probe" "$OUT"
cp "$HERE/Package.swift" "$B/"
cp -R "$REPO/Sources/MacStatsCore" "$REPO/Sources/CAppleSensors" "$B/Sources/"
for f in "$REPO"/Sources/MacStatsApp/*.swift; do
  [[ "$(basename "$f")" == MacStatsMain.swift ]] || cp "$f" "$B/Sources/Probe/"
done
cp "$HERE/main.swift" "$B/Sources/Probe/"
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
(cd "$B" && swift build -c release 2>&1 | grep -E "error|warning: unre|Compiling Probe|Build" || true)
cd "$REPO"
"$B/.build/release/Probe" "$OUT" "$@" &
PID=$!
( sleep 150; kill "$PID" ) 2>/dev/null &
WATCH=$!
wait "$PID" || true
pkill -P "$WATCH" 2>/dev/null || true
kill "$WATCH" 2>/dev/null || true
# The probe's own throwaway defaults suites (it lists them): cfprefsd may rewrite them at exit.
LIST="${TMPDIR:-/tmp}/macstats-tour-probe-suites.txt"
if [[ -f "$LIST" ]]; then
  sleep 1
  while read -r name; do
    [[ "$name" == MacStatsTourProbe-* ]] && rm -f "$HOME/Library/Preferences/$name.plist"
  done < "$LIST"
  rm -f "$LIST"
fi
