# Picks the developer directory for build.sh and Driver/build-driver.sh. Source it.
#
# A DEVELOPER_DIR set by the caller is used as it is. Otherwise Xcode is preferred,
# but only when it can be used and its SDK is macOS 15 or later: Xcode refuses to
# run until its license is accepted again after an update, and an older Xcode left
# beside newer Command Line Tools cannot compile the app. In either case the Command
# Line Tools are used, named explicitly, because xcode-select may still point at
# that Xcode.

XCODE_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
CLT_DEVELOPER_DIR=/Library/Developer/CommandLineTools

if [ -n "${DEVELOPER_DIR:-}" ]; then
  export DEVELOPER_DIR
elif [ -d "$XCODE_DEVELOPER_DIR" ] &&
     xcode_sdk_version="$(DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcrun --sdk macosx --show-sdk-version 2>/dev/null)" &&
     [ "${xcode_sdk_version%%.*}" -ge 15 ]; then
  export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
elif [ -d "$CLT_DEVELOPER_DIR" ]; then
  if [ -d "$XCODE_DEVELOPER_DIR" ]; then
    echo "note: Xcode is not usable (license not accepted, or its SDK is older than macOS 15); building with the Command Line Tools" >&2
  fi
  export DEVELOPER_DIR="$CLT_DEVELOPER_DIR"
fi

# xcstringstool ships with Xcode only. When the chosen toolchain lacks it, use the
# first installed Xcode that has it; compiling a String Catalog does not depend on
# the SDK.
use_xcstringstool() {
  xcrun --find xcstringstool >/dev/null 2>&1 && return 0
  local xcode
  for xcode in /Applications/Xcode.app /Applications/Xcode*.app; do
    if DEVELOPER_DIR="$xcode/Contents/Developer" xcrun --find xcstringstool >/dev/null 2>&1; then
      export DEVELOPER_DIR="$xcode/Contents/Developer"
      return 0
    fi
  done
  echo "error: xcstringstool not found; it ships with Xcode" >&2
  return 1
}
