#!/bin/bash
# Downloads the two helper engines Waypoint runs as separate processes, straight from their official releases,
# and refuses anything whose SHA-256 differs from the pinned values (archive first, then the extracted binary).
#   sing-box  — the tunnel (TUN, rules, server pools)          github.com/SagerNet/sing-box
#   Xray-core — carries the server types sing-box cannot dial   github.com/XTLS/Xray-core
# Usage: scripts/fetch-vendor.sh        (Apple Silicon Macs; run once, before scripts/bundle.sh)
set -euo pipefail
cd "$(dirname "$0")/.."

SB_VER="1.14.2"
SB_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-darwin-arm64.tar.gz"
SB_ARCHIVE_SHA="925c5382eca8492b0150f868a6db20b18290a38700e621724b3703fd453e032d"
SB_BIN_SHA="d652879eed7e38b866fa980bc2e119dcdb13968fe5e6583670293a258686d0e7"

XR_VER="26.3.27"
XR_URL="https://github.com/XTLS/Xray-core/releases/download/v${XR_VER}/Xray-macos-arm64-v8a.zip"
XR_ARCHIVE_SHA="2e93a67e8aa1936ecefb307e120830fcbd4c643ab9b1c46a2d0838d5f8409eaf"
XR_BIN_SHA="5d9dd24c0aba4b6cfcc6a33a5d67f854816ee17f392bf932ec8176da46f7e404"

[ "$(uname -m)" = "arm64" ] || { echo "Only Apple Silicon is pinned here; add the darwin-amd64 hashes to build for Intel." >&2; exit 1; }

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
check() { [ "$(sha "$1")" = "$2" ] || { echo "SHA-256 mismatch for $3 — refusing to use it." >&2; exit 1; }; }

mkdir -p vendor
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if [ -x vendor/sing-box ] && [ "$(sha vendor/sing-box)" = "$SB_BIN_SHA" ]; then echo "sing-box ${SB_VER}: already present"; else
  echo "sing-box ${SB_VER}: downloading…"
  curl -fL --proto '=https' -o "$TMP/sb.tgz" "$SB_URL"
  check "$TMP/sb.tgz" "$SB_ARCHIVE_SHA" "the sing-box archive"
  tar -xzf "$TMP/sb.tgz" -C "$TMP"
  install -m 755 "$TMP"/sing-box-*/sing-box vendor/sing-box
  cp "$TMP"/sing-box-*/LICENSE vendor/sing-box.LICENSE 2>/dev/null || true
  check vendor/sing-box "$SB_BIN_SHA" "the sing-box binary"
fi

if [ -x vendor/xray ] && [ "$(sha vendor/xray)" = "$XR_BIN_SHA" ]; then echo "Xray ${XR_VER}: already present"; else
  echo "Xray ${XR_VER}: downloading…"
  curl -fL --proto '=https' -o "$TMP/xr.zip" "$XR_URL"
  check "$TMP/xr.zip" "$XR_ARCHIVE_SHA" "the Xray archive"
  unzip -q -o "$TMP/xr.zip" -d "$TMP/xr"
  install -m 755 "$TMP/xr/xray" vendor/xray
  cp "$TMP/xr/LICENSE" vendor/xray.LICENSE 2>/dev/null || true
  check vendor/xray "$XR_BIN_SHA" "the Xray binary"
fi
echo "vendor/ is ready."
