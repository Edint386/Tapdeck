#!/bin/bash
# Xcode があればその SDK を、無ければ Command Line Tools の SDK を使う。
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

# ── 1. tapproof — オーディオエンジンの検証用CLI ──────────────────────
echo "→ tapproof"
xcrun swiftc -O "${common_flags[@]}" \
  -o build/tapproof \
  Sources/Engine/*.swift Sources/CLI/*.swift

# tapproof は入力デバイスを読むためマイク権限が要る。TCC はバンドルを持たない
# 実行ファイルにプロンプトを出せないので、.app に包んでおく。
# バンドル内のバイナリを直接起動すれば標準出力はそのまま使える。
echo "→ Tapproof.app (TCC 用のバンドル)"
PROOF="build/Tapproof.app"
rm -rf "$PROOF"
mkdir -p "$PROOF/Contents/MacOS"
cp Resources/Tapproof-Info.plist "$PROOF/Contents/Info.plist"
cp build/tapproof "$PROOF/Contents/MacOS/tapproof"
codesign --force --sign "${TAPDECK_SIGN_ID:--}" "$PROOF"

# ── 2. Tapdeck.app — 画面収録UI（Phase 1 の成果物）────────────────────
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

# 署名: 安定した自己署名証明書 "Tapdeck Local" があればそれを使う。
# ad-hoc だとビルドのたびに署名が変わり、画面収録の許可を毎回求められる。
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

echo "✓ build/tapproof と $APP をビルドしました"
