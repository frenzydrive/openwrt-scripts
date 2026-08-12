#!/bin/sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
NC='\033[0m'

BASE_URL='https://master.dl.sourceforge.net/project/openwrt-passwall-build'
MOD_ZIP_URL='https://raw.githubusercontent.com/frenzydrive/openwrt-scripts/main/assets/passwall2/mod.zip'

RETRY_COUNT=5
RETRY_DELAY=3

info()  { printf "%b\n" "${GREEN}$*${NC}"; }
warn()  { printf "%b\n" "${YELLOW}$*${NC}"; }
error() { printf "%b\n" "${RED}$*${NC}" >&2; }
die()   { error "$*"; exit 1; }

[ "$(id -u)" = "0" ] || die "Run this script as root."
[ -r /etc/openwrt_release ] || die "Cannot read /etc/openwrt_release."

. /etc/openwrt_release

case "$DISTRIB_RELEASE" in
    *SNAPSHOT*)
        die "SNAPSHOT builds are not supported by this installer."
        ;;
esac

RELEASE="${DISTRIB_RELEASE%.*}"
ARCH="$DISTRIB_ARCH"

[ -n "$RELEASE" ] || die "Cannot detect OpenWrt release."
[ -n "$ARCH" ] || die "Cannot detect OpenWrt architecture."

if command -v apk >/dev/null 2>&1; then
    PKG_MANAGER='apk'
elif command -v opkg >/dev/null 2>&1; then
    PKG_MANAGER='opkg'
else
    die "Neither apk nor opkg was found."
fi

info "OpenWrt: $DISTRIB_RELEASE"
info "Architecture: $ARCH"
info "Package manager: $PKG_MANAGER"

# -----------------------------------------------------------------------------
# Retry helpers
# -----------------------------------------------------------------------------

sleep_before_retry() {
    attempt="$1"
    warn "Retrying in ${RETRY_DELAY}s... (${attempt}/${RETRY_COUNT})"
    sleep "$RETRY_DELAY"
}

# Download to a temporary file first. The destination is replaced only after a
# successful non-empty download, so a broken mirror cannot destroy a good file.
download_file() {
    url="$1"
    dest="$2"
    label="$3"
    tmp="${dest}.tmp.$$"
    attempt=1

    rm -f "$tmp"

    while [ "$attempt" -le "$RETRY_COUNT" ]; do
        info "$label (attempt $attempt/$RETRY_COUNT)..."
        rm -f "$tmp"

        if wget -O "$tmp" "$url" && [ -s "$tmp" ]; then
            mv -f "$tmp" "$dest"
            return 0
        fi

        rm -f "$tmp"

        if [ "$attempt" -lt "$RETRY_COUNT" ]; then
            sleep_before_retry "$attempt"
        fi

        attempt=$((attempt + 1))
    done

    rm -f "$tmp"
    return 1
}

apk_update_retry() {
    attempt=1

    while [ "$attempt" -le "$RETRY_COUNT" ]; do
        if apk update; then
            return 0
        fi

        warn "apk update failed (attempt $attempt/$RETRY_COUNT)."

        if [ "$attempt" -lt "$RETRY_COUNT" ]; then
            sleep_before_retry "$attempt"
        fi

        attempt=$((attempt + 1))
    done

    return 1
}

apk_add_retry() {
    description="$1"
    shift
    attempt=1

    while [ "$attempt" -le "$RETRY_COUNT" ]; do
        info "$description (attempt $attempt/$RETRY_COUNT)..."

        if apk add "$@"; then
            return 0
        fi

        warn "$description failed (attempt $attempt/$RETRY_COUNT)."

        if [ "$attempt" -lt "$RETRY_COUNT" ]; then
            # Refresh indexes before retrying. This also gives SourceForge a
            # chance to choose a different mirror on the next request.
            apk update >/dev/null 2>&1 || true
            sleep_before_retry "$attempt"
        fi

        attempt=$((attempt + 1))
    done

    return 1
}

opkg_update_retry() {
    attempt=1

    while [ "$attempt" -le "$RETRY_COUNT" ]; do
        if opkg update; then
            return 0
        fi

        warn "opkg update failed (attempt $attempt/$RETRY_COUNT)."

        if [ "$attempt" -lt "$RETRY_COUNT" ]; then
            sleep_before_retry "$attempt"
        fi

        attempt=$((attempt + 1))
    done

    return 1
}

opkg_install_retry() {
    description="$1"
    shift
    attempt=1

    while [ "$attempt" -le "$RETRY_COUNT" ]; do
        info "$description (attempt $attempt/$RETRY_COUNT)..."

        if opkg install "$@"; then
            return 0
        fi

        warn "$description failed (attempt $attempt/$RETRY_COUNT)."

        if [ "$attempt" -lt "$RETRY_COUNT" ]; then
            opkg update >/dev/null 2>&1 || true
            sleep_before_retry "$attempt"
        fi

        attempt=$((attempt + 1))
    done

    return 1
}

# -----------------------------------------------------------------------------
# Basic router settings
# -----------------------------------------------------------------------------

if uci -q get network.wan >/dev/null 2>&1; then
    uci -q set network.wan.peerdns='0'
    uci -q set network.wan.dns='1.1.1.1'
fi

if uci -q get network.wan6 >/dev/null 2>&1; then
    uci -q set network.wan6.peerdns='0'
    uci -q set network.wan6.dns='2001:4860:4860::8888'
fi

uci -q set system.@system[0].zonename='Europe/Moscow'
uci -q set system.@system[0].timezone='MSK-3'
uci commit network
uci commit system
/sbin/reload_config

# -----------------------------------------------------------------------------
# DNS helper used while replacing dnsmasq with dnsmasq-full
# -----------------------------------------------------------------------------

backup_resolver() {
    rm -f /tmp/resolv.conf.passwall2.bak
    cp -L /etc/resolv.conf /tmp/resolv.conf.passwall2.bak 2>/dev/null || true
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
}

restore_resolver() {
    if [ -f /tmp/resolv.conf.passwall2.bak ]; then
        cat /tmp/resolv.conf.passwall2.bak > /etc/resolv.conf 2>/dev/null || true
        rm -f /tmp/resolv.conf.passwall2.bak
    fi
}

# -----------------------------------------------------------------------------
# OpenWrt 25.12+ / APK
# -----------------------------------------------------------------------------

valid_apk_key() {
    key="$1"

    [ -s "$key" ] || return 1
    grep -q '^-----BEGIN PUBLIC KEY-----$' "$key" 2>/dev/null || return 1
    grep -q '^-----END PUBLIC KEY-----$' "$key" 2>/dev/null || return 1

    return 0
}

install_apk_key() {
    APK_KEY='/etc/apk/keys/openwrt-passwall-build.pem'
    APK_KEY_NEW='/tmp/openwrt-passwall-build.pem'

    if valid_apk_key "$APK_KEY"; then
        info "PassWall APK key is already installed and looks valid."
        return 0
    fi

    warn "PassWall APK key is missing or invalid. Downloading a fresh copy..."
    rm -f "$APK_KEY_NEW"

    attempt=1
    while [ "$attempt" -le "$RETRY_COUNT" ]; do
        info "Downloading PassWall APK key (attempt $attempt/$RETRY_COUNT)..."
        rm -f "$APK_KEY_NEW"

        if wget -O "$APK_KEY_NEW" "$BASE_URL/apk.pub" && \
           valid_apk_key "$APK_KEY_NEW"; then
            mv -f "$APK_KEY_NEW" "$APK_KEY"
            chmod 0644 "$APK_KEY"
            info "PassWall APK key installed successfully."
            return 0
        fi

        rm -f "$APK_KEY_NEW"
        warn "Failed to download a valid PassWall APK key."

        if [ "$attempt" -lt "$RETRY_COUNT" ]; then
            sleep_before_retry "$attempt"
        fi

        attempt=$((attempt + 1))
    done

    return 1
}

install_with_apk() {
    info "Configuring PassWall repositories for APK..."

    mkdir -p /etc/apk/keys /etc/apk/repositories.d

    install_apk_key || \
        die "Failed to install a valid PassWall APK key after $RETRY_COUNT attempts."

    REPO_FILE='/etc/apk/repositories.d/customfeeds.list'
    touch "$REPO_FILE"

    # Remove only old PassWall feed entries; preserve all unrelated feeds.
    sed -i '\|openwrt-passwall-build|d' "$REPO_FILE"

    for feed in passwall_luci passwall_packages passwall2; do
        printf '%s\n' \
            "$BASE_URL/releases/packages-$RELEASE/$ARCH/$feed/packages.adb" \
            >> "$REPO_FILE"
    done

    apk_update_retry || die "apk update failed after $RETRY_COUNT attempts."

    info "Installing dnsmasq-full..."
    if ! apk info -e dnsmasq-full >/dev/null 2>&1; then
        backup_resolver
        apk del dnsmasq >/dev/null 2>&1 || true

        if ! apk_add_retry "Installing dnsmasq-full" dnsmasq-full; then
            restore_resolver
            die "Failed to install dnsmasq-full after $RETRY_COUNT attempts."
        fi

        restore_resolver
    fi

    info "Installing PassWall2 and required packages..."

    apk_add_retry "Installing basic dependencies" unzip ca-bundle || \
        die "Failed to install basic dependencies after $RETRY_COUNT attempts."

    apk_add_retry "Installing PassWall2" \
        luci-app-passwall2 luci-i18n-passwall2-ru || \
        die "Failed to install PassWall2 after $RETRY_COUNT attempts."

    apk_add_retry "Installing xray-core" xray-core || \
        die "Failed to install xray-core after $RETRY_COUNT attempts."

    for pkg in \
        kmod-nft-socket \
        kmod-nft-tproxy \
        kmod-inet-diag \
        kmod-netlink-diag \
        kmod-tun \
        ipset
    do
        apk add "$pkg" >/dev/null 2>&1 || \
            warn "Optional package was not installed: $pkg"
    done
}

# -----------------------------------------------------------------------------
# OpenWrt 24.10 and older / OPKG
# -----------------------------------------------------------------------------

install_with_opkg() {
    info "Configuring PassWall repositories for OPKG..."

    rm -f /tmp/ipk.pub
    download_file "$BASE_URL/ipk.pub" /tmp/ipk.pub \
        "Downloading PassWall OPKG key" || \
        die "Failed to download PassWall OPKG key after $RETRY_COUNT attempts."

    opkg-key add /tmp/ipk.pub || die "Failed to add PassWall OPKG key."

    REPO_FILE='/etc/opkg/customfeeds.conf'
    touch "$REPO_FILE"

    # Remove only old PassWall feed entries; preserve all unrelated feeds.
    sed -i '/openwrt-passwall-build/d' "$REPO_FILE"
    sed -i '/^src\/gz passwall_luci /d; /^src\/gz passwall_packages /d; /^src\/gz passwall2 /d' "$REPO_FILE"

    for feed in passwall_luci passwall_packages passwall2; do
        printf 'src/gz %s %s\n' \
            "$feed" \
            "$BASE_URL/releases/packages-$RELEASE/$ARCH/$feed" \
            >> "$REPO_FILE"
    done

    opkg_update_retry || die "opkg update failed after $RETRY_COUNT attempts."

    info "Installing dnsmasq-full..."
    if ! opkg status dnsmasq-full 2>/dev/null | grep -q '^Status:.* installed'; then
        backup_resolver
        opkg remove dnsmasq >/dev/null 2>&1 || true

        if ! opkg_install_retry "Installing dnsmasq-full" dnsmasq-full; then
            restore_resolver
            die "Failed to install dnsmasq-full after $RETRY_COUNT attempts."
        fi

        restore_resolver
    fi

    info "Installing PassWall2 and required packages..."

    opkg_install_retry "Installing basic dependencies" wget-ssl unzip ca-bundle || \
        die "Failed to install basic dependencies after $RETRY_COUNT attempts."

    opkg_install_retry "Installing PassWall2" \
        luci-app-passwall2 luci-i18n-passwall2-ru || \
        die "Failed to install PassWall2 after $RETRY_COUNT attempts."

    opkg_install_retry "Installing xray-core" xray-core || \
        die "Failed to install xray-core after $RETRY_COUNT attempts."

    for pkg in \
        kmod-nft-socket \
        kmod-nft-tproxy \
        kmod-inet-diag \
        kmod-netlink-diag \
        kmod-tun \
        ipset
    do
        opkg install "$pkg" >/dev/null 2>&1 || \
            warn "Optional package was not installed: $pkg"
    done
}

case "$PKG_MANAGER" in
    apk)  install_with_apk ;;
    opkg) install_with_opkg ;;
esac

# -----------------------------------------------------------------------------
# Installation checks
# -----------------------------------------------------------------------------

[ -x /etc/init.d/passwall2 ] || die "PassWall2 installation failed."
[ -x /usr/bin/xray ] || die "Xray installation failed."

if [ "$PKG_MANAGER" = 'apk' ]; then
    apk info -e dnsmasq-full >/dev/null 2>&1 || \
        die "dnsmasq-full is not installed."
else
    opkg status dnsmasq-full 2>/dev/null | grep -q '^Status:.* installed' || \
        die "dnsmasq-full is not installed."
fi

# -----------------------------------------------------------------------------
# frenzydrive PassWall2 interface mod
# This MUST run after PassWall2 installation so modified files overwrite stock.
# -----------------------------------------------------------------------------

info "Applying customized PassWall2 interface files..."
cd /tmp || die "Cannot enter /tmp."
rm -f mod.zip

download_file "$MOD_ZIP_URL" /tmp/mod.zip \
    "Downloading customized PassWall2 mod" || \
    die "Failed to download mod.zip after $RETRY_COUNT attempts."

unzip -tq /tmp/mod.zip >/dev/null 2>&1 || \
    die "Downloaded mod.zip is invalid or incomplete."

unzip -o /tmp/mod.zip -d / || die "Failed to unpack mod.zip."

# -----------------------------------------------------------------------------
# PassWall2 defaults
# -----------------------------------------------------------------------------

info "Applying PassWall2 settings..."

uci -q set system.@system[0].zonename='Europe/Moscow'
uci -q set system.@system[0].timezone='MSK-3'
uci -q set passwall2.@global_forwarding[0]=global_forwarding
uci -q set passwall2.@global_forwarding[0].tcp_no_redir_ports='disable'
uci -q set passwall2.@global_forwarding[0].udp_no_redir_ports='disable'
uci -q set passwall2.@global_forwarding[0].tcp_redir_ports='1:65535'
uci -q set passwall2.@global_forwarding[0].udp_redir_ports='1:65535'
uci -q set passwall2.@global[0].direct_dns_protocol='auto'
uci -q set passwall2.@global[0].direct_dns_query_strategy='UseIP'
uci -q set passwall2.@global[0].remote_dns_protocol='doh'
uci -q set passwall2.@global[0].remote_dns_query_strategy='UseIPv4'
uci -q set passwall2.@global[0].dns_hosts='cloudflare-dns.com 1.1.1.1 dns.google.com 8.8.8.8'
uci -q set passwall2.@global[0].remote_dns_detour='remote'
uci -q set passwall2.@global[0].remote_dns_doh='https://1.1.1.1/dns-query'
uci -q set passwall2.@global[0].dns_redirect='1'

# Remove stock regional rules used by the package defaults.
uci -q delete passwall2.China
uci -q delete passwall2.Iran

# Direct rule for Russia.
uci -q set passwall2.Russia=shunt_rules
uci -q set passwall2.Russia.network='tcp,udp'
uci -q set passwall2.Russia.remarks='Russia'
uci -q set passwall2.Russia.domain_list='geosite:category-ru'
uci -q set passwall2.Russia.ip_list='geoip:ru'
uci -q set passwall2.rulenode.Russia='_direct'

uci commit passwall2
uci commit system
uci commit network

/sbin/reload_config
/etc/init.d/passwall2 enable
/etc/init.d/passwall2 restart

rm -f \
    /tmp/install_passwall2.sh \
    /tmp/install_passwall2_25.1.sh \
    /tmp/mod.zip \
    /tmp/ipk.pub \
    /tmp/openwrt-passwall-build.pem \
    /tmp/resolv.conf.passwall2.bak

printf "%b\n" "${YELLOW}** PassWall2 installation completed successfully **${NC}"
printf "%b\n" "${MAGENTA}Customized for frenzydrive/openwrt-scripts${NC}"
