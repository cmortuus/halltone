#!/bin/zsh
# Builds the menu bar app with SwiftPM (no Xcode needed) and wraps it as Halltone.app.
# Usage: ./make-bundle.sh [--run]
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release 2>&1 | grep -E "error|warning: unre" || true
APP=.build/Halltone.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/HalltoneMac "$APP/Contents/MacOS/Halltone"
cp Halltone.icns "$APP/Contents/Resources/Halltone.icns"
sed -e 's/\$(EXECUTABLE_NAME)/Halltone/' -e 's/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.halltone.mac/' Info.plist > "$APP/Contents/Info.plist"
# Sign with a valid Apple Development identity, chosen by SHA-1 hash: several certificates can
# share the same name, which makes signing by name ambiguous. A stable identity keeps the
# System Audio Recording permission across rebuilds; ad hoc is only a fallback.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | grep -v REVOKED | head -1 | awk '{print $2}')
if [[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" --identifier com.halltone.mac "$APP" >/dev/null 2>&1; then
  :
else
  echo "warning: no usable Apple Development identity; signing ad hoc (System Audio Recording may need re-granting)" >&2
  codesign --force --sign - --identifier com.halltone.mac "$APP"
fi
echo "$APP"
if [[ "${1:-}" == "--run" ]]; then
  # Quit the running copy and wait for it to exit; opening while it is still terminating makes
  # LaunchServices hand the request to the dying instance and nothing new starts.
  pkill -f "Halltone.app/Contents/MacOS/Halltone" 2>/dev/null || true
  for _ in {1..50}; do pgrep -f "Halltone.app/Contents/MacOS/Halltone" >/dev/null || break; sleep 0.1; done
  open -n "$APP"
  for _ in {1..50}; do pgrep -f "Halltone.app/Contents/MacOS/Halltone" >/dev/null && break; sleep 0.1; done
  pgrep -f "Halltone.app/Contents/MacOS/Halltone" >/dev/null || { echo "error: Halltone did not start" >&2; exit 1; }
fi
