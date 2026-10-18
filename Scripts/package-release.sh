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
# 5. prints the exact `gh release create` command, tagged on this HEAD (it publishes nothing)
#
# Order: bump Info.plist → Scripts/test.sh → commit → git push origin main → this script → the
# printed gh command (the checks below need the bump committed and pushed first).
#
# The optional notes file (Markdown) becomes both the GitHub release notes and the text Sparkle
# shows in its update window; without one, a short default pointing to the release page is used.
#
# Refuses to package (each check has an override, for dry runs only):
#   - uncommitted changes                                   ALLOW_DIRTY=1
#   - HEAD isn't origin/main (what the release will be tagged from)   ALLOW_NOT_MAIN=1
#   - HEAD lacks a branch listed in MUST_CONTAIN below      ALLOW_MISSING_BRANCHES=1
#   - a GitHub release with this tag already exists         (no override: bump the version)
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

# What gets packaged must be exactly what is committed and pushed to main.
if [ -n "$(git -C "$ROOT" status --porcelain)" ] && [ "${ALLOW_DIRTY:-0}" != 1 ]; then
    echo "error: uncommitted changes (git status); commit them first, or ALLOW_DIRTY=1 for a dry run" >&2
    exit 1
fi
if [ "${ALLOW_NOT_MAIN:-0}" != 1 ]; then
    git -C "$ROOT" fetch -q origin main || { echo "error: can't fetch origin/main to compare with HEAD" >&2; exit 1; }
    if [ "$(git -C "$ROOT" rev-parse HEAD)" != "$(git -C "$ROOT" rev-parse origin/main)" ]; then
        echo "error: HEAD is not origin/main; merge and push first, or ALLOW_NOT_MAIN=1 for a dry run" >&2
        exit 1
    fi
fi

# Branches whose features the owner already runs (installed from them) but that aren't on main
# yet. A release without them would take those features away from every copy Sparkle updates.
# Checked only where the branch exists (locally or as origin/<name>); remove a name once it's
# merged into main for good. Details: docs/sparkle-updates/README.md, STATUS / NEXT STEPS.
MUST_CONTAIN=(feat/stability-tour)
if [ "${ALLOW_MISSING_BRANCHES:-0}" != 1 ]; then
    for BRANCH in "${MUST_CONTAIN[@]}"; do
        for REF in "refs/heads/$BRANCH" "refs/remotes/origin/$BRANCH"; do
            git -C "$ROOT" rev-parse -q --verify "$REF" >/dev/null || continue
            if ! git -C "$ROOT" merge-base --is-ancestor "$REF" HEAD; then
                echo "error: HEAD doesn't contain $REF; merge it first (or ALLOW_MISSING_BRANCHES=1 for a dry run)" >&2
                exit 1
            fi
        done
    done
fi

if ! command -v gh >/dev/null; then
    echo "error: gh (GitHub CLI) not found; it's needed to check for and publish the release" >&2
    exit 1
fi
if GH_OUT="$(gh release view "$TAG" --repo "$REPO" 2>&1)"; then
    echo "error: release $TAG already exists on $REPO; bump CFBundleShortVersionString in $PLIST" >&2
    exit 1
elif ! grep -qi "not found" <<<"$GH_OUT"; then
    echo "error: couldn't check whether release $TAG exists: $GH_OUT" >&2
    exit 1
fi

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
$(sed 's/]]>/]]]]><![CDATA[>/g' "$NOTES_OUT")
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
# --target: the tag is created on exactly the commit that was packaged, even if main moves on.
echo "==> To publish, run exactly:"
echo "gh release create $TAG \"$ZIP\" \"$DIST/appcast.xml\" --repo $REPO --target $(git -C "$ROOT" rev-parse HEAD) --latest --title \"MacStats $VERSION\" --notes-file \"$NOTES_OUT\""
