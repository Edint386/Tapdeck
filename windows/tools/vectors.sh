#!/bin/bash
# Builds the reference vector generator from the unchanged Swift sources it
# exercises, and runs it on windows/vectors.
#
#   windows/tools/vectors.sh write      regenerate windows/vectors
#   windows/tools/vectors.sh check      fail when windows/vectors no longer match the Swift code
#   windows/tools/vectors.sh selftest   show that the comparison catches every kind of change
set -euo pipefail
cd "$(dirname "$0")/../.."

source tools/toolchain.sh
mkdir -p build/windows
xcrun swiftc -O -swift-version 5 \
  Sources/Engine/GainStage.swift Sources/Engine/RoutingGraph.swift \
  windows/tools/vectors/*.swift \
  -o build/windows/vectorgen
if [ "${1:-check}" = selftest ]; then
  build/windows/vectorgen selftest
else
  build/windows/vectorgen "${1:-check}" windows/vectors
fi
