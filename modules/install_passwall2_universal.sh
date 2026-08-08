#!/bin/sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
NC='\033[0m'

BASE_URL='https://master.dl.sourceforge.net/project/openwrt-passwall-build'
MOD_ZIP_URL='https://raw.githubusercontent.com/frenzydrive/openwrt-scripts/main/assets/passwall2/mod.zip'

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

install_with_apk() {
    info "Configuring PassWall repositories for APK..."

    mkdir -p /etc/apk/keys /etc/apk/repositories.d

    wget -O /etc/apk/keys/openwrt-passwall-build.pem \
        "$BASE_URL/apk.pub" || die "Failed to download PassWall APK key."

    REPO_FILE='/etc/apk/repositories.d/customfeeds.list'
    touch "$REPO_FILE"

    # Remove only old PassWall feed entries; preserve all unrelated feeds.
    sed -i '\|openwrt-passwall-build|d' "$REPO_FILE"

    for feed in passwall_luci passwall_packages passwall2; do
        printf '%s\n' \
            "$BASE_URL/releases/packages-$RELEASE/$ARCH/$feed/packages.adb" \
            >> "$REPO_FILE"
    done

    apk update || die "apk update failed."

    info "Installing dnsmasq-full..."
    if ! apk info -e dnsmasq-full >/dev/null 2>&1; then
        backup_resolver
        apk del dnsmasq >/dev/null 2>&1 || true
        apk add dnsmasq-full || {
            restore_resolver
            die "Failed to install dnsmasq-full."
        }
        restore_resolver
    fi

    info "Installing PassWall2 and required packages..."
    apk add unzip ca-bundle || die "Failed to install basic dependencies."
    apk add luci-app-passwall2 luci-i18n-passwall2-ru || \
        die "Failed to install PassWall2."
    apk add xray-core || die "Failed to install xray-core."

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

    wget -O /tmp/ipk.pub "$BASE_URL/ipk.pub" || \
        die "Failed to download PassWall OPKG key."
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

    opkg update || die "opkg update failed."

    info "Installing dnsmasq-full..."
    if ! opkg status dnsmasq-full 2>/dev/null | grep -q '^Status:.* installed'; then
        backup_resolver
        opkg remove dnsmasq >/dev/null 2>&1 || true
        opkg install dnsmasq-full || {
            restore_resolver
            die "Failed to install dnsmasq-full."
        }
        restore_resolver
    fi

    info "Installing PassWall2 and required packages..."
    opkg install wget-ssl unzip ca-bundle || die "Failed to install basic dependencies."
    opkg install luci-app-passwall2 luci-i18n-passwall2-ru || \
        die "Failed to install PassWall2."
    opkg install xray-core || die "Failed to install xray-core."

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
wget -q -O mod.zip "$MOD_ZIP_URL" || die "Failed to download mod.zip."
unzip -o mod.zip -d / || die "Failed to unpack mod.zip."

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

rm -f /tmp/install_passwall2.sh /tmp/install_passwall2_25.1.sh /tmp/mod.zip /tmp/ipk.pub /tmp/resolv.conf.passwall2.bak

printf "%b\n" "${YELLOW}** PassWall2 installation completed successfully **${NC}"
printf "%b\n" "${MAGENTA}Customized for frenzydrive/openwrt-scripts${NC}"
