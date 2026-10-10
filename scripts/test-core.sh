#!/bin/zsh
# Runs the HalltoneCore unit tests. Prefers Xcode's toolchain: the Command Line Tools' swift-build
# intermittently loses the TestingMacros plugin. Falls back to CLT (with retries) without Xcode.
set -uo pipefail
cd "$(dirname "$0")/../Packages/HalltoneCore"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
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
