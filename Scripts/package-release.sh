#!/bin/bash
# Builds, signs and packages a MacStats release, ready to publish (docs/sparkle-updates/README.md):
#
#   Scripts/package-release.sh [release-notes.md]
#
# 1. release build → dist/MacStats.app, signed inside-out with "MacStats Code Signing"
#    (required; Scripts/setup-signing.sh creates it)
# 2. dist/MacStats.app.zip (ditto, keeps the signature + framework symlinks) — the asset both
#    install.sh and Sparkle download
# 3. EdDSA-signs the zip with the Sparkle key from the login Keychain (sign_update)
# 4. dist/appcast.xml — the Sparkle feed for this one release; its URL in every installed app is
#    releases/LATEST/download/appcast.xml, so publishing this release as "latest" is what ships it
# 5. prints the exact `gh release create` command (this script publishes nothing)
#
# The optional notes file (Markdown) becomes both the GitHub release notes and the text Sparkle
# shows in its update window; without one, a short default pointing to the release page is used.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
REPO="david53001/macos-stats"
SPARKLE_BIN="${SPARKLE_BIN:-$HOME/Developer/Sparkle/2.10.0/bin}"
NOTES_FILE="${1:-}"

PLIST="$ROOT/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
TAG="v$VERSION"

[ -x "$SPARKLE_BIN/sign_update" ] || { echo "error: Sparkle tools not found in $SPARKLE_BIN" >&2; exit 1; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "error: CFBundleVersion must be a whole number (got '$BUILD')" >&2; exit 1; }
[ -z "$NOTES_FILE" ] || [ -f "$NOTES_FILE" ] || { echo "error: notes file '$NOTES_FILE' not found" >&2; exit 1; }

# Sparkle only offers an update whose CFBundleVersion is higher than the installed one, so
# refuse a build number that isn't above the currently published feed's (best effort: skipped
# when offline or before the first Sparkle release).
LIVE_BUILD="$(curl -fsSL --max-time 10 "https://github.com/$REPO/releases/latest/download/appcast.xml" 2>/dev/null |
    sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' | head -1 || true)"
if [ -n "$LIVE_BUILD" ] && [ "$BUILD" -le "$LIVE_BUILD" ]; then
    echo "error: CFBundleVersion $BUILD is not above the published build $LIVE_BUILD; bump it in $PLIST" >&2
    exit 1
fi

rm -rf "$DIST"
mkdir -p "$DIST"
MACSTATS_APP="$DIST/MacStats.app" MACSTATS_REQUIRE_IDENTITY=1 "$ROOT/Scripts/bundle.sh" release
ZIP="$DIST/MacStats.app.zip"
ditto -c -k --keepParent "$DIST/MacStats.app" "$ZIP"

# EdDSA signature + length for the appcast enclosure (key read from the Keychain, never printed).
SIGNATURE_ATTRS="$("$SPARKLE_BIN/sign_update" "$ZIP")"
"$SPARKLE_BIN/sign_update" --verify "$ZIP" "$(sed -n 's/.*edSignature="\([^"]*\)".*/\1/p' <<<"$SIGNATURE_ATTRS")" >/dev/null

NOTES_OUT="$DIST/release-notes.md"
if [ -n "$NOTES_FILE" ]; then
    cp "$NOTES_FILE" "$NOTES_OUT"
else
    printf 'MacStats %s. Details: https://github.com/%s/releases/tag/%s\n' "$VERSION" "$REPO" "$TAG" > "$NOTES_OUT"
fi

cat > "$DIST/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MacStats</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>MacStats $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[
$(cat "$NOTES_OUT")
]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/MacStats.app.zip"
                 type="application/octet-stream" $SIGNATURE_ATTRS />
    </item>
  </channel>
</rss>
XML
xmllint --noout "$DIST/appcast.xml"

echo
echo "==> verify"
codesign --verify --deep --strict "$DIST/MacStats.app" && echo "code signature OK"
codesign -dvv "$DIST/MacStats.app" 2>&1 | grep -E '^(Identifier|Authority|Signature)=' || true
echo "MacStats $VERSION (build $BUILD): $ZIP, $DIST/appcast.xml"
echo
echo "==> To publish (after merging to main and pushing), run exactly:"
echo "gh release create $TAG \"$ZIP\" \"$DIST/appcast.xml\" --repo $REPO --latest --title \"MacStats $VERSION\" --notes-file \"$NOTES_OUT\""
