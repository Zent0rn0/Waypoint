#!/bin/bash
# Removes the tunnel daemon completely. Terminal: scripts/uninstall-daemon.sh (asks for your password via sudo).
# From the app it is run through the macOS administrator prompt (extra --user/--payload arguments are ignored).
set -euo pipefail
if [ "$(id -u)" != 0 ]; then exec sudo "$0"; fi
launchctl bootout system/dev.waypoint.daemon 2>/dev/null || true     # stops sing-box; the TUN and its routes vanish with it
rm -f /Library/LaunchDaemons/dev.waypoint.daemon.plist
rm -rf /usr/local/libexec/waypoint /var/db/waypoint
echo "Демон удалён, туннель остановлен, маршруты вернулись в обычное состояние."
