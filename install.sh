#!/bin/bash
# Build, install to /Applications, and re-arm the Screen Recording permission.
#
# build.sh ad-hoc signs, so every build is a different app as far as macOS is
# concerned and the previous grant silently stops matching — capture then fails
# with "the user declined TCCs" even though the switch in Privacy settings still
# looks on. Clearing Softclose's own entry means the next launch asks cleanly.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

echo "==> install"
pkill -f "Softclose.app/Contents/MacOS/Softclose" 2>/dev/null || true
sleep 1
rm -rf /Applications/Softclose.app
cp -R build/Softclose.app /Applications/Softclose.app
rm -rf build/Softclose.app          # one bundle only, so macOS has one app to resolve

echo "==> reset Screen Recording approval (stale after re-signing)"
# Non-zero when there is no entry yet, which is the normal first-install case.
tccutil reset ScreenCapture io.github.matejcok1234.softclose || true

open /Applications/Softclose.app
echo "==> running. Allow Screen Recording when asked, or add Softclose under"
echo "    Privacy & Security › Screen & System Audio Recording."
