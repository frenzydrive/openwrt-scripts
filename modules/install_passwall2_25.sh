#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
NC='\033[0m'

PASSWALL_BASE_URL="https://master.dl.sourceforge.net/project/openwrt-passwall-build"
PASSWALL_FEEDS_FILE="/etc/apk/repositories.d/passwall.list"
MOD_URL="https://raw.githubusercontent.com/frenzydrive/openwrt-scripts/main/assets/passwall2/mod.zip"
FALLBACK_XRAY_URL="https://raw.githubusercontent.com/amirhosseinchoghaei/mi4agigabit/main/amirhossein.sh"

log() {
    echo -e "$1"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log "${RED}Please run this script as root.${NC}"
        exit 1
    fi
}

require_apk() {
    if ! command -v apk >/dev/null 2>&1; then
        log "${RED}This installer is for OpenWrt 25.12.x and newer (apk-based systems).${NC}"
        exit 1
    fi
}

configure_basic_system() {
    log "${GREEN}Applying base network and timezone settings...${NC}"

    uci set network.wan.peerdns='0' || true
    uci set network.wan6.peerdns='0' || true
    uci set network.wan.dns='1.1.1.1' || true
    uci set network.wan6.dns='2001:4860:4860::8888' || true

    uci set system.@system[0].zonename='Europe/Moscow'
    uci set system.@system[0].timezone='MSK-3'

    uci commit network
    uci commit system
    /sbin/reload_config
}

detect_release_and_arch() {
    # shellcheck disable=SC1091
    . /etc/openwrt_release

    if echo "${DISTRIB_RELEASE:-}" | grep -q 'SNAPSHOT'; then
        log "${YELLOW}SNAPSHOT version detected!${NC}"
        log "${RED}SNAPSHOT builds are not supported by this installer.${NC}"
        log "${YELLOW}Please use a stable OpenWrt release version.${NC}"
        exit 1
    fi

    RELEASE="${DISTRIB_RELEASE%.*}"

    ARCH="$(apk --print-arch 2>/dev/null || true)"
    if [ -z "$ARCH" ]; then
        ARCH="${DISTRIB_ARCH:-}"
    fi

    if [ -z "$RELEASE" ] || [ -z "$ARCH" ]; then
        log "${RED}Failed to detect OpenWrt release or architecture.${NC}"
        exit 1
    fi

    PASSWALL_RELEASE_URL="$PASSWALL_BASE_URL/releases/packages-$RELEASE/$ARCH"
}

configure_passwall_repo() {
    log "${GREEN}Configuring PassWall APK feeds...${NC}"

    mkdir -p /etc/apk/repositories.d

    # 1. Достаем архитектуру напрямую через apk
    # Обычно это что-то вроде aarch64_cortex-a53
    SUB_ARCH=$(apk --print-arch)

    # 2. Проверяем версию. Если это 25.12, которой еще нет в репозитории PassWall,
    # мы подменим её на 24.10, чтобы пакеты могли установиться.
    # (Пакеты от 24.10 совместимы с 25.12 по архитектуре)
    PW_VER="$RELEASE"
    if [ "$RELEASE" = "25.12" ]; then
        log "${YELLOW}Forcing 24.10 repository for 25.12 compatibility...${NC}"
        PW_VER="24.10"
    fi

    # 3. Формируем правильные пути (Версия -> Фид -> Архитектура)
    cat > "$PASSWALL_FEEDS_FILE" <<EOF_REPOS
$PASSWALL_BASE_URL/releases/packages-$PW_VER/passwall_packages/$SUB_ARCH
$PASSWALL_BASE_URL/releases/packages-$PW_VER/passwall_luci/$SUB_ARCH
$PASSWALL_BASE_URL/releases/packages-$PW_VER/passwall2/$SUB_ARCH
EOF_REPOS

    apk update || true
}

install_passwall_packages() {
    log "${GREEN}Installing PassWall2 and dependencies...${NC}"

    if apk info -e dnsmasq >/dev/null 2>&1; then
        apk del dnsmasq || true
    fi

    apk add --allow-untrusted \
        dnsmasq-full \
        wget-ssl \
        unzip \
        ca-bundle \
        luci-app-passwall2 \
        kmod-nft-socket \
        kmod-nft-tproxy \
        kmod-inet-diag \
        kmod-netlink-diag \
        kmod-tun \
        ipset

    if [ -f /etc/init.d/passwall2 ]; then
        log "${GREEN}PassWall2 installed successfully!${NC}"
    else
        log "${RED}PassWall2 installation failed.${NC}"
        exit 1
    fi

    if apk info -e dnsmasq-full >/dev/null 2>&1; then
        log "${GREEN}dnsmasq-full installed successfully!${NC}"
    else
        log "${RED}dnsmasq-full not installed.${NC}"
        exit 1
    fi
}

install_xray() {
    log "${GREEN}Installing Xray...${NC}"

    if ! apk add --allow-untrusted xray-core; then
        log "${YELLOW}xray-core installation failed from repository, trying fallback...${NC}"
    fi

    if [ -f /usr/bin/xray ] || [ -f /usr/sbin/xray ]; then
        log "${GREEN}Xray installed successfully!${NC}"
        return 0
    fi

    log "${YELLOW}Xray not found after package install, trying fallback script...${NC}"
    rm -f /tmp/amirhossein.sh
    wget -O /tmp/amirhossein.sh "$FALLBACK_XRAY_URL"
    chmod 755 /tmp/amirhossein.sh
    /bin/sh /tmp/amirhossein.sh
}

install_ui_mods() {
    log "${GREEN}Installing customized UI files...${NC}"

    cd /tmp || exit 1
    rm -f mod.zip
    wget -q -O mod.zip "$MOD_URL"
    unzip -o mod.zip -d /
    cd /root 2>/dev/null || cd /
}

configure_passwall() {
    log "${GREEN}Applying PassWall settings...${NC}"

    uci set system.@system[0].zonename='Europe/Moscow'
    uci set system.@system[0].timezone='MSK-3'

    if ! uci -q get passwall2.@global_forwarding[0] >/dev/null; then
        uci add passwall2 global_forwarding >/dev/null
    fi
    if ! uci -q get passwall2.@global[0] >/dev/null; then
        uci add passwall2 global >/dev/null
    fi
    if ! uci -q get passwall2.rulenode >/dev/null; then
        uci set passwall2.rulenode='nodes'
    fi

    uci set passwall2.@global_forwarding[0].tcp_no_redir_ports='disable'
    uci set passwall2.@global_forwarding[0].udp_no_redir_ports='disable'
    uci set passwall2.@global_forwarding[0].tcp_redir_ports='1:65535'
    uci set passwall2.@global_forwarding[0].udp_redir_ports='1:65535'
    uci set passwall2.@global[0].remote_dns='8.8.4.4'

    uci set passwall2.Russia='shunt_rules'
    uci set passwall2.Russia.network='tcp,udp'
    uci set passwall2.Russia.remarks='Russia'
    uci set passwall2.Russia.domain_list='geosite:category-ru'
    uci set passwall2.Russia.ip_list='geoip:ru'

    uci set passwall2.rulenode.Russia='_direct'

    uci commit passwall2
    uci commit system
    uci commit network
}

cleanup() {
    rm -f /tmp/install_passwall2.sh /tmp/install_passwall2_25.sh /tmp/install_passwall2_25_auto.sh \
          /tmp/amirhossein.sh /tmp/mod.zip /root/passwall.pub passwalls.sh 2>/dev/null || true
}

main() {
    require_root
    require_apk

    clear || true
    log "Running as root..."
    sleep 1

    configure_basic_system
    detect_release_and_arch
    configure_passwall_repo
    install_passwall_packages
    install_xray
    install_ui_mods
    configure_passwall
    cleanup

    /sbin/reload_config

    log "${YELLOW}** Installation completed **${NC}"
    log "${MAGENTA}Customized for frenzydrive/openwrt-scripts${NC}"
}

main "$@"
