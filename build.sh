#!/bin/bash
# Use Xcode's SDK when it is installed, otherwise the Command Line Tools SDK.
# Set DEVELOPER_DIR to build with a particular Xcode instead.
set -euo pipefail
cd "$(dirname "$0")"

source tools/toolchain.sh
SDK="$(xcrun --sdk macosx --show-sdk-path)"

source tools/signing.sh
SIGN_ID="$(signing_identity "${TAPDECK_SIGN_ID:-}")"
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
codesign --force --sign "$SIGN_ID" "$PROOF"

# -- 2. Tapdeck.app ---------------------------------------------------------
echo "→ Tapdeck.app"
APP="Tapdeck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Tapdeck.icns "$APP/Contents/Resources/Tapdeck.icns"

# The compiler also lists every string the code asks to have translated, one
# .stringsdata file per source file. The check below compares that list with the
# catalog, so a string cannot be added to the code without a translation.
rm -rf build/strings
mkdir -p build/strings
xcrun swiftc -O "${common_flags[@]}" -parse-as-library \
  -framework ScreenCaptureKit \
  -emit-localized-strings -emit-localized-strings-path build/strings \
  -o "$APP/Contents/MacOS/Tapdeck" \
  Sources/Engine/*.swift Sources/App/*.swift

echo "→ localization"
python3 tools/check_localization.py build/strings
# xcstringstool ships with Xcode, not with the Command Line Tools.
use_xcstringstool
# One folder per language. Having both is also what makes macOS offer a per-app
# language for Tapdeck in System Settings.
xcrun xcstringstool compile --output-directory "$APP/Contents/Resources" Resources/Localizable.xcstrings
xcrun xcstringstool compile --output-directory "$APP/Contents/Resources" Resources/InfoPlist.xcstrings

echo "→ signing with: $SIGN_ID"
codesign --force --sign "$SIGN_ID" "$APP"

echo "Built build/tapproof and $APP"
