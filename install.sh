#!/bin/bash
# Tapdeck.app をビルドして /Applications へ入れる。
# 以降は普段のアプリと同じように Launchpad や Spotlight から起動できる。
set -euo pipefail
cd "$(dirname "$0")"

DESTINATION="/Applications/Tapdeck.app"

# 固定の署名IDが無ければ先に作る。無いまま ad-hoc で署名すると
# ビルドのたびに許可（マイク・画面収録・オーディオ録音）が取り直しになる。
if ! security find-certificate -c "Tapdeck Local" >/dev/null 2>&1; then
  echo "→ 署名用の証明書がないので作成します"
  ./tools/setup-signing.sh
fi

./build.sh

if pgrep -x Tapdeck >/dev/null 2>&1; then
  echo "→ 実行中の Tapdeck を終了します"
  osascript -e 'tell application "Tapdeck" to quit' 2>/dev/null || pkill -x Tapdeck || true
  sleep 1
fi

echo "→ $DESTINATION へインストール"
rm -rf "$DESTINATION"
cp -R Tapdeck.app "$DESTINATION"

# Launch Services に登録し直して、アイコンと名前を即座に反映させる。
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DESTINATION" 2>/dev/null || true

echo "✓ インストールしました: $DESTINATION"
echo
echo "  起動:        open -a Tapdeck"
echo "  ドライバ:    sudo ./install-driver.sh   （仮想デバイスを使う場合、初回のみ）"
