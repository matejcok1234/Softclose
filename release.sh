#!/bin/bash
# Builds a distributable DMG from the current source.
#
# The app is ad-hoc signed, so Gatekeeper rejects it once the download carries a
# quarantine flag — see the Download section of the README for what users have
# to do about that. Signing with a Developer ID certificate and notarising is
# the fix; there is a stub for it at the bottom of this script.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG="build/Softclose-$VERSION.dmg"

./build.sh

echo "==> staging"
rm -rf build/dmg
mkdir -p build/dmg
cp -R build/Softclose.app build/dmg/Softclose.app
ln -s /Applications build/dmg/Applications      # so the window is drag-to-install

echo "==> dmg"
rm -f "$DMG"
hdiutil create -volname "Softclose $VERSION" -srcfolder build/dmg \
    -ov -format UDZO -quiet "$DMG"
rm -rf build/dmg

# Notarisation. Needs a Developer ID signature and a stored notarytool profile;
# see NOTARISING.md for the one-time setup. Skipped cleanly without them, so the
# script still produces a working (if quarantine-flagged) DMG.
PROFILE=${NOTARY_PROFILE:-softclose}
if codesign -dvv build/Softclose.app 2>&1 | grep -q "Signature=adhoc"; then
    echo "==> not notarising: app is ad-hoc signed"
elif ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "==> not notarising: no notarytool profile '$PROFILE' (see NOTARISING.md)"
else
    echo "==> notarising (a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1 | sed 's/^/    /'
    echo "==> stapling"
    xcrun stapler staple "$DMG" 2>&1 | sed 's/^/    /'
fi

echo "==> $DMG"
ls -lh "$DMG" | awk '{print "    size:  " $5}'
shasum -a 256 "$DMG" | awk '{print "    sha256: " $1}'
# The real test: what a user's Mac decides about the downloaded file.
spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 \
    | sed 's/^/    gatekeeper: /'


