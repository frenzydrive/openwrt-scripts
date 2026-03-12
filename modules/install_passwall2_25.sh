#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Базовые настройки
PASSWALL_BASE_URL="https://master.dl.sourceforge.net/project/openwrt-passwall-build"
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
    log "${GREEN}Applying base network and timezone settings (Europe/Moscow)...${NC}"

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
    # Для систем на apk 25.12 определяем архитектуру автоматически
    ARCH="$(apk --print-arch 2>/dev/null || echo "aarch64_cortex-a53")"
    RELEASE="25.12"

    log "${YELLOW}Detected Arch: $ARCH. Using PassWall feeds for: $RELEASE${NC}"
}

configure_passwall_repo() {
    log "${GREEN}Configuring PassWall APK feeds (ADB format)...${NC}"

    # Полная очистка всех старых и кастомных списков для исключения конфликтов
    rm -f /etc/apk/repositories.d/*.list

    # Формируем пути. В OpenWrt 25 apk автоматически добавляет архитектуру к URL,
    # поэтому указываем путь до папки релиза.
    # Префикс [ndx:adb] принудительно включает поиск packages.adb вместо APKINDEX.tar.gz
    local REPO_ROOT="$PASSWALL_BASE_URL/releases/packages-$RELEASE"
    
    cat > "/etc/apk/repositories.d/passwall.list" <<EOF
[ndx:adb]$REPO_ROOT/passwall_packages
[ndx:adb]$REPO_ROOT/passwall_luci
[ndx:adb]$REPO_ROOT/passwall2
EOF

    log "${YELLOW}Feeds configured. Updating package lists...${NC}"
    apk update || true
}

install_passwall_packages() {
    log "${GREEN}Installing PassWall2 and dependencies...${NC}"

    # Удаляем стандартный dnsmasq для установки dnsmasq-full
    if apk info -e dnsmasq >/dev/null 2>&1; then
        apk del dnsmasq || true
    fi

    # Установка с флагом --allow-untrusted для сторонних репозиториев
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
}

install_xray() {
    log "${GREEN}Installing Xray...${NC}"

    if ! apk add --allow-untrusted xray-core; then
        log "${YELLOW}xray-core installation failed from repository, trying fallback...${NC}"
        rm -f /tmp/amirhossein.sh
        wget -qO /tmp/amirhossein.sh "$FALLBACK_XRAY_URL"
        chmod +x /tmp/amirhossein.sh
        /bin/sh /tmp/amirhossein.sh
    fi

    if [ -f /usr/bin/xray ] || [ -f /usr/sbin/xray ]; then
        log "${GREEN}Xray installed successfully!${NC}"
    else
        log "${RED}Xray installation failed.${NC}"
    fi
}

install_ui_mods() {
    log "${GREEN}Installing customized UI files...${NC}"

    wget -qO /tmp/mod.zip "$MOD_URL"
    if [ -f /tmp/mod.zip ]; then
        unzip -o /tmp/mod.zip -d /
        log "${GREEN}UI mods applied.${NC}"
    else
        log "${YELLOW}UI mod file not found, skipping.${NC}"
    fi
}

configure_passwall() {
    log "${GREEN}Applying PassWall settings for Russia/Shunt...${NC}"

    # Инициализация базовых секций если их нет
    if ! uci -q get passwall2.@global_forwarding[0] >/dev/null; then
        uci add passwall2 global_forwarding >/dev/null
    fi
    if ! uci -q get passwall2.@global[0] >/dev/null; then
        uci add passwall2 global >/dev/null
    fi

    # Основные настройки портов
    uci set passwall2.@global_forwarding[0].tcp_no_redir_ports='disable'
    uci set passwall2.@global_forwarding[0].udp_no_redir_ports='disable'
    uci set passwall2.@global_forwarding[0].tcp_redir_ports='1:65535'
    uci set passwall2.@global_forwarding[0].udp_redir_ports='1:65535'
    uci set passwall2.@global[0].remote_dns='8.8.4.4'

    # Правила для РФ (Direct)
    uci set passwall2.Russia='shunt_rules'
    uci set passwall2.Russia.network='tcp,udp'
    uci set passwall2.Russia.remarks='Russia'
    uci set passwall2.Russia.domain_list='geosite:category-ru'
    uci set passwall2.Russia.ip_list='geoip:ru'

    # Настройка узлов
    if ! uci -q get passwall2.rulenode >/dev/null; then
        uci set passwall2.rulenode='nodes'
    fi
    uci set passwall2.rulenode.Russia='_direct'

    uci commit passwall2
}

cleanup() {
    log "${GREEN}Cleaning up temporary files...${NC}"
    rm -f /tmp/install_passwall2_25_auto.sh /tmp/amirhossein.sh /tmp/mod.zip 2>/dev/null || true
}

main() {
    require_root
    require_apk

    log "Starting installation for OpenWrt 25.12..."
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
    log "${YELLOW}** Installation completed successfully **${NC}"
    log "${MAGENTA}Customized for frenzydrive/openwrt-scripts${NC}"
}

main "$@"
