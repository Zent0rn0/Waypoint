#!/bin/bash
# Builds build/Waypoint.app (menu bar app, with the daemon installer inside) and build/waypoint (CLI).
# Usage: scripts/bundle.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Waypoint.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/WaypointApp" "$APP/Contents/MacOS/Waypoint"
cp "$BIN/waypoint" build/waypoint

# Everything the in-app "install daemon" button needs (runs behind the standard macOS administrator prompt).
R="$APP/Contents/Resources"
cp build/waypoint "$R/waypoint"
cp vendor/sing-box "$R/sing-box"
cp vendor/xray "$R/xray"                      # helper for servers only Xray can carry (user privileges)
cp vendor/xray.LICENSE vendor/sing-box.LICENSE "$R/" 2>/dev/null || true
cp scripts/install-daemon.sh scripts/uninstall-daemon.sh "$R/"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$R/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Waypoint</string>
  <key>CFBundleDisplayName</key><string>Waypoint</string>
  <key>CFBundleIdentifier</key><string>dev.waypoint.app</string>
  <key>CFBundleExecutable</key><string>Waypoint</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>CFBundleLocalizations</key><array><string>ru</string></array>
  <key>CFBundleShortVersionString</key><string>0.3.2</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Waypoint читает адрес открытой вкладки браузера, чтобы предложить направить этот сайт через VPN или напрямую.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for a local build (no Developer ID needed).
xattr -cr "$APP" 2>/dev/null || true   # Finder/iCloud attributes make codesign refuse the bundle
codesign --force --sign - --identifier dev.waypoint.app "$APP"
echo "Готово: $APP  и  build/waypoint"
