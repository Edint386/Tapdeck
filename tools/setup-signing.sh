#!/bin/bash
# 安定したコード署名IDを1つ作ってキーチェーンに入れる。
#
# なぜ必要か:
#   ad-hoc 署名 (codesign -s -) はビルドのたびに署名が変わる。macOS から見ると
#   毎回「別のアプリ」なので、マイク・画面収録・オーディオ録音の許可が
#   その都度リセットされる。固定の証明書で署名すれば許可が維持される。
#
# 配布には Apple Developer Program の Developer ID と公証が必要。
# これは「自分の Mac で使う」ためのもの。
set -euo pipefail

NAME="Tapdeck Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "✓ 「$NAME」は既にキーチェーンにあります"
  exit 0
fi

# macOS 同梱の LibreSSL を使う。Homebrew の OpenSSL 3 が作る PKCS#12 は
# 既定のアルゴリズムが新しすぎて、security コマンドが読み込めない
# （MAC verification failed になる）。
OPENSSL=/usr/bin/openssl

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "→ 自己署名の証明書を作成中 …"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$NAME/O=Tapdeck" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

"$OPENSSL" pkcs12 -export -out "$WORK/bundle.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -passout pass:tapdeck 2>/dev/null

echo "→ キーチェーンへ登録します（パスワードを聞かれたらログインパスワードを入れてください）"
security import "$WORK/bundle.p12" -k "$KEYCHAIN" -P tapdeck \
  -T /usr/bin/codesign -T /usr/bin/security -A

echo "✓ 「$NAME」を登録しました。build.sh が自動でこれを使います。"
