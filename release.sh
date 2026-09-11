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

PROFILE=${NOTARY_PROFILE:-softclose}
ADHOC=$(codesign -dvv build/Softclose.app 2>&1 | grep -c "Signature=adhoc" || true)

# Two rounds of notarisation, and the order matters.
#
# Round one is the app. Apple issues a ticket against its code signature, and
# stapling writes that ticket into the bundle — which is what lets it launch on
# a Mac that is offline. An unstapled app has to reach Apple on first launch
# instead, and fails closed if it can't.
#
# Round two is the finished disk image, which has to happen after, because
# packaging the stapled app changes the image and would invalidate any ticket
# issued for an earlier version of it.

if [ "$ADHOC" = "0" ] && xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "==> notarising the app (a few minutes)"
    rm -f build/Softclose.zip
    ditto -c -k --keepParent build/Softclose.app build/Softclose.zip
    xcrun notarytool submit build/Softclose.zip --keychain-profile "$PROFILE" --wait 2>&1 \
        | grep -E "id:|status:" | sed 's/^/    /'
    rm -f build/Softclose.zip
    xcrun stapler staple build/Softclose.app 2>&1 | tail -1 | sed 's/^/    /'
else
    echo "==> skipping notarisation (ad-hoc signed, or no '$PROFILE' profile — see NOTARISING.md)"
fi

echo "==> background"
swiftc -O Tools/MakeDMGBackground.swift -o build/makedmgbg
./build/makedmgbg build >/dev/null
# One TIFF carrying 1x and 2x, so the window is sharp on a Retina display.
tiffutil -cathidpicheck build/dmg-background.png build/dmg-background@2x.png \
    -out build/dmg-background.tiff >/dev/null 2>&1

echo "==> dmg"
rm -f "$DMG"
if command -v dmgbuild >/dev/null 2>&1; then
    # dmgbuild writes the .DS_Store directly. Driving the Finder over AppleScript
    # is the usual way to lay out an install window, and it needs Automation
    # permission, behaves differently when the screen is locked, and hangs often
    # enough to be a poor fit for a release script.
    # `|| true` because the filter can swallow every line, and under
    # `set -o pipefail` a grep that matches nothing takes the script down with
    # it — silently, after the image has already been built.
    { dmgbuild -s dmg-settings.py -D app=build/Softclose.app \
        "Softclose $VERSION" "$DMG" 2>&1 | grep -v "WARNING" | sed 's/^/    /'; } || true
else
    echo "    dmgbuild not installed — plain image (pipx install dmgbuild)"
    rm -rf build/dmg && mkdir -p build/dmg
    cp -R build/Softclose.app build/dmg/Softclose.app
    ln -s /Applications build/dmg/Applications
    hdiutil create -volname "Softclose $VERSION" -srcfolder build/dmg \
        -ov -format UDZO -quiet "$DMG"
    rm -rf build/dmg
fi

if [ "$ADHOC" = "0" ]; then
    IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" \
        | head -1 | sed -E 's/.*"(.*)"/\1/')
    if [ -n "$IDENTITY" ]; then
        echo "==> signing the disk image"
        codesign --force --sign "$IDENTITY" --timestamp "$DMG" 2>&1 | sed 's/^/    /'
    fi
    if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        echo "==> notarising the disk image (a few minutes)"
        xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1 \
            | grep -E "id:|status:" | sed 's/^/    /'
        xcrun stapler staple "$DMG" 2>&1 | tail -1 | sed 's/^/    /'
    fi
fi

echo "==> $DMG"
ls -lh "$DMG" | awk '{print "    size:  " $5}'
shasum -a 256 "$DMG" | awk '{print "    sha256: " $1}'
# What a user's Mac decides, checked the way it will actually be asked:
# the image on mount, and the app once it has been dragged out.
spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 \
    | sed 's/^/    image:  /'
spctl --assess --type execute -v build/Softclose.app 2>&1 | sed 's/^/    app:    /'
xcrun stapler validate "$DMG" >/dev/null 2>&1 \
    && echo "    ticket: stapled to image and app" \
    || echo "    ticket: NOT stapled to the image"


