#!/bin/bash
# Installs the Waypoint tunnel daemon (LaunchDaemon, runs as root).
#   From a terminal:   scripts/install-daemon.sh                     (asks for your password via sudo)
#   From the app:      install-daemon.sh --payload <Resources> --user <name>   (run through the macOS administrator prompt)
# The daemon starts with the tunnel OFF; it only does something after `waypoint tunnel on` / the app's switch.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
USER_NAME=""; WP=""; SBX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_NAME="$2"; shift 2 ;;
    --payload) WP="$2/waypoint"; SBX="$2/sing-box"; shift 2 ;;
    --wp) WP="$2"; shift 2 ;;
    --sb) SBX="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$WP" ] || WP="$HERE/../build/waypoint"
[ -n "$SBX" ] || SBX="$HERE/../vendor/sing-box"
if [ "$(id -u)" != 0 ]; then exec sudo "$0" --user "${USER_NAME:-$(id -un)}" --wp "$WP" --sb "$SBX"; fi
USER_NAME="${USER_NAME:-${SUDO_USER:?run via sudo from your own account}}"
HOME_DIR="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')"
SUPPORT="$HOME_DIR/Library/Application Support/Waypoint"
EXPECTED="d652879eed7e38b866fa980bc2e119dcdb13968fe5e6583670293a258686d0e7"

[ -x "$WP" ] || { echo "Нет $WP — сначала выполните scripts/bundle.sh"; exit 1; }
[ -x "$SBX" ] || { echo "Нет $SBX"; exit 1; }
ACTUAL="$(shasum -a 256 "$SBX" | cut -d' ' -f1)"
[ "$ACTUAL" = "$EXPECTED" ] || { echo "Контрольная сумма sing-box не совпала — отказываюсь ставить."; exit 1; }

install -d -m 755 -o root -g wheel /usr/local/libexec/waypoint /var/db/waypoint
install -m 755 -o root -g wheel "$WP" /usr/local/libexec/waypoint/waypoint
install -m 755 -o root -g wheel "$SBX" /usr/local/libexec/waypoint/sing-box
install -d -m 755 -o "$USER_NAME" "$SUPPORT"
xattr -c /usr/local/libexec/waypoint/waypoint /usr/local/libexec/waypoint/sing-box 2>/dev/null || true

PLIST=/Library/LaunchDaemons/dev.waypoint.daemon.plist
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.waypoint.daemon</string>
  <key>ProgramArguments</key><array>
    <string>/usr/local/libexec/waypoint/waypoint</string><string>tunnel</string><string>daemon</string>
    <string>--home</string><string>$SUPPORT</string>
    <string>--sing-box</string><string>/usr/local/libexec/waypoint/sing-box</string>
    <string>--state</string><string>/var/db/waypoint</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/var/db/waypoint/daemon.log</string>
  <key>StandardOutPath</key><string>/var/db/waypoint/daemon.log</string>
</dict></plist>
PL
chown root:wheel "$PLIST"; chmod 644 "$PLIST"
launchctl bootout system/dev.waypoint.daemon 2>/dev/null || true
# bootout is asynchronous: wait until the old instance is really gone, otherwise bootstrap fails with "Input/output error"
for _ in $(seq 1 20); do launchctl print system/dev.waypoint.daemon >/dev/null 2>&1 || break; sleep 0.5; done
for attempt in 1 2 3 4 5; do
  launchctl bootstrap system "$PLIST" && break
  [ "$attempt" = 5 ] && { echo "Не удалось загрузить демон (launchctl bootstrap)"; exit 1; }
  sleep 1
done
echo "Готово. Демон установлен (туннель ВЫКЛЮЧЕН). Включить: переключатель «Туннель» в приложении или  waypoint tunnel on"
