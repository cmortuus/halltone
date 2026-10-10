#!/bin/zsh
# Builds halltone-cli (release) and wraps it in a minimal .app bundle so that, when launched
# through LaunchServices (`open`), TCC attributes the System Audio Recording permission to
# the tool itself rather than to the terminal that spawned it.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release >/dev/null
APP=.build/HalltoneCLI.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/halltone-cli "$APP/Contents/MacOS/halltone-cli"
cp Sources/halltone-cli/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string halltone-cli" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "$APP"
