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

echo "==> $DMG"
ls -lh "$DMG" | awk '{print "    size:  " $5}'
shasum -a 256 "$DMG" | awk '{print "    sha256: " $1}'
spctl --assess --type execute -vv build/Softclose.app 2>&1 | sed 's/^/    gatekeeper: /'

# To ship without the quarantine warning, replace the ad-hoc signature in
# build.sh with a Developer ID Application certificate, then:
#
#   xcrun notarytool submit "$DMG" --keychain-profile <profile> --wait
#   xcrun stapler staple "$DMG"
#
# The keychain profile is created once with `xcrun notarytool store-credentials`
# and needs an app-specific password from appleid.apple.com.
