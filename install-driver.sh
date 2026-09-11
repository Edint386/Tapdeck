#!/bin/bash
# 仮想オーディオデバイス (Tapdeck.driver) を macOS へ登録する。
#
# HAL プラグインは /Library/Audio/Plug-Ins/HAL/ にしか置けない。
# coreaudiod は _coreaudiod ユーザーで動くため、ホームディレクトリ下は読めない。
# そのため sudo が必要。
set -euo pipefail
cd "$(dirname "$0")"

if [ "$EUID" -ne 0 ]; then
  echo "sudo で実行してください:  sudo ./install-driver.sh"
  exit 1
fi

./Driver/build-driver.sh

DESTINATION="/Library/Audio/Plug-Ins/HAL/Tapdeck.driver"
echo "→ $DESTINATION へインストール"
rm -rf "$DESTINATION"
cp -R build/Tapdeck.driver "$DESTINATION"

echo "→ coreaudiod を再起動します（一瞬すべての音が途切れます）"
killall coreaudiod
echo "✓ インストールしました。「Tapdeck」が入力・出力デバイスとして現れます。"
