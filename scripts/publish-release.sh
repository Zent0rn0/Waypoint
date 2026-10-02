#!/bin/bash
# Publishes build/ files as a GitHub release for the given tag, using the credential git already has for github.com
# (the token is passed to curl through a private header file and never printed). Usage: scripts/publish-release.sh v0.3.0
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:?tag}"; V="${TAG#v}"; REPO="Zent0rn0/Waypoint"
H="$(mktemp)"; chmod 600 "$H"; trap 'rm -f "$H"' EXIT
TOKEN="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill | sed -n 's/^password=//p')"
[ -n "$TOKEN" ] || { echo "нет сохранённого доступа к github.com"; exit 1; }
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$H"; unset TOKEN
api() { curl -sS -H @"$H" -H "Accept: application/vnd.github+json" "$@"; }
BODY="$(python3 -c 'import json,sys; print(json.dumps({"tag_name":sys.argv[1],"name":"Waypoint "+sys.argv[2],"body":open("build/RELEASE_NOTES.md").read()}))' "$TAG" "$V")"
ID="$(api "https://api.github.com/repos/$REPO/releases/tags/$TAG" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
if [ -z "$ID" ]; then ID="$(api -X POST "https://api.github.com/repos/$REPO/releases" -d "$BODY" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id") or sys.exit(str(d)))')"
else api -X PATCH "https://api.github.com/repos/$REPO/releases/$ID" -d "$BODY" >/dev/null; fi
for f in "build/Waypoint-$V-macos-arm64.dmg" "build/Waypoint-$V-macos-arm64.zip" build/SHA256SUMS; do
  n="$(basename "$f")"
  api -X POST -H "Content-Type: application/octet-stream" --data-binary @"$f" "https://uploads.github.com/repos/$REPO/releases/$ID/assets?name=$n" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("uploaded:", d.get("name") or d)'
done
