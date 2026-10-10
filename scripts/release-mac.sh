#!/bin/zsh
# Builds a notarized Halltone.dmg for distribution outside the Mac App Store.
#
# One-time prerequisites (need the paid Apple Developer Program):
#   1. A "Developer ID Application" certificate in the login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application).
#   2. A notarytool keychain profile:
#        xcrun notarytool store-credentials halltone-notary \
#          --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
#
# Usage: scripts/release-mac.sh [--skip-notarize]
#   --skip-notarize  build and sign (Developer ID, or Apple Development if none) without notarizing
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SKIP_NOTARIZE=${1:-}
OUT=.build/release-mac
rm -rf -- "${OUT:?}"
mkdir -p "$OUT"

IDENTITY=$(security find-identity -v -p codesigning | { grep "Developer ID Application" || true; } | head -1 | awk '{print $2}')
if [[ -z "$IDENTITY" ]]; then
  if [[ "$SKIP_NOTARIZE" != "--skip-notarize" ]]; then
    echo "error: no Developer ID Application certificate (see prerequisites at the top of this script)" >&2
    exit 1
  fi
  IDENTITY=$(security find-identity -v -p codesigning | { grep "Apple Development" || true; } | { grep -v REVOKED || true; } | head -1 | awk '{print $2}')
  echo "note: no Developer ID certificate; signing with Apple Development for a local test build"
fi

xcodegen generate >/dev/null
xcodebuild -project Halltone.xcodeproj -scheme HalltoneMac -configuration Release -destination "generic/platform=macOS" \
  -derivedDataPath "$OUT/dd" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP="$OUT/dd/Build/Products/Release/Halltone.app"
codesign --verify --strict --deep "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority=|flags=" | head -3

DMG="$OUT/Halltone.dmg"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Halltone -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null 2>&1
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [[ "$SKIP_NOTARIZE" != "--skip-notarize" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile halltone-notary --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
echo "$DMG"
