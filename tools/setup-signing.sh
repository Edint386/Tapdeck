#!/bin/bash
# Create one stable code signing identity and put it in the keychain.
#
# Why this is needed: an ad-hoc signature (codesign -s -) changes on every
# build. macOS then treats each build as a different application and resets the
# permissions it was granted — microphone, screen recording, audio capture.
# Signing with a fixed certificate keeps them.
#
# Distribution needs a Developer ID from the Apple Developer Program plus
# notarisation. This is for running on your own Mac.
set -euo pipefail

NAME="Tapdeck Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" is already in the keychain"
  exit 0
fi

# Use the LibreSSL that ships with macOS. PKCS#12 bundles from Homebrew's
# OpenSSL 3 use newer default algorithms that the security command cannot read
# (it fails with "MAC verification failed").
OPENSSL=/usr/bin/openssl

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "-> Creating a self-signed certificate…"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$NAME/O=Tapdeck" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

"$OPENSSL" pkcs12 -export -out "$WORK/bundle.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -passout pass:tapdeck 2>/dev/null

echo "-> Adding it to the keychain (enter your login password if asked)"
security import "$WORK/bundle.p12" -k "$KEYCHAIN" -P tapdeck \
  -T /usr/bin/codesign -T /usr/bin/security -A

echo "Added \"$NAME\". build.sh will pick it up automatically."
