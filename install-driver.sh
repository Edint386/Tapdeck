#!/bin/bash
# Register the virtual audio devices (Tapdeck.driver) with macOS.
#
# A HAL plug-in can only live in /Library/Audio/Plug-Ins/HAL/. The process that
# hosts it runs as another user and cannot read anything under your home
# directory, which is why this needs sudo.
set -euo pipefail
cd "$(dirname "$0")"

if [ "$EUID" -ne 0 ]; then
  echo "Run this with sudo:  sudo ./install-driver.sh"
  exit 1
fi

# Build as the original user. Building as root would leave the products owned
# by root and stop that user from rebuilding afterwards.
if [ -n "${SUDO_USER:-}" ]; then
  sudo -u "$SUDO_USER" ./Driver/build-driver.sh
else
  ./Driver/build-driver.sh
fi

# Prepare somewhere for the virtual device configuration.
#
# The host process is sandboxed and can only read a few locations.
# （/System/Library/Sandbox/Profiles/com.apple.audio.coreaudiod.sb）。
# Somewhere like /Users/Shared is not allowed and reads there fail silently.
# /Library/Preferences/Audio is allowed, but Audio itself is root:_coreaudiod
# 775 and the Data directory beneath it is SIP-restricted, so create a
# user-owned directory here that the app can write to.
CONFIG_DIR="/Library/Preferences/Audio/Tapdeck"
mkdir -p "$CONFIG_DIR"
chmod 755 "$CONFIG_DIR"
if [ -n "${SUDO_USER:-}" ]; then
  chown -R "$SUDO_USER" "$CONFIG_DIR"
fi
echo "-> Configuration directory: $CONFIG_DIR"

DESTINATION="/Library/Audio/Plug-Ins/HAL/Tapdeck.driver"
echo "-> Installing to $DESTINATION"
rm -rf "$DESTINATION"
cp -R build/driver/Tapdeck.driver "$DESTINATION"

echo "-> Restarting Core Audio (all audio cuts out for a moment)"
killall coreaudiod
echo "Installed. Tapdeck now appears as an input and output device."
