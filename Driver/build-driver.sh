#!/bin/bash
# Tapdeck.driver（AudioServerPlugIn）をビルドする。
# インストールは sudo が要るので、このスクリプトはビルドまでしか行わない。
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

# coreaudiod は署名されていないプラグインを読み込まない。
# 自分用なら ad-hoc (-) でよい。配布するなら Developer ID + 公証が必要。
SIGN_ID="${TAPDECK_DRIVER_SIGN_ID:--}"
echo "→ signing with: $SIGN_ID"
codesign --force --sign "$SIGN_ID" "$BUNDLE"
codesign --verify --verbose=2 "$BUNDLE" 2>&1 | sed 's/^/   /'

echo "✓ $BUNDLE"
