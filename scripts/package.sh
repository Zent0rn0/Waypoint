#!/bin/bash
# Builds the release files in build/: Waypoint-<version>-macos-arm64.dmg (drag to Applications), the same app as .zip,
# and SHA256SUMS. Usage: scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bundle.sh release
APP=build/Waypoint.app
V="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
NAME="Waypoint-$V-macos-arm64"
rm -f "build/$NAME.zip" "build/$NAME.dmg" build/SHA256SUMS

ditto -c -k --keepParent "$APP" "build/$NAME.zip"

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Waypoint.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Waypoint $V" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "build/$NAME.dmg"

(cd build && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS && cat SHA256SUMS)
ls -la "build/$NAME.dmg" "build/$NAME.zip"
