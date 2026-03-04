#!/bin/sh
set -eu

REPO_RAW="https://raw.githubusercontent.com/frenzydrive/openwrt-scripts/main"
ASSET_PATH="assets/vpn-switch/10-vpn-switch"

DST_DIR="/etc/hotplug.d/button"
DST_FILE="10-vpn-switch"
DST="$DST_DIR/$DST_FILE"

TMP="/tmp/openwrt-scripts-vpn-switch"

log() { echo "[vpn-switch] $*"; }
die() { echo "[vpn-switch][ERROR] $*" >&2; exit 1; }

# --- main ---

mkdir -p "$TMP"
mkdir -p "$DST_DIR"

log "Downloading: $ASSET_PATH"
wget -q -O "$TMP/$DST_FILE" "$REPO_RAW/$ASSET_PATH" || die "Download failed"

if [ -f "$DST" ]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  cp -f "$DST" "$DST.bak.$TS"
  log "Backup: $DST.bak.$TS"
fi

cp -f "$TMP/$DST_FILE" "$DST"
chmod 0755 "$DST"

log "Installed: $DST"
log "Tip: logread | grep vpn-switch"
