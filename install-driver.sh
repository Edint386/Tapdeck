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

# ビルドは元のユーザーで行う。root でビルドすると成果物が root 所有になり、
# 以降そのユーザーがビルドし直せなくなる。
if [ -n "${SUDO_USER:-}" ]; then
  sudo -u "$SUDO_USER" ./Driver/build-driver.sh
else
  ./Driver/build-driver.sh
fi

# 仮想デバイスの設定ファイルの置き場所を用意する。
#
# coreaudiod はサンドボックス下で動き、読める場所が限られている
# （/System/Library/Sandbox/Profiles/com.apple.audio.coreaudiod.sb）。
# /Users/Shared などは許可されておらず、読もうとしても静かに失敗する。
# /Library/Preferences/Audio 配下は許可されているが、Audio 自体は
# root:_coreaudiod の 775、その下の Data は SIP の restricted。
# そこでここにユーザー所有のディレクトリを作り、アプリから書けるようにする。
CONFIG_DIR="/Library/Preferences/Audio/Tapdeck"
mkdir -p "$CONFIG_DIR"
chmod 755 "$CONFIG_DIR"
if [ -n "${SUDO_USER:-}" ]; then
  chown -R "$SUDO_USER" "$CONFIG_DIR"
fi
echo "→ 設定の置き場所: $CONFIG_DIR"

DESTINATION="/Library/Audio/Plug-Ins/HAL/Tapdeck.driver"
echo "→ $DESTINATION へインストール"
rm -rf "$DESTINATION"
cp -R build/driver/Tapdeck.driver "$DESTINATION"

echo "→ coreaudiod を再起動します（一瞬すべての音が途切れます）"
killall coreaudiod
echo "✓ インストールしました。「Tapdeck」が入力・出力デバイスとして現れます。"
