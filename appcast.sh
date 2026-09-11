#!/bin/bash
# Regenerates the update feed from the current release DMG.
#
# The feed lists only the newest version, which is all Sparkle needs to offer an
# update. Keeping every past release in it would mean either hosting all the old
# DMGs in one place or rewriting each entry's URL, and neither buys anything.
#
# Each entry is signed with the EdDSA private key in the login keychain. That
# key is what makes an update trustworthy: Sparkle checks the signature against
# the public key compiled into the app, so a tampered download is refused even
# if the feed itself is served over a compromised connection. Losing the key
# means no existing install can ever be updated again.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG="build/Softclose-$VERSION.dmg"
TOOLS=".build/artifacts/sparkle/Sparkle/bin"

[ -f "$DMG" ] || { echo "no $DMG — run ./release.sh first"; exit 1; }
[ -x "$TOOLS/generate_appcast" ] || { echo "Sparkle tools missing — run swift build"; exit 1; }

echo "==> feed for $VERSION"
rm -rf build/appcast && mkdir -p build/appcast
cp "$DMG" build/appcast/

"$TOOLS/generate_appcast" \
    --download-url-prefix "https://github.com/matejcok1234/Softclose/releases/download/v$VERSION/" \
    --link "https://github.com/matejcok1234/Softclose" \
    build/appcast

mkdir -p docs
cp build/appcast/appcast.xml docs/appcast.xml
echo "==> docs/appcast.xml"
grep -E "sparkle:version|sparkle:edSignature|url=" docs/appcast.xml | sed 's/^/    /' | cut -c1-140
