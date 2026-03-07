#!/bin/sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
NC='\033[0m'

INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/frenzydrive/openwrt-scripts/main/modules/install_passwall2.sh"
MOD_ZIP_URL="https://raw.githubusercontent.com/frenzydrive/openwrt-scripts/main/assets/passwall2/mod.zip"

PASSWALL_PKG="luci-app-passwall2"
PASSWALL_I18N_PKG="luci-i18n-passwall2-ru"

echo "Running as root..."
sleep 1
clear

is_passwall_installed() {
    opkg status "$PASSWALL_PKG" >/dev/null 2>&1 && return 0
    [ -f /etc/init.d/passwall2 ] && return 0
    return 1
}

ask_yes_no() {
    prompt="$1"
    while true; do
        printf "%b%s [y/n]: %b" "$YELLOW" "$prompt" "$NC"
        read ans
        case "$ans" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

configure_passwall_feed() {
    release="$(. /etc/openwrt_release; echo "${DISTRIB_RELEASE%.*}")"
    arch="$(. /etc/openwrt_release; echo "${DISTRIB_ARCH}")"

    if [ -z "$release" ] || [ -z "$arch" ]; then
        echo -e "${RED}Failed to detect OpenWrt release or architecture.${NC}"
        return 1
    fi

    echo -e "${GREEN}Detected release: ${release}${NC}"
    echo -e "${GREEN}Detected architecture: ${arch}${NC}"

    cat > /etc/opkg/customfeeds.conf <<EOF
src/gz passwall2 https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-$release/$arch/passwall2
EOF

    return 0
}

update_passwall_packages() {
    echo -e "${GREEN}Updating package lists...${NC}"
    opkg update || return 1

    echo -e "${GREEN}Updating PassWall2 packages...${NC}"
    opkg install "$PASSWALL_PKG" "$PASSWALL_I18N_PKG" || return 1

    return 0
}

apply_mod_files() {
    echo -e "${GREEN}Downloading customized PassWall2 files...${NC}"
    cd /tmp || return 1
    rm -f mod.zip

    wget -q "$MOD_ZIP_URL" -O mod.zip || return 1
    unzip -o mod.zip -d / || return 1

    cd / >/dev/null 2>&1 || return 1
    return 0
}

apply_post_update_settings() {
    echo -e "${GREEN}Applying post-update settings...${NC}"

    uci set system.@system[0].zonename='Europe/Moscow'
    uci set system.@system[0].timezone='MSK-3'

    uci set passwall2.@global_forwarding[0]=global_forwarding
    uci set passwall2.@global_forwarding[0].tcp_no_redir_ports='disable'
    uci set passwall2.@global_forwarding[0].udp_no_redir_ports='disable'
    uci set passwall2.@global_forwarding[0].tcp_redir_ports='1:65535'
    uci set passwall2.@global_forwarding[0].udp_redir_ports='1:65535'
    uci set passwall2.@global[0].remote_dns='8.8.4.4'

    uci set passwall2.Russia=shunt_rules
    uci set passwall2.Russia.network='tcp,udp'
    uci set passwall2.Russia.remarks='Russia'
    uci set passwall2.Russia.domain_list='geosite:category-ru'
    uci set passwall2.Russia.ip_list='geoip:ru'
    uci set passwall2.myshunt.Russia='_direct'

    uci commit passwall2
    uci commit system
    /sbin/reload_config

    return 0
}

run_install_script() {
    echo -e "${GREEN}Downloading install_passwall2.sh...${NC}"
    cd /tmp || exit 1
    rm -f install_passwall2.sh

    wget -q "$INSTALL_SCRIPT_URL" -O install_passwall2.sh || {
        echo -e "${RED}Failed to download install_passwall2.sh${NC}"
        exit 1
    }

    chmod 755 install_passwall2.sh
    echo -e "${GREEN}Starting PassWall2 installation...${NC}"
    sh /tmp/install_passwall2.sh
    exit $?
}

if ! is_passwall_installed; then
    echo -e "${RED}PassWall2 is not installed on this router.${NC}"

    if ask_yes_no "Do you want to install PassWall2 now?"; then
        run_install_script
    else
        echo -e "${YELLOW}Update cancelled.${NC}"
        exit 0
    fi
fi

echo -e "${GREEN}PassWall2 installation detected.${NC}"

configure_passwall_feed || {
    echo -e "${RED}Failed to configure PassWall2 feed.${NC}"
    exit 1
}

update_passwall_packages || {
    echo -e "${RED}Failed to update PassWall2 packages.${NC}"
    exit 1
}

apply_mod_files || {
    echo -e "${RED}Failed to apply customized mod.zip files.${NC}"
    exit 1
}

apply_post_update_settings || {
    echo -e "${RED}Failed to apply post-update settings.${NC}"
    exit 1
}

echo -e "${YELLOW}** PassWall2 update completed successfully **${NC}"
echo -e "${MAGENTA}Customized for frenzydrive/openwrt-scripts${NC}"
