#!/bin/bash
# Use Xcode's SDK when it is installed, otherwise the Command Line Tools SDK.
set -euo pipefail
cd "$(dirname "$0")"

if [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-macos15.0"
mkdir -p build

common_flags=(-swift-version 5 -target "$TARGET" -sdk "$SDK"
              -framework CoreAudio -framework AVFoundation -framework AppKit)

# -- 1. tapproof: command line harness for the audio engine ------------------
echo "→ tapproof"
xcrun swiftc -O "${common_flags[@]}" \
  -o build/tapproof \
  Sources/Engine/*.swift Sources/CLI/*.swift

# tapproof needs microphone permission to read an input device, and TCC cannot
# prompt for a bare executable, so wrap it in an .app. Running the binary inside
# the bundle directly still gives normal stdout.
echo "-> Tapproof.app (bundle so TCC can prompt)"
PROOF="build/Tapproof.app"
rm -rf "$PROOF"
mkdir -p "$PROOF/Contents/MacOS"
cp Resources/Tapproof-Info.plist "$PROOF/Contents/Info.plist"
cp build/tapproof "$PROOF/Contents/MacOS/tapproof"
codesign --force --sign "${TAPDECK_SIGN_ID:--}" "$PROOF"

# -- 2. Tapdeck.app ---------------------------------------------------------
echo "→ Tapdeck.app"
APP="Tapdeck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Tapdeck.icns "$APP/Contents/Resources/Tapdeck.icns"

xcrun swiftc -O "${common_flags[@]}" -parse-as-library \
  -framework ScreenCaptureKit \
  -o "$APP/Contents/MacOS/Tapdeck" \
  Sources/Engine/*.swift Sources/App/*.swift

# Signing: prefer the stable self-signed "Tapdeck Local" certificate. An ad-hoc
# signature changes on every build, which resets the granted permissions.
SIGN_ID="${TAPDECK_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  if security find-certificate -c "Tapdeck Local" >/dev/null 2>&1; then
    SIGN_ID="Tapdeck Local"
  else
    SIGN_ID="-"
  fi
fi
echo "→ signing with: $SIGN_ID"
codesign --force --sign "$SIGN_ID" "$APP"

echo "Built build/tapproof and $APP"
