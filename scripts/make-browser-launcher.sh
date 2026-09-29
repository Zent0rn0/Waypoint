#!/bin/bash
# Creates ~/Applications/<Browser> via Waypoint.app: starts Waypoint if needed, then launches a Chromium-based
# browser with --proxy-pac-url (system PAC is ignored while a full-tunnel VPN such as Happ is the primary service).
# Works for Chromium-based browsers and Electron apps (Cursor, Obsidian, …); native apps ignore the flag.
# Usage: scripts/make-browser-launcher.sh [AppName]   (default: Comet)
set -euo pipefail
BROWSER="${1:-Comet}"
SRC="/Applications/$BROWSER.app"
[ -d "$SRC" ] || { echo "Не найден $SRC"; exit 1; }
EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SRC/Contents/Info.plist")"
APP="$HOME/Applications/$BROWSER via Waypoint.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ICON="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$SRC/Contents/Info.plist" 2>/dev/null || true)"
ICON="${ICON%.icns}"
[ -n "$ICON" ] && [ -f "$SRC/Contents/Resources/$ICON.icns" ] && cp "$SRC/Contents/Resources/$ICON.icns" "$APP/Contents/Resources/icon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$BROWSER via Waypoint</string>
  <key>CFBundleIdentifier</key><string>dev.waypoint.launcher.$(echo "$BROWSER" | tr -cd 'A-Za-z0-9')</string>
  <key>CFBundleExecutable</key><string>launch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

cat > "$APP/Contents/MacOS/launch" <<SH
#!/bin/bash
BROWSER="$BROWSER"
EXE="$EXE"
PORT="\$(grep -o '"listenPort" *: *[0-9]*' "\$HOME/Library/Application Support/Waypoint/settings.json" 2>/dev/null | grep -o '[0-9]*\$')"
PORT="\${PORT:-7810}"
if pgrep -x "\$EXE" >/dev/null; then
  osascript -e "display dialog \"\$BROWSER уже запущен. Закройте его полностью (⌘Q) и откройте снова через этот ярлык: флаг прокси применяется только при запуске.\" buttons {\"OK\"} default button 1 with icon caution"
  exit 0
fi
pgrep -f "Waypoint.app/Contents/MacOS/Waypoint" >/dev/null || open -a "\$HOME/Applications/Waypoint.app"
for i in \$(seq 1 30); do nc -z 127.0.0.1 "\$PORT" 2>/dev/null && break; sleep 0.3; done
exec open -a "\$BROWSER" --args --proxy-pac-url="http://127.0.0.1:\$PORT/proxy.pac"
SH
chmod +x "$APP/Contents/MacOS/launch"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Готово: $APP"
