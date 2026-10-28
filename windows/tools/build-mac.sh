#!/bin/bash
# Builds the Windows engine's portable code on the Mac and runs its tests, with
# the same toolchain choice as build.sh.
#
#   windows/tools/build-mac.sh          release build and all tests
#   windows/tools/build-mac.sh thread   ringtest under ThreadSanitizer
#   windows/tools/build-mac.sh address  all tests under AddressSanitizer
set -euo pipefail
cd "$(dirname "$0")/../.."

source tools/toolchain.sh
sanitizer="${1:-}"
directory="build/windows-cpp${sanitizer:+-$sanitizer}"
# --fresh: a changed compiler would otherwise make CMake drop its cache and
# silently forget the sanitizer.
cmake --fresh -S windows -B "$directory" \
  -DCMAKE_BUILD_TYPE="${sanitizer:+RelWithDebInfo}" \
  -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
  -DCMAKE_OSX_SYSROOT="$(xcrun --show-sdk-path)" \
  -DTAPDECK_SANITIZE="$sanitizer" >/dev/null
cmake --build "$directory" --parallel
if [ "$sanitizer" = thread ]; then
  "$directory/ringtest"
else
  ctest --test-dir "$directory" --output-on-failure
fi
