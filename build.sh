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
codesign --force --sign - --identifier io.github.matejcok1234.softclose \
    --entitlements Softclose.entitlements --options runtime \
    --timestamp=none "$APP" 2>&1 | sed 's/^/    /'

echo "==> done: $APP"
