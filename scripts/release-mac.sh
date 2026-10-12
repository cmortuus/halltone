#!/bin/zsh
# Builds a notarized, stapled Halltone.dmg for distribution outside the Mac App Store.
#
# Prerequisites: Xcode signed in (Settings → Accounts) to the paid Apple Developer team, and a
# "Developer ID Application" certificate (Accounts → team → Manage Certificates → +).
# Notarization goes through the Xcode account, so no app-specific password is needed.
#
# Usage: scripts/release-mac.sh            # archive, notarize, staple, DMG
#        scripts/release-mac.sh --no-notarize  # signed DMG only (local testing)
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
TEAM=$(awk '/DEVELOPMENT_TEAM:/{print $2; exit}' project.yml)
OUT=.build/release-mac
rm -rf -- "${OUT:?}"
mkdir -p "$OUT"

IDENTITY=$(security find-identity -v -p codesigning | { grep "Developer ID Application" || true; } | head -1 | awk '{print $2}')
[[ -n "$IDENTITY" ]] || { echo "error: no Developer ID Application certificate (see prerequisites)" >&2; exit 1; }

xcodegen generate >/dev/null
xcodebuild -project Halltone.xcodeproj -scheme HalltoneMac -configuration Release -destination "generic/platform=macOS" \
  -archivePath "$OUT/Halltone.xcarchive" -allowProvisioningUpdates archive | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"

if [[ "${1:-}" == "--no-notarize" ]]; then
  DEST=export
else
  DEST=upload
fi
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>$DEST</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/Halltone.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" -allowProvisioningUpdates | grep -E "error:|EXPORT (SUCCEEDED|FAILED)|Uploaded"

if [[ "$DEST" == upload ]]; then
  echo "waiting for notarization…"
  for _ in {1..60}; do
    if xcodebuild -exportNotarizedApp -archivePath "$OUT/Halltone.xcarchive" -exportPath "$OUT/app" 2>&1 | grep -q "EXPORT SUCCEEDED"; then
      break
    fi
    sleep 30
  done
  [[ -d "$OUT/app/Halltone.app" ]] || { echo "error: notarization did not finish (check Xcode Organizer)" >&2; exit 1; }
  APP="$OUT/app/Halltone.app"
  xcrun stapler validate "$APP"
  spctl --assess --type execute -v "$APP"
else
  APP="$OUT/export/Halltone.app"
fi

STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Halltone.dmg"
hdiutil create -volname Halltone -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null 2>&1
codesign --sign "$IDENTITY" --timestamp "$DMG"
echo "$DMG"
