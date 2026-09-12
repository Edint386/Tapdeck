#!/bin/bash
# Build Tapdeck.app and install it into /Applications, so it launches from
# Launchpad or Spotlight like any other app.
set -euo pipefail
cd "$(dirname "$0")"

DESTINATION="/Applications/Tapdeck.app"

# Create the stable signing identity first if it is missing. Without it every
# build is ad-hoc signed, and macOS resets the granted permissions each time.
if ! security find-certificate -c "Tapdeck Local" >/dev/null 2>&1; then
  echo "-> No signing certificate yet; creating one"
  ./tools/setup-signing.sh
fi

./build.sh

if pgrep -x Tapdeck >/dev/null 2>&1; then
  echo "-> Quitting the running Tapdeck"
  osascript -e 'tell application "Tapdeck" to quit' 2>/dev/null || pkill -x Tapdeck || true
  sleep 1
fi

echo "-> Installing to $DESTINATION"
rm -rf "$DESTINATION"
cp -R Tapdeck.app "$DESTINATION"

# Re-register with Launch Services so the icon and name update immediately.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DESTINATION" 2>/dev/null || true

echo "Installed: $DESTINATION"
echo
echo "  Launch:  open -a Tapdeck"
echo "  Driver:  sudo ./install-driver.sh   (once, for virtual devices)"
