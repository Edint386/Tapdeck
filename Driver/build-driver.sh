#!/bin/bash
# Build Tapdeck.driver (an AudioServerPlugIn).
# Installing needs sudo, so this script stops at building.
set -euo pipefail
cd "$(dirname "$0")"

# Xcode refuses to run until its license is accepted again after an update,
# so fall back to the Command Line Tools when it cannot be used.
if [ -d /Applications/Xcode.app ] &&
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
elif [ -d /Applications/Xcode.app ]; then
  echo "note: Xcode is not usable (license not accepted?); building with the Command Line Tools" >&2
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

# Core Audio will not load an unsigned plug-in. Its plug-in host runs with
# com.apple.security.cs.disable-library-validation, so it does not insist on a
# particular signer: the shared certificate works, and so does ad-hoc.
source ../tools/signing.sh  # the script runs from Driver/
SIGN_ID="$(signing_identity "${TAPDECK_DRIVER_SIGN_ID:-}")"
echo "→ signing with: $SIGN_ID"
codesign --force --sign "$SIGN_ID" "$BUNDLE"
codesign --verify --verbose=2 "$BUNDLE" 2>&1 | sed 's/^/   /'

echo "✓ $BUNDLE"
