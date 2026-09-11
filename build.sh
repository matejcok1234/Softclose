#!/bin/bash
# Builds Softclose.app — SwiftPM binary + compiled shaders + bundle + ad-hoc signature.
# The signature matters: Screen Recording permission is remembered per signed
# bundle, so an unsigned build would re-ask on every rebuild.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=${CONFIG:-release}
APP="build/Softclose.app"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Softclose"

echo "==> shaders"
mkdir -p build/shaders
xcrun -sdk macosx metal -O3 -c Sources/Softclose/Shaders/Bend.metal -o build/shaders/Bend.air
xcrun -sdk macosx metallib build/shaders/Bend.air -o build/shaders/default.metallib

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Softclose"

# Sparkle, which powers Check for Updates, is a framework and has to live
# inside the bundle. SwiftPM copies it to the build directory but doesn't build
# app bundles, so it is placed and signed here.
SPARKLE="$(swift build -c "$CONFIG" --show-bin-path)/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
    cp -R "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
fi
cp build/shaders/default.metallib "$APP/Contents/Resources/default.metallib"
# Shipped as a fallback if the metallib ever fails to load.
cp Sources/Softclose/Shaders/Bend.metal "$APP/Contents/Resources/Bend.metal"
[ -f build/Softclose.icns ] && cp build/Softclose.icns "$APP/Contents/Resources/Softclose.icns"
cp Info.plist "$APP/Contents/Info.plist"

echo "==> sign"
# A Developer ID Application certificate if the machine has one, ad-hoc if not.
# The difference matters twice over: Gatekeeper rejects an ad-hoc signature on
# anything that arrives with a download's quarantine flag, and TCC keys its
# permissions to the signature — an ad-hoc one changes with every build, so
# Screen Recording has to be granted again each time, while a Developer ID
# signature is stable and the grant sticks.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 \
    | sed -E 's/.*"(.*)"/\1/')

if [ -n "$IDENTITY" ]; then
    echo "    identity: $IDENTITY"
    SIGN=(codesign --force --sign "$IDENTITY" --options runtime --timestamp)
else
    echo "    identity: ad-hoc (no Developer ID certificate found)"
    SIGN=(codesign --force --sign - --options runtime --timestamp=none)
fi

# Nested code is signed from the inside out: a signature covers everything
# beneath it, so signing the app first and its framework afterwards would
# invalidate the app's own seal. Sparkle ships ad-hoc signed and its helpers are
# separate executables, each needing its own signature under this identity.
SPARKLE_IN_APP="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_IN_APP" ]; then
    V="$SPARKLE_IN_APP/Versions/B"
    "${SIGN[@]}" "$V/XPCServices/Downloader.xpc" 2>&1 | sed 's/^/    sparkle: /'
    "${SIGN[@]}" "$V/XPCServices/Installer.xpc"  2>&1 | sed 's/^/    sparkle: /'
    "${SIGN[@]}" "$V/Updater.app"                2>&1 | sed 's/^/    sparkle: /'
    "${SIGN[@]}" "$V/Autoupdate"                 2>&1 | sed 's/^/    sparkle: /'
    "${SIGN[@]}" "$SPARKLE_IN_APP"               2>&1 | sed 's/^/    sparkle: /'
fi

"${SIGN[@]}" --identifier io.github.matejcok1234.softclose \
    --entitlements Softclose.entitlements "$APP" 2>&1 | sed 's/^/    /'

echo "==> done: $APP"
