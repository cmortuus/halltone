#!/bin/zsh
# Pulls Documents/halltone.log from the Halltone iPhone app over USB (or Wi-Fi once paired).
# Usage: scripts/phone-log.sh [device-udid] [out-file]
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
DEVICE=${1:-00008130-000165113601001C}
OUT=${2:-phone-halltone.log}
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier com.halltone.phone --source Documents/halltone.log --destination "$OUT" >/dev/null
echo "$OUT"
