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
    # A secure timestamp is required for notarisation; ad-hoc cannot have one.
    codesign --force --sign "$IDENTITY" --identifier io.github.matejcok1234.softclose \
        --entitlements Softclose.entitlements --options runtime \
        --timestamp "$APP" 2>&1 | sed 's/^/    /'
else
    echo "    identity: ad-hoc (no Developer ID certificate found)"
    codesign --force --sign - --identifier io.github.matejcok1234.softclose \
        --entitlements Softclose.entitlements --options runtime \
        --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
fi

echo "==> done: $APP"
