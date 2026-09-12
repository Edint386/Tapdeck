#!/bin/bash
# Build Tapdeck.driver (an AudioServerPlugIn).
# Installing needs sudo, so this script stops at building.
set -euo pipefail
cd "$(dirname "$0")"

if [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"

BUNDLE="../build/driver/Tapdeck.driver"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp Info.plist "$BUNDLE/Contents/Info.plist"

echo "→ compiling TapdeckDriver"
xcrun clang -bundle -O2 \
  -isysroot "$SDK" \
  -arch arm64 -arch x86_64 \
  -mmacosx-version-min=13.0 \
  -Wall -Wextra \
  -framework CoreFoundation -framework CoreAudio \
  -o "$BUNDLE/Contents/MacOS/TapdeckDriver" \
  TapdeckDriver.c

# Core Audio will not load an unsigned plug-in. Ad-hoc (-) is fine for your own
# machine; distribution needs a Developer ID signature and notarisation.
SIGN_ID="${TAPDECK_DRIVER_SIGN_ID:--}"
echo "→ signing with: $SIGN_ID"
codesign --force --sign "$SIGN_ID" "$BUNDLE"
codesign --verify --verbose=2 "$BUNDLE" 2>&1 | sed 's/^/   /'

echo "✓ $BUNDLE"
