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

TMP_MOD='/tmp/passwall2-mod.zip'
TMP_OPKG_KEY='/tmp/openwrt-passwall-build.pub'
RESTART_LOG='/tmp/passwall2-restart.log'
CONFIG_BACKUP=''

say()  { printf '%b\n' "$1"; }
info() { say "${GREEN}$*${NC}"; }
warn() { say "${YELLOW}$*${NC}"; }
err()  { say "${RED}$*${NC}" >&2; }

cleanup() {
    rm -f "$TMP_MOD" "$TMP_OPKG_KEY"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
            n|N|no|NO)   return 1 ;;
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

    mkdir -p /etc/opkg || return 1
    touch "$FEED_FILE" || return 1

    info 'Installing/updating PassWall repository key (opkg)...'

    wget -q -O "$TMP_OPKG_KEY" "$BASE_URL/ipk.pub" || {
        err 'Failed to download the PassWall opkg public key.'
        return 1
    }

    opkg-key add "$TMP_OPKG_KEY" >/dev/null 2>&1 || {
        err 'Failed to add the PassWall opkg public key.'
        return 1
    }

    # Keep unrelated custom feeds; remove only old PassWall build feed entries.
    sed -i \
        -e '/openwrt-passwall-build/d' \
        -e '/^[[:space:]]*src\/gz[[:space:]]\+passwall_luci[[:space:]]/d' \
        -e '/^[[:space:]]*src\/gz[[:space:]]\+passwall_packages[[:space:]]/d' \
        -e '/^[[:space:]]*src\/gz[[:space:]]\+passwall2[[:space:]]/d' \
        "$FEED_FILE" || return 1

    if [ "$BUILD_KIND" = 'snapshot' ]; then
        FEED_BASE="$BASE_URL/snapshots/packages/$OPENWRT_ARCH"
    else
        FEED_BASE="$BASE_URL/releases/packages-$RELEASE_BRANCH/$OPENWRT_ARCH"
    fi

    for feed in passwall_luci passwall_packages passwall2; do
        printf 'src/gz %s %s/%s\n' "$feed" "$FEED_BASE" "$feed" >> "$FEED_FILE" || return 1
    done

    return 0
}

configure_apk_feeds() {
    FEED_DIR='/etc/apk/repositories.d'
    FEED_FILE="$FEED_DIR/customfeeds.list"
    KEY_DIR='/etc/apk/keys'

    mkdir -p "$FEED_DIR" "$KEY_DIR" || return 1
    touch "$FEED_FILE" || return 1

    info 'Installing/updating PassWall repository key (apk)...'

    wget -q -O "$KEY_DIR/openwrt-passwall-build.pem" "$BASE_URL/apk.pub" || {
        err 'Failed to download the PassWall apk public key.'
        return 1
    }

    # Keep unrelated custom feeds; remove only old PassWall build feed entries.
    sed -i '/openwrt-passwall-build/d' "$FEED_FILE" || return 1

    if [ "$BUILD_KIND" = 'snapshot' ]; then
        FEED_BASE="$BASE_URL/snapshots/packages/$OPENWRT_ARCH"
    else
        FEED_BASE="$BASE_URL/releases/packages-$RELEASE_BRANCH/$OPENWRT_ARCH"
    fi

    for feed in passwall_luci passwall_packages passwall2; do
        printf '%s/%s/packages.adb\n' "$FEED_BASE" "$feed" >> "$FEED_FILE" || return 1
    done

    return 0
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

backup_passwall_config() {
    [ -f /etc/config/passwall2 ] || return 0

    stamp="$(date '+%Y%m%d-%H%M%S' 2>/dev/null)"
    [ -n "$stamp" ] || stamp='unknown-time'

    CONFIG_BACKUP="/root/passwall2-config-before-update-${stamp}"

    cp -p /etc/config/passwall2 "$CONFIG_BACKUP" || {
        err 'Failed to back up /etc/config/passwall2.'
        return 1
    }

    info "PassWall2 config backup: ${CONFIG_BACKUP}"
    return 0
}

normalize_legacy_no_redir_ports() {
    [ -f /etc/config/passwall2 ] || return 0

    changed=0

    tcp_no_redir="$(uci -q get passwall2.@global_forwarding[0].tcp_no_redir_ports 2>/dev/null)"
    udp_no_redir="$(uci -q get passwall2.@global_forwarding[0].udp_no_redir_ports 2>/dev/null)"

    if [ "$tcp_no_redir" = 'disable' ]; then
        info 'Normalizing legacy TCP no-redir value "disable"...'
        uci -q delete passwall2.@global_forwarding[0].tcp_no_redir_ports || return 1
        changed=1
    fi

    if [ "$udp_no_redir" = 'disable' ]; then
        info 'Normalizing legacy UDP no-redir value "disable"...'
        uci -q delete passwall2.@global_forwarding[0].udp_no_redir_ports || return 1
        changed=1
    fi

    if [ "$changed" = '1' ]; then
        uci commit passwall2 || {
            err 'Failed to save normalized PassWall2 no-redir settings.'
            return 1
        }
    fi

    return 0
}

normalize_acl_sources() {
    [ -f /etc/config/passwall2 ] || return 0
    command -v lua >/dev/null 2>&1 || {
        warn 'Lua is not available; ACL sources compatibility check was skipped.'
        return 0
    }

    lua <<'LUA'
local uci = require("luci.model.uci").cursor()
local changed = false

uci:foreach("passwall2", "acl_rule", function(s)
    local sources = s.sources

    if type(sources) == "string" then
        local values = {}

        for item in sources:gmatch("%S+") do
            values[#values + 1] = item
        end

        local ok, err

        if #values > 0 then
            ok, err = uci:set_list("passwall2", s[".name"], "sources", values)
        else
            ok, err = uci:delete("passwall2", s[".name"], "sources")
        end

        if not ok then
            io.stderr:write(
                string.format(
                    "Failed to normalize ACL sources for %s: %s\n",
                    tostring(s[".name"]),
                    tostring(err)
                )
            )
            os.exit(1)
        end

        io.write(
            string.format(
                "Normalized ACL %s: %d source entries\n",
                tostring(s[".name"]),
                #values
            )
        )

        changed = true
    end
end)

if changed then
    local ok, err = uci:commit("passwall2")
    if not ok then
        io.stderr:write("Failed to commit normalized ACL sources: " .. tostring(err) .. "\n")
        os.exit(1)
    end
end
LUA
}

pre_update_compat_fix() {
    normalize_legacy_no_redir_ports || return 1
    normalize_acl_sources || return 1
    return 0
}

install_or_update_passwall() {
    info 'Updating package lists...'

    if [ "$PKG_MANAGER" = 'apk' ]; then
        apk update || return 1

        info 'Installing/updating PassWall2 and Russian translation...'

        # --upgrade upgrades explicitly requested packages and dependencies
        # required by them; it does not run a full system-wide apk upgrade.
        apk add --upgrade "$PASSWALL_PKG" "$PASSWALL_I18N_PKG" || return 1
    else
        opkg update || return 1

        info 'Installing/updating PassWall2 and Russian translation...'
        opkg install "$PASSWALL_PKG" "$PASSWALL_I18N_PKG" || return 1
    fi

    return 0
}

post_package_compat_fix() {
    # Run again because a package upgrade can migrate/rewrite UCI values.
    normalize_legacy_no_redir_ports || return 1
    normalize_acl_sources || return 1
    return 0
}

apply_mod_files() {
    ensure_unzip || return 1

    info 'Downloading customized PassWall2 interface files...'
    rm -f "$TMP_MOD"

    wget -q -O "$TMP_MOD" "$MOD_ZIP_URL" || {
        err 'Failed to download mod.zip.'
        return 1
    }

    info 'Applying customized PassWall2 icons/files...'

    unzip -o "$TMP_MOD" -d / >/dev/null || {
        err 'Failed to unpack mod.zip.'
        return 1
    }

    return 0
}

ensure_passwall_base_sections() {
    uci -q get passwall2.@global[0] >/dev/null 2>&1 || {
        uci add passwall2 global >/dev/null || return 1
    }

    uci -q get passwall2.@global_forwarding[0] >/dev/null 2>&1 || {
        uci add passwall2 global_forwarding >/dev/null || return 1
    }

    return 0
}

apply_post_update_settings() {
    info 'Applying post-update settings...'

    ensure_passwall_base_sections || {
        err 'Failed to ensure required PassWall2 UCI sections.'
        return 1
    }

    # Keep the same router settings used by the original updater.
    uci set system.@system[0].zonename='Europe/Moscow' || return 1
    uci set system.@system[0].timezone='MSK-3' || return 1

    # Redirect all TCP/UDP ports unless the user has configured specific
    # no-redir port exclusions. Legacy sentinel "disable" is handled separately.
    uci set passwall2.@global_forwarding[0].tcp_redir_ports='1:65535' || return 1
    uci set passwall2.@global_forwarding[0].udp_redir_ports='1:65535' || return 1

    uci set passwall2.@global[0].remote_dns='8.8.4.4' || return 1

    # Custom Russia shunt rule.
    uci set passwall2.Russia=shunt_rules || return 1
    uci set passwall2.Russia.network='tcp,udp' || return 1
    uci set passwall2.Russia.remarks='Russia' || return 1
    uci set passwall2.Russia.domain_list='geosite:category-ru' || return 1
    uci set passwall2.Russia.ip_list='geoip:ru' || return 1

    if uci -q get passwall2.rulenode >/dev/null 2>&1; then
        uci set passwall2.rulenode.Russia='_direct' || return 1
    else
        warn 'PassWall2 node "rulenode" was not found; Russia shunt binding was skipped.'
    fi

    uci commit passwall2 || return 1
    uci commit system || return 1

    /sbin/reload_config >/dev/null 2>&1 || true

    return 0
}

validate_passwall_config() {
    tcp_no_redir="$(uci -q get passwall2.@global_forwarding[0].tcp_no_redir_ports 2>/dev/null)"
    udp_no_redir="$(uci -q get passwall2.@global_forwarding[0].udp_no_redir_ports 2>/dev/null)"

    if [ "$tcp_no_redir" = 'disable' ] || [ "$udp_no_redir" = 'disable' ]; then
        err 'Legacy no-redir value "disable" is still present in PassWall2 config.'
        return 1
    fi

    command -v lua >/dev/null 2>&1 || return 0

    lua <<'LUA'
local uci = require("luci.model.uci").cursor()
local broken = false

uci:foreach("passwall2", "acl_rule", function(s)
    if type(s.sources) == "string" then
        io.stderr:write(
            string.format(
                "ACL %s still has multiple sources stored as one string\n",
                tostring(s[".name"])
            )
        )
        broken = true
    end
end)

if broken then
    os.exit(1)
end
LUA
}

restart_passwall() {
    [ -x /etc/init.d/passwall2 ] || {
        err '/etc/init.d/passwall2 was not found.'
        return 1
    }

    info 'Restarting PassWall2...'
    rm -f "$RESTART_LOG"

    /etc/init.d/passwall2 restart >"$RESTART_LOG" 2>&1
    rc=$?

    [ -s "$RESTART_LOG" ] && cat "$RESTART_LOG"

    if [ "$rc" -ne 0 ]; then
        err "PassWall2 restart failed with exit code ${rc}."
        err "Restart log: ${RESTART_LOG}"
        return 1
    fi

    if grep -Eiq \
        "Could not resolve service: Unrecognized service|dport[[:space:]]+\{disable\}|bad argument #1 to 'ipairs'|Failed to parse JSON data|stack traceback:" \
        "$RESTART_LOG" 2>/dev/null; then
        err 'PassWall2 restart produced a known fatal compatibility error.'
        err "Restart log: ${RESTART_LOG}"
        return 1
    fi

    return 0
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

backup_passwall_config || {
    err 'Update aborted because the current PassWall2 config could not be backed up.'
    exit 1
}

pre_update_compat_fix || {
    err 'Failed to apply pre-update PassWall2 compatibility fixes.'
    [ -n "$CONFIG_BACKUP" ] && err "Backup: ${CONFIG_BACKUP}"
    exit 1
}

install_or_update_passwall || {
    err 'Failed to install/update PassWall2.'
    [ -n "$CONFIG_BACKUP" ] && err "Backup: ${CONFIG_BACKUP}"
    exit 1
}

[ -x /etc/init.d/passwall2 ] || {
    err 'PassWall2 package operation completed, but /etc/init.d/passwall2 was not found.'
    [ -n "$CONFIG_BACKUP" ] && err "Backup: ${CONFIG_BACKUP}"
    exit 1
}

post_package_compat_fix || {
    err 'PassWall2 was updated, but configuration compatibility normalization failed.'
    [ -n "$CONFIG_BACKUP" ] && err "Backup: ${CONFIG_BACKUP}"
    exit 1
}

apply_mod_files || {
    err 'PassWall2 was updated, but the custom mod.zip could not be applied.'
    [ -n "$CONFIG_BACKUP" ] && err "Backup: ${CONFIG_BACKUP}"
    exit 1
}

apply_post_update_settings || {
    err 'PassWall2 was updated and mod.zip was applied, but post-update UCI settings failed.'
    [ -n "$CONFIG_BACKUP" ] && err "Backup: ${CONFIG_BACKUP}"
    exit 1
}

# One final normalization after all UCI writes.
post_package_compat_fix || {
    err 'Final PassWall2 compatibility normalization failed.'
    [ -n "$CONFIG_BACKUP" ] && err "Backup: ${CONFIG_BACKUP}"
    exit 1
}

validate_passwall_config || {
    err 'PassWall2 configuration validation failed.'
    [ -n "$CONFIG_BACKUP" ] && err "Backup: ${CONFIG_BACKUP}"
    exit 1
}

restart_passwall || {
    err 'PassWall2 update finished, but the service did not restart cleanly.'
    [ -n "$CONFIG_BACKUP" ] && err "Backup: ${CONFIG_BACKUP}"
    exit 1
}

say "${YELLOW}** PassWall2 update completed successfully **${NC}"
say "${MAGENTA}Customized for frenzydrive/openwrt-scripts${NC}"

[ -n "$CONFIG_BACKUP" ] && info "Backup kept at: ${CONFIG_BACKUP}"

exit 0
