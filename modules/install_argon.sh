#!/bin/sh
set -eu

REPO="https://raw.githubusercontent.com/frenzydrive/openwrt-scripts/main/assets/argon-config"
TMP="/tmp/argon-install"

log() { echo "[argon] $*"; }

mkdir -p "$TMP"
cd "$TMP"

log "Updating opkg..."
opkg update >/dev/null

log "Installing required dependency..."
opkg install luci-lib-ipkg ca-bundle >/dev/null 2>&1 || true

log "Downloading Argon packages from your repository..."

wget -q "$REPO/luci-theme-argon_2.4.3-r20250722_all.ipk"
wget -q "$REPO/luci-app-argon-config_0.9_all.ipk"
wget -q "$REPO/luci-i18n-argon-config-ru_0.9_all.ipk" 2>/dev/null || true

log "Installing packages..."
opkg install ./*.ipk

# Ensure LuCI menu exists (safety net)
MENU="/usr/share/luci/menu.d/luci-app-argon-config.json"
if [ ! -f "$MENU" ]; then
cat > "$MENU" <<'EOF'
{
  "admin/system/argon-config": {
    "title": "Argon Config",
    "order": 60,
    "action": {
      "type": "view",
      "path": "argon-config"
    }
  }
}
EOF
fi

log "Restarting LuCI..."
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart

log "Done. Open LuCI → System → Argon Config"
