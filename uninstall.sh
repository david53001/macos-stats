#!/bin/bash
# One-line uninstaller for MacStats (macOS):
#
#   curl -fsSL https://raw.githubusercontent.com/david53001/macos-stats/main/uninstall.sh | bash
#
# Quits MacStats and removes everything it put on this Mac: the app, its settings (the
# battery-usage history lives there too) and its caches. Reinstall any time with install.sh.
set -euo pipefail

APP_NAME="MacStats"
BUNDLE_ID="com.macstats.MacStats"
APP="$HOME/Applications/MacStats.app"

if [ "$(uname -s)" != "Darwin" ]; then echo "This uninstaller is for macOS." >&2; exit 1; fi

if pgrep -xq "$APP_NAME"; then
    echo "==> Quitting $APP_NAME..."
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do pgrep -xq "$APP_NAME" || break; sleep 0.5; done
    pkill -x "$APP_NAME" 2>/dev/null || true
fi

echo "==> Removing $APP..."
rm -rf "$APP"

echo "==> Removing settings and caches..."
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
rm -rf "$HOME/Library/Preferences/$BUNDLE_ID.plist" \
       "$HOME/Library/Caches/$BUNDLE_ID" \
       "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
       "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"

echo "==> Resetting permissions..."
tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "Done. $APP_NAME is uninstalled."
