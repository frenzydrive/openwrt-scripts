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

log() { echo -e "$1"; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log "${RED}Please run as root.${NC}"
        exit 1
    fi
}

require_apk() {
    if ! command -v apk >/dev/null 2>&1; then
        log "${RED}This installer is for OpenWrt 25.12+ (apk-based).${NC}"
        exit 1
    fi
}

configure_basic_system() {
    log "${GREEN}Applying network and timezone (Europe/Moscow)...${NC}"
    uci set network.wan.peerdns='0'
    uci set network.wan.dns='1.1.1.1'
    uci set system.@system[0].zonename='Europe/Moscow'
    uci set system.@system[0].timezone='MSK-3'
    uci commit network
    uci commit system
}

detect_release_and_arch() {
    # Для 25.12 используем фиды от 24.10, так как они совместимы и уже существуют
    RELEASE="24.10"
    
    # В apk-версиях это вернет чистую строку архитектуры (например, aarch64_cortex-a53)
    ARCH=$(apk --print-arch)
    
    log "${YELLOW}Detected Arch: $ARCH. Using PassWall feeds for: $RELEASE${NC}"
}

configure_passwall_repo() {
    log "${GREEN}Configuring PassWall APK feeds...${NC}"
    mkdir -p /etc/apk/repositories.d

    # Правильная структура URL для SourceForge: версия -> название фида -> архитектура
    cat > "$PASSWALL_FEEDS_FILE" <<EOF_REPOS
$PASSWALL_BASE_URL/releases/packages-$RELEASE/passwall_packages/$ARCH
$PASSWALL_BASE_URL/releases/packages-$RELEASE/passwall_luci/$ARCH
$PASSWALL_BASE_URL/releases/packages-$RELEASE/passwall2/$ARCH
EOF_REPOS

    apk update || true
}

install_passwall_packages() {
    log "${GREEN}Installing PassWall2 and dependencies...${NC}"
    
    # Удаляем стандартный dnsmasq перед установкой full-версии
    apk del dnsmasq || true
    
    # --allow-untrusted обязателен для сторонних репозиториев без импортированного ключа
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
}

install_xray() {
    log "${GREEN}Installing Xray...${NC}"
    if ! apk add --allow-untrusted xray-core; then
        log "${YELLOW}Trying fallback script for Xray...${NC}"
        wget -qO /tmp/amirhossein.sh "$FALLBACK_XRAY_URL"
        chmod +x /tmp/amirhossein.sh
        /bin/sh /tmp/amirhossein.sh
    fi
}

install_ui_mods() {
    log "${GREEN}Installing customized UI files...${NC}"
    wget -qO /tmp/mod.zip "$MOD_URL"
    unzip -o /tmp/mod.zip -d /
}

configure_passwall() {
    log "${GREEN}Applying PassWall settings...${NC}"
    # Твои настройки для обхода блокировок в РФ
    uci set passwall2.Russia='shunt_rules'
    uci set passwall2.Russia.remarks='Russia'
    uci set passwall2.Russia.domain_list='geosite:category-ru'
    uci set passwall2.Russia.ip_list='geoip:ru'
    uci set passwall2.rulenode.Russia='_direct'
    uci commit passwall2
}

main() {
    require_root
    require_apk
    configure_basic_system
    detect_release_and_arch
    configure_passwall_repo
    install_passwall_packages
    install_xray
    install_ui_mods
    configure_passwall
    /sbin/reload_config
    log "${YELLOW}** Installation completed for OpenWrt 25.12 **${NC}"
}

main "$@"
