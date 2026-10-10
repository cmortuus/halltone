#!/bin/zsh
# Runs the HalltoneCore unit tests. The Command Line Tools' swift-build occasionally loses the
# TestingMacros plugin on incremental builds; retry once, then fall back to a clean build.
set -uo pipefail
cd "$(dirname "$0")/../Packages/HalltoneCore"
for attempt in 1 2 3; do
  out=$(swift test "$@" 2>&1)
  if ! grep -q "TestingMacros" <<<"$out"; then
    echo "$out"
    exit 0
  fi
  [ $attempt -eq 2 ] && rm -rf .build
done
echo "$out"
exit 1
