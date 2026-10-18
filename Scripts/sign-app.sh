#!/bin/bash
# Signs an assembled MacStats.app inside-out: Sparkle's nested helpers, then the framework, then
# the app (no --deep: it would re-sign the helpers without their own options).
#
#   Scripts/sign-app.sh path/to/MacStats.app
#
# Uses the stable "MacStats Code Signing" identity from Scripts/setup-signing.sh; without it,
# falls back to ad-hoc with a warning, or fails when MACSTATS_REQUIRE_IDENTITY=1 (releases).
# Sparkle's helpers keep the hardened runtime they ship with (they load only system libraries);
# the app itself stays without it, as before: it is not sandboxed or notarized, and the
# runtime's library validation would refuse a Sparkle.framework signed by a self-signed cert.
set -euo pipefail
APP="$1"

IDENTITY="MacStats Code Signing"
KEYCHAIN="$HOME/Library/Keychains/macstats-signing.keychain-db"
# Public on purpose (also in setup-signing.sh): this keychain holds only the local self-signed
# signing certificate, which nobody trusts; it just keeps the signature stable so macOS keeps
# the Finder permission across updates. Update trust rests on Sparkle's EdDSA key (login
# Keychain), not on this. Knowing it gives nothing beyond what local access already gives.
KEYCHAIN_PW="macstats-local"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
    SIGN=(--keychain "$KEYCHAIN" --sign "$IDENTITY")
    WHO="'$IDENTITY'"
elif [ "${MACSTATS_REQUIRE_IDENTITY:-0}" = 1 ]; then
    echo "error: signing identity '$IDENTITY' not found; run Scripts/setup-signing.sh" >&2
    exit 1
else
    echo "warning: '$IDENTITY' not found (Scripts/setup-signing.sh); signing ad-hoc" >&2
    SIGN=(--sign -)
    WHO="ad-hoc"
fi

FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
    V="$FW/Versions/B"
    # (bundle.sh removed the XPC services: only sandboxed apps use them.)
    codesign --force "${SIGN[@]}" -o runtime "$V/Autoupdate"
    codesign --force "${SIGN[@]}" -o runtime "$V/Updater.app"
    codesign --force "${SIGN[@]}" -o runtime "$FW"
fi

# Seals Info.plist + Resources too. The linker only signs the bare executable, leaving
# "Info.plist=not bound" otherwise — which makes TCC ignore NSAppleEventsUsageDescription and
# silently deny the Apple events to Finder that power the Trash card.
codesign --force "${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Signed $APP ($WHO)"
