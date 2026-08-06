#!/bin/sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
NC='\033[0m'

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
BASE_URL="https://master.dl.sourceforge.net/project/openwrt-passwall-build"

info "OpenWrt: $DISTRIB_RELEASE"
info "Architecture: $ARCH"

# Basic network settings
uci -q set network.wan.peerdns='0'
uci -q set network.wan.dns='1.1.1.1'

if uci -q get network.wan6 >/dev/null 2>&1; then
    uci -q set network.wan6.peerdns='0'
    uci -q set network.wan6.dns='2001:4860:4860::8888'
fi

# Time zone: Moscow
uci -q set system.@system[0].zonename='Europe/Moscow'
uci -q set system.@system[0].timezone='MSK-3'
uci commit network
uci commit system
/sbin/reload_config

install_with_apk() {
    info "APK package manager detected."

    mkdir -p /etc/apk/keys /etc/apk/repositories.d

    wget -O /etc/apk/keys/openwrt-passwall-build.pem \
        "$BASE_URL/apk.pub" || die "Failed to download PassWall APK key."

    REPO_FILE='/etc/apk/repositories.d/customfeeds.list'
    touch "$REPO_FILE"
    sed -i '\|openwrt-passwall-build|d' "$REPO_FILE"

    for feed in passwall_luci passwall_packages passwall2; do
        printf '%s\n' \
            "$BASE_URL/releases/packages-$RELEASE/$ARCH/$feed/packages.adb" \
            >> "$REPO_FILE"
    done

    apk update || die "apk update failed."

    # Preserve DNS resolution while replacing dnsmasq.
    cp -L /etc/resolv.conf /tmp/resolv.conf.passwall2.bak 2>/dev/null || true
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf

    if ! apk info -e dnsmasq-full >/dev/null 2>&1; then
        apk del dnsmasq >/dev/null 2>&1 || true
        apk add dnsmasq-full || die "Failed to install dnsmasq-full."
    fi

    [ ! -f /tmp/resolv.conf.passwall2.bak ] || \
        cat /tmp/resolv.conf.passwall2.bak > /etc/resolv.conf

    apk add unzip ca-bundle || die "Failed to install basic dependencies."
    apk add luci-app-passwall2 luci-i18n-passwall2-ru || \
        die "Failed to install luci-app-passwall2."
    apk add xray-core || die "Failed to install xray-core."

    # Useful runtime dependencies. Some can already be pulled automatically.
    for pkg in \
        kmod-nft-socket \
        kmod-nft-tproxy \
        kmod-inet-diag \
        kmod-netlink-diag \
        kmod-tun \
        ipset
    do
        apk add "$pkg" >/dev/null 2>&1 || warn "Optional package was not installed: $pkg"
    done
}

install_with_opkg() {
    info "OPKG package manager detected."

    opkg update || die "opkg update failed."

    wget -O /tmp/ipk.pub "$BASE_URL/ipk.pub" || \
        die "Failed to download PassWall OPKG key."
    opkg-key add /tmp/ipk.pub || die "Failed to add PassWall OPKG key."

    REPO_FILE='/etc/opkg/customfeeds.conf'
    touch "$REPO_FILE"
    sed -i '/openwrt-passwall-build/d' "$REPO_FILE"
    sed -i '/^src\/gz passwall_luci /d; /^src\/gz passwall_packages /d; /^src\/gz passwall2 /d' "$REPO_FILE"

    for feed in passwall_luci passwall_packages passwall2; do
        printf 'src/gz %s %s\n' \
            "$feed" \
            "$BASE_URL/releases/packages-$RELEASE/$ARCH/$feed" \
            >> "$REPO_FILE"
    done

    opkg update || die "Second opkg update failed."

    if ! opkg status dnsmasq-full 2>/dev/null | grep -q '^Status:.* installed'; then
        opkg remove dnsmasq >/dev/null 2>&1 || true
        opkg install dnsmasq-full || die "Failed to install dnsmasq-full."
    fi

    opkg install wget-ssl unzip ca-bundle || die "Failed to install basic dependencies."
    opkg install luci-app-passwall2 luci-i18n-passwall2-ru || \
        die "Failed to install luci-app-passwall2."
    opkg install xray-core || die "Failed to install xray-core."

    for pkg in \
        kmod-nft-socket \
        kmod-nft-tproxy \
        kmod-inet-diag \
        kmod-netlink-diag \
        kmod-tun \
        ipset
    do
        opkg install "$pkg" >/dev/null 2>&1 || warn "Optional package was not installed: $pkg"
    done
}

if command -v apk >/dev/null 2>&1; then
    install_with_apk
elif command -v opkg >/dev/null 2>&1; then
    install_with_opkg
else
    die "Neither apk nor opkg was found."
fi

[ -x /etc/init.d/passwall2 ] || die "PassWall2 installation failed."
[ -x /usr/bin/xray ] || die "Xray installation failed."

if command -v apk >/dev/null 2>&1; then
    apk info -e dnsmasq-full >/dev/null 2>&1 || die "dnsmasq-full is not installed."
else
    opkg status dnsmasq-full 2>/dev/null | grep -q '^Status:.* installed' || \
        die "dnsmasq-full is not installed."
fi

# Customized interface files
cd /tmp || die "Cannot enter /tmp."
rm -f mod.zip
wget -q -O mod.zip \
    https://raw.githubusercontent.com/frenzydrive/openwrt-scripts/main/assets/passwall2/mod.zip || \
    die "Failed to download mod.zip."
unzip -o mod.zip -d / || die "Failed to unpack mod.zip."

# PassWall2 settings
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

uci -q delete passwall2.China
uci -q delete passwall2.Iran

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

rm -f /tmp/install_passwall2.sh /tmp/mod.zip /tmp/resolv.conf.passwall2.bak

printf "%b\n" "${YELLOW}** Installation completed **${NC}"
printf "%b\n" "${MAGENTA}Customized for frenzydrive/openwrt-scripts${NC}"
