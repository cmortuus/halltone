#!/bin/zsh
# Builds the HalltonePhone app (Debug), installs it on the iPhone and launches it, over USB or
# Wi-Fi: a paired phone on the same network needs no cable (Xcode → Devices → Connect via network).
# Usage: scripts/deploy-phone.sh [device-udid]
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
DEVICE=${1:-00008130-000165113601001C}
DD=.build/DerivedData-phone
[ -d Halltone.xcodeproj ] || xcodegen generate >/dev/null
xcodebuild -project Halltone.xcodeproj -scheme HalltonePhone -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath "$DD" -allowProvisioningUpdates -quiet build
xcrun devicectl device install app --device "$DEVICE" "$DD/Build/Products/Debug-iphoneos/Halltone.app" >/dev/null
echo "installed on $DEVICE"
# Launching needs the phone unlocked; it's installed either way.
xcrun devicectl device process launch --device "$DEVICE" com.halltone.phone >/dev/null 2>&1 \
  && echo "launched" || echo "not launched (phone locked?): open Halltone on the phone"
