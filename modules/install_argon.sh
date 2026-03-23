#!/bin/sh
set -eu

REPO="https://raw.githubusercontent.com/frenzydrive/openwrt-scripts/main/assets/argon-config"
TMP="/tmp/argon-install"
THEME_IPK="luci-theme-argon_2.4.3-r20250722_all.ipk"
APP_IPK="luci-app-argon-config_0.9_all.ipk"
RU_LMO="argon-config.ru.lmo"

log() {
    echo "[argon] $*"
}

warn() {
    echo "[argon][WARN] $*" >&2
}

die() {
    echo "[argon][ERROR] $*" >&2
    exit 1
}

is_installed() {
    opkg list-installed 2>/dev/null | grep -q "^$1 "
}

install_if_missing() {
    pkg="$1"
    if is_installed "$pkg"; then
        log "Already installed: $pkg"
    else
        log "Installing: $pkg"
        opkg install "$pkg" >/dev/null || die "Failed to install package: $pkg"
    fi
}

download_file() {
    file="$1"
    url="$2"

    log "Downloading: $file"
    if ! wget -q -O "$file" "$url"; then
        rm -f "$file"
        return 1
    fi

    [ -s "$file" ] || {
        rm -f "$file"
        return 1
    }

    return 0
}

install_ipk_if_present() {
    file="$1"
    pkg_desc="$2"

    if [ ! -f "$file" ]; then
        warn "File not found, skipping: $file"
        return 0
    fi

    log "Installing: $pkg_desc"
    if ! opkg install "./$file"; then
        warn "Failed to install $file"
        return 1
    fi

    return 0
}

install_translation_lmo() {
    if ! download_file "$RU_LMO" "$REPO/$RU_LMO"; then
        warn "Russian translation file not found in repository, skipping"
        return 0
    fi

    log "Installing Russian translation (.lmo)"
    mkdir -p /usr/lib/lua/luci/i18n
    cp -f "$RU_LMO" /usr/lib/lua/luci/i18n/argon-config.ru.lmo
    chmod 0644 /usr/lib/lua/luci/i18n/argon-config.ru.lmo
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

fix_postinst_defaults() {
    DEFAULTS_FILE="/etc/uci-defaults/luci-argon-config"

    if [ ! -f "$DEFAULTS_FILE" ]; then
        log "Creating missing postinst helper: $DEFAULTS_FILE"
        mkdir -p /etc/uci-defaults
        cat > "$DEFAULTS_FILE" <<'EOF'
#!/bin/sh
exit 0
EOF
        chmod +x "$DEFAULTS_FILE"
    fi
}

get_router_title() {
    local title

    title="$(cat /tmp/sysinfo/model 2>/dev/null || true)"
    [ -n "$title" ] || title="OpenWrt"

    title="$(printf '%s' "$title" | sed 's/[[:cntrl:]]//g; s/[[:space:]]\+/ /g; s/^ //; s/ $//')"

    printf '%s\n' "$title"
}

patch_argon_title() {
    local title
    local file
    local content
    local new_content

    title="$(get_router_title)"

    for file in \
        /usr/lib/lua/luci/view/themes/argon/header.htm \
        /usr/lib/lua/luci/view/themes/argon/header_login.htm
    do
        [ -f "$file" ] || continue

        content="$(cat "$file")"
        new_content="$(printf '%s\n' "$content" | sed "s#<title[^>]*>.*</title>#<title>${title}</title>#")"

        if [ "$content" != "$new_content" ]; then
            printf '%s\n' "$new_content" > "$file"
        fi
    done

    log "Browser tab title set to: $title"
}

restart_luci() {
    log "Restarting LuCI..."
    rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
    /etc/init.d/rpcd restart >/dev/null 2>&1 || true
    /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
}

# --- main ---

if ! is_installed luci-base; then
    die "LuCI (luci-base) is not installed.
Install LuCI first, then run this script."
fi

mkdir -p "$TMP"
cd "$TMP"

log "Updating opkg..."
opkg update >/dev/null || die "opkg update failed"

install_if_missing ca-bundle
install_if_missing luci-lib-ipkg
install_if_missing luci-compat

fix_postinst_defaults

if is_installed luci-theme-argon && is_installed luci-app-argon-config; then
    log "Argon theme + Argon Config already installed. Skipping package install."
    install_translation_lmo || true
    ensure_menu
    patch_argon_title
    restart_luci
    log "Done.
Open LuCI -> System -> Argon Config"
    exit 0
fi

if ! is_installed luci-theme-argon; then
    download_file "$THEME_IPK" "$REPO/$THEME_IPK" || die "Failed to download $THEME_IPK"
fi

if ! is_installed luci-app-argon-config; then
    download_file "$APP_IPK" "$REPO/$APP_IPK" || die "Failed to download $APP_IPK"
fi

log "Installing packages..."

if ! is_installed luci-theme-argon; then
    install_ipk_if_present "$THEME_IPK" "Argon theme" || die "Argon theme installation failed"
fi

if ! is_installed luci-app-argon-config; then
    install_ipk_if_present "$APP_IPK" "Argon Config app" || warn "Argon Config app installed with warnings"
fi

install_translation_lmo || true
ensure_menu
patch_argon_title
restart_luci

log "Done.
Open LuCI -> System -> Argon Config"
