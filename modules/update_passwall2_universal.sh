#!/bin/sh

# Universal PassWall2 updater for OpenWrt 24.10 (opkg) and 25.12+ (apk)
# Customized for frenzydrive/openwrt-scripts

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
NC='\033[0m'

BASE_URL='https://master.dl.sourceforge.net/project/openwrt-passwall-build'
MOD_ZIP_URL='https://raw.githubusercontent.com/frenzydrive/openwrt-scripts/main/assets/passwall2/mod.zip'

PASSWALL_PKG='luci-app-passwall2'
PASSWALL_I18N_PKG='luci-i18n-passwall2-ru'

say() { printf '%b\n' "$1"; }
info() { say "${GREEN}$*${NC}"; }
warn() { say "${YELLOW}$*${NC}"; }
err()  { say "${RED}$*${NC}" >&2; }

cleanup() {
    rm -f /tmp/passwall2-mod.zip /tmp/openwrt-passwall-build.pub
}
trap cleanup EXIT INT TERM

[ "$(id -u)" = '0' ] || {
    err 'This script must be run as root.'
    exit 1
}

[ -r /etc/openwrt_release ] || {
    err '/etc/openwrt_release not found. This does not look like OpenWrt.'
    exit 1
}

# shellcheck disable=SC1091
. /etc/openwrt_release

OPENWRT_RELEASE="${DISTRIB_RELEASE:-unknown}"
OPENWRT_ARCH="${DISTRIB_ARCH:-}"

[ -n "$OPENWRT_ARCH" ] || {
    err 'Failed to detect OpenWrt architecture.'
    exit 1
}

if command -v apk >/dev/null 2>&1; then
    PKG_MANAGER='apk'
elif command -v opkg >/dev/null 2>&1; then
    PKG_MANAGER='opkg'
else
    err 'Neither apk nor opkg was found.'
    exit 1
fi

if [ "$OPENWRT_RELEASE" = 'SNAPSHOT' ]; then
    BUILD_KIND='snapshot'
    RELEASE_BRANCH='SNAPSHOT'
else
    BUILD_KIND='release'
    RELEASE_BRANCH="${OPENWRT_RELEASE%.*}"
fi

info "OpenWrt: ${OPENWRT_RELEASE}"
info "Architecture: ${OPENWRT_ARCH}"
info "Package manager: ${PKG_MANAGER}"

ask_yes_no() {
    prompt="$1"
    while true; do
        printf '%b%s [y/n]: %b' "$YELLOW" "$prompt" "$NC"
        read -r ans
        case "$ans" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO) return 1 ;;
            *) say 'Please answer y or n.' ;;
        esac
    done
}

is_passwall_installed() {
    [ -x /etc/init.d/passwall2 ] && return 0

    if [ "$PKG_MANAGER" = 'apk' ]; then
        apk list -I "$PASSWALL_PKG" 2>/dev/null | grep -q "^${PASSWALL_PKG}-" && return 0
    else
        opkg status "$PASSWALL_PKG" >/dev/null 2>&1 && return 0
    fi

    return 1
}

configure_opkg_feeds() {
    FEED_FILE='/etc/opkg/customfeeds.conf'
    mkdir -p /etc/opkg
    touch "$FEED_FILE"

    info 'Installing/updating PassWall repository key (opkg)...'
    wget -q -O /tmp/openwrt-passwall-build.pub "$BASE_URL/ipk.pub" || {
        err 'Failed to download the PassWall opkg public key.'
        return 1
    }
    opkg-key add /tmp/openwrt-passwall-build.pub >/dev/null 2>&1 || {
        err 'Failed to add the PassWall opkg public key.'
        return 1
    }

    # Keep unrelated custom feeds; remove only old PassWall build feed entries.
    sed -i \
        -e '/openwrt-passwall-build/d' \
        -e '/^[[:space:]]*src\/gz[[:space:]]\+passwall_luci[[:space:]]/d' \
        -e '/^[[:space:]]*src\/gz[[:space:]]\+passwall_packages[[:space:]]/d' \
        -e '/^[[:space:]]*src\/gz[[:space:]]\+passwall2[[:space:]]/d' \
        "$FEED_FILE"

    if [ "$BUILD_KIND" = 'snapshot' ]; then
        FEED_BASE="$BASE_URL/snapshots/packages/$OPENWRT_ARCH"
    else
        FEED_BASE="$BASE_URL/releases/packages-$RELEASE_BRANCH/$OPENWRT_ARCH"
    fi

    for feed in passwall_luci passwall_packages passwall2; do
        printf 'src/gz %s %s/%s\n' "$feed" "$FEED_BASE" "$feed" >> "$FEED_FILE"
    done
}

configure_apk_feeds() {
    FEED_DIR='/etc/apk/repositories.d'
    FEED_FILE="$FEED_DIR/customfeeds.list"
    KEY_DIR='/etc/apk/keys'

    mkdir -p "$FEED_DIR" "$KEY_DIR"
    touch "$FEED_FILE"

    info 'Installing/updating PassWall repository key (apk)...'
    wget -q -O "$KEY_DIR/openwrt-passwall-build.pem" "$BASE_URL/apk.pub" || {
        err 'Failed to download the PassWall apk public key.'
        return 1
    }

    # Keep unrelated custom feeds; remove only old PassWall build feed entries.
    sed -i '/openwrt-passwall-build/d' "$FEED_FILE"

    if [ "$BUILD_KIND" = 'snapshot' ]; then
        FEED_BASE="$BASE_URL/snapshots/packages/$OPENWRT_ARCH"
    else
        FEED_BASE="$BASE_URL/releases/packages-$RELEASE_BRANCH/$OPENWRT_ARCH"
    fi

    for feed in passwall_luci passwall_packages passwall2; do
        printf '%s/%s/packages.adb\n' "$FEED_BASE" "$feed" >> "$FEED_FILE"
    done
}

configure_passwall_feeds() {
    if [ "$PKG_MANAGER" = 'apk' ]; then
        configure_apk_feeds
    else
        configure_opkg_feeds
    fi
}

ensure_unzip() {
    command -v unzip >/dev/null 2>&1 && return 0

    info 'Installing unzip...'
    if [ "$PKG_MANAGER" = 'apk' ]; then
        apk add unzip
    else
        opkg install unzip
    fi
}

install_or_update_passwall() {
    info 'Updating package lists...'

    if [ "$PKG_MANAGER" = 'apk' ]; then
        apk update || return 1
        info 'Installing/updating PassWall2 and Russian translation...'
        # --upgrade upgrades only the explicitly requested packages and required dependencies,
        # not the entire OpenWrt system.
        apk add --upgrade "$PASSWALL_PKG" "$PASSWALL_I18N_PKG" || return 1
    else
        opkg update || return 1
        info 'Installing/updating PassWall2 and Russian translation...'
        opkg install "$PASSWALL_PKG" "$PASSWALL_I18N_PKG" || return 1
    fi

    return 0
}

apply_mod_files() {
    ensure_unzip || return 1

    info 'Downloading customized PassWall2 interface files...'
    rm -f /tmp/passwall2-mod.zip

    wget -q -O /tmp/passwall2-mod.zip "$MOD_ZIP_URL" || {
        err 'Failed to download mod.zip.'
        return 1
    }

    info 'Applying customized PassWall2 icons/files...'
    unzip -o /tmp/passwall2-mod.zip -d / >/dev/null || {
        err 'Failed to unpack mod.zip.'
        return 1
    }

    return 0
}

apply_post_update_settings() {
    info 'Applying post-update settings...'

    uci set system.@system[0].zonename='Europe/Moscow'
    uci set system.@system[0].timezone='MSK-3'

    # Keep the same PassWall2 settings used by the original updater.
    uci set passwall2.@global_forwarding[0]=global_forwarding
    uci -q delete passwall2.@global_forwarding[0].tcp_no_redir_ports
    uci -q delete passwall2.@global_forwarding[0].udp_no_redir_ports
    uci set passwall2.@global_forwarding[0].tcp_redir_ports='1:65535'
    uci set passwall2.@global_forwarding[0].udp_redir_ports='1:65535'
    uci set passwall2.@global[0].remote_dns='8.8.4.4'

    uci set passwall2.Russia=shunt_rules
    uci set passwall2.Russia.network='tcp,udp'
    uci set passwall2.Russia.remarks='Russia'
    uci set passwall2.Russia.domain_list='geosite:category-ru'
    uci set passwall2.Russia.ip_list='geoip:ru'
    uci set passwall2.rulenode.Russia='_direct'

    uci commit passwall2 || return 1
    uci commit system || return 1
    /sbin/reload_config >/dev/null 2>&1 || true

    return 0
}

restart_passwall() {
    if [ -x /etc/init.d/passwall2 ]; then
        info 'Restarting PassWall2...'
        /etc/init.d/passwall2 restart || {
            warn 'PassWall2 was updated, but the service restart returned an error.'
            return 0
        }
    fi
}

configure_passwall_feeds || {
    err 'Failed to configure PassWall repositories.'
    exit 1
}

if ! is_passwall_installed; then
    warn 'PassWall2 is not currently installed on this router.'
    if ! ask_yes_no 'Install PassWall2 now?'; then
        warn 'Operation cancelled.'
        exit 0
    fi
fi

install_or_update_passwall || {
    err 'Failed to install/update PassWall2.'
    exit 1
}

[ -x /etc/init.d/passwall2 ] || {
    err 'PassWall2 package operation completed, but /etc/init.d/passwall2 was not found.'
    exit 1
}

apply_mod_files || {
    err 'PassWall2 was updated, but the custom mod.zip could not be applied.'
    exit 1
}

apply_post_update_settings || {
    err 'PassWall2 was updated and mod.zip was applied, but post-update UCI settings failed.'
    exit 1
}

restart_passwall

say "${YELLOW}** PassWall2 update completed successfully **${NC}"
say "${MAGENTA}Customized for frenzydrive/openwrt-scripts${NC}"
exit 0
