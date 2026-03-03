#!/bin/sh
set -eu

REPO="https://raw.githubusercontent.com/frenzydrive/openwrt-scripts/main/assets/argon-config"
TMP="/tmp/argon-install"

log() { echo "[argon] $*"; }
die() { echo "[argon][ERROR] $*" >&2; exit 1; }

is_installed() {
  # match exact package name at line start
  opkg list-installed 2>/dev/null | grep -q "^$1 "
}

install_if_missing() {
  pkg="$1"
  if is_installed "$pkg"; then
    log "Already installed: $pkg"
  else
    log "Installing: $pkg"
    opkg install "$pkg" >/dev/null
  fi
}

restart_luci() {
  log "Restarting LuCI..."
  rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
  /etc/init.d/rpcd restart >/dev/null 2>&1 || true
  /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
}

ensure_menu() {
  MENU="/usr/share/luci/menu.d/luci-app-argon-config.json"
  if [ ! -f "$MENU" ]; then
    log "Creating missing menu entry: $MENU"
    mkdir -p /usr/share/luci/menu.d
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
}

# --- main ---

# 0) LuCI sanity
if ! is_installed luci-base; then
  die "LuCI (luci-base) is not installed. Install LuCI first, then run this script."
fi

mkdir -p "$TMP"
cd "$TMP"

log "Updating opkg..."
opkg update >/dev/null

# 1) Dependencies needed for GitHub HTTPS + argon-config page
install_if_missing ca-bundle
install_if_missing luci-lib-ipkg

# 2) If already installed, don't reinstall
if is_installed luci-theme-argon && is_installed luci-app-argon-config; then
  log "Argon theme + Argon Config already installed. Skipping download/install."
  ensure_menu
  restart_luci
  log "Done. Open LuCI → System → Argon Config"
  exit 0
fi

log "Downloading Argon packages from your repository..."

THEME_IPK="luci-theme-argon_2.4.3-r20250722_all.ipk"
APP_IPK="luci-app-argon-config_0.9_all.ipk"
RU_IPK="luci-i18n-argon-config-ru_0.9_all.ipk"

# download only what is missing
if ! is_installed luci-theme-argon; then
  wget -q -O "$THEME_IPK" "$REPO/$THEME_IPK"
fi

if ! is_installed luci-app-argon-config; then
  wget -q -O "$APP_IPK" "$REPO/$APP_IPK"
fi

# translation is optional
if ! is_installed luci-i18n-argon-config-ru; then
  wget -q -O "$RU_IPK" "$REPO/$RU_IPK" 2>/dev/null || true
fi

log "Installing packages..."
# install only files that actually exist (were downloaded)
[ -f "$THEME_IPK" ] && opkg install "./$THEME_IPK" >/dev/null || true
[ -f "$APP_IPK" ] && opkg install "./$APP_IPK" >/dev/null || true
[ -f "$RU_IPK" ] && opkg install "./$RU_IPK" >/dev/null || true

ensure_menu
restart_luci

log "Done. Open LuCI → System → Argon Config"
