#!/bin/bash
# One-time, non-interactive setup of a STABLE self-signed code-signing identity for MacStats
# ("MacStats Code Signing"), the same approach as JVoice and BetterScreenshot.
#
# Why: an ad-hoc signature is identified by the code hash, which changes on every build, so
# macOS forgets permissions tied to it (the Finder "Automation" permission behind the Trash
# card) after every update. A stable certificate gives every build the same "designated
# requirement", so a permission granted once survives updates, including Sparkle auto-updates.
# (Sparkle itself trusts updates by their EdDSA signature, so it works with either.)
#
# The identity lives in a dedicated keychain (not the login keychain) whose password is in this
# script, so `codesign` can be pre-authorized and never shows a prompt. That keychain holds
# nothing but this local, self-signed certificate (trusted by nobody; it only keeps the
# signature stable). Idempotent: creates the identity only once, so it never changes.
set -euo pipefail

IDENTITY="MacStats Code Signing"
KEYCHAIN="$HOME/Library/Keychains/macstats-signing.keychain-db"
KEYCHAIN_PW="macstats-local"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    echo "Signing identity '$IDENTITY' already exists - nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "Generating self-signed code-signing certificate..."
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
    -subj "/CN=$IDENTITY" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout pass:"$KEYCHAIN_PW" -name "$IDENTITY" 2>/dev/null

if [ ! -f "$KEYCHAIN" ]; then
    security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
fi
security set-keychain-settings "$KEYCHAIN"                 # no auto-lock timeout
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PW" -T /usr/bin/codesign -A
# Pre-authorize codesign so signing never shows a keychain prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PW" "$KEYCHAIN" >/dev/null

# Put the keychain on the user search list (so codesign finds it), keeping the existing ones.
if ! security list-keychains -d user | grep -q "$KEYCHAIN"; then
    EXISTING="$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')"
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$KEYCHAIN" $EXISTING
fi

echo "Created stable signing identity '$IDENTITY'."
echo "Back up $KEYCHAIN (password: $KEYCHAIN_PW) to build releases on another Mac with the same identity."
