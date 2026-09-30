#!/bin/bash
# Installs or updates MacStats (macOS 14+, Apple Silicon):
#
#   curl -fsSL https://raw.githubusercontent.com/david53001/macos-stats/main/install.sh | bash
#
# Downloads the newest release, puts MacStats.app in ~/Applications (replacing an older
# copy; no admin password needed), clears the quarantine flag (the app is not notarized,
# so Gatekeeper would otherwise refuse to open it) and launches it. Run it again to update.
# Settings and the battery-usage history live in the app's preferences, so they carry over.
set -euo pipefail

REPO="david53001/macos-stats"
ASSET="MacStats.app.zip"
DEST="$HOME/Applications/MacStats.app"

if [ "$(uname -s)" != "Darwin" ]; then echo "MacStats is a macOS app." >&2; exit 1; fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 14 ]; then
    echo "MacStats needs macOS 14 (Sonoma) or newer; you have $(sw_vers -productVersion)." >&2; exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then echo "MacStats needs an Apple Silicon Mac." >&2; exit 1; fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading the newest MacStats..."
curl -fsSL -o "$TMP/$ASSET" "https://github.com/$REPO/releases/latest/download/$ASSET"
ditto -x -k "$TMP/$ASSET" "$TMP"
[ -d "$TMP/MacStats.app" ] || { echo "error: the download did not contain MacStats.app" >&2; exit 1; }
codesign --verify --deep --strict "$TMP/MacStats.app" 2>/dev/null \
    || { echo "error: the downloaded app failed signature verification" >&2; exit 1; }

if pgrep -xq MacStats; then
    echo "==> Quitting the running copy..."
    pkill -x MacStats || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq MacStats || break; sleep 0.5; done
fi

echo "==> Installing to $DEST..."
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$TMP/MacStats.app" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

open "$DEST"
VERSION="$(defaults read "$DEST/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")"
echo "Done. MacStats $VERSION is running; click the graph icon in your menu bar."
