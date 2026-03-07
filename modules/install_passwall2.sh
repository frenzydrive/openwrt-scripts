#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
NC='\033[0m'

echo "Running as root..."
sleep 1
clear

# Базовые сетевые настройки
uci set network.wan.peerdns='0'
uci set network.wan6.peerdns='0'
uci set network.wan.dns='1.1.1.1'
uci set network.wan6.dns='2001:4860:4860::8888'

# Часовой пояс: Москва
uci set system.@system[0].zonename='Europe/Moscow'
uci set system.@system[0].timezone='MSK-3'

uci commit network
uci commit system
/sbin/reload_config

SNAP="$(grep -o SNAPSHOT /etc/openwrt_release | sed -n '1p')"

if [ "$SNAP" = "SNAPSHOT" ]; then
    echo -e "${YELLOW}SNAPSHOT version detected!${NC}"
    echo -e "${RED}SNAPSHOT builds are not supported by this installer.${NC}"
    echo -e "${YELLOW}Please use a stable OpenWrt release version.${NC}"
    exit 1
fi

echo -e "${GREEN}Updating packages...${NC}"
fi

opkg update

# Сторонний feed PassWall
wget -O passwall.pub https://master.dl.sourceforge.net/project/openwrt-passwall-build/passwall.pub
opkg-key add passwall.pub

> /etc/opkg/customfeeds.conf

read release arch << EOF
$(. /etc/openwrt_release ; echo ${DISTRIB_RELEASE%.*} $DISTRIB_ARCH)
EOF

for feed in passwall_luci passwall_packages passwall2; do
    echo "src/gz $feed https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-$release/$arch/$feed" >> /etc/opkg/customfeeds.conf
done

opkg update
sleep 2

# Установка зависимостей
opkg remove dnsmasq
sleep 2
opkg install dnsmasq-full
opkg install wget-ssl unzip luci-app-passwall2
opkg install kmod-nft-socket kmod-nft-tproxy
opkg install ca-bundle kmod-inet-diag kernel kmod-netlink-diag kmod-tun ipset

# Проверки
if [ -f /etc/init.d/passwall2 ]; then
    echo -e "${GREEN}PassWall2 installed successfully!${NC}"
else
    echo -e "${RED}PassWall2 installation failed.${NC}"
    exit 1
fi

if [ -f /usr/lib/opkg/info/dnsmasq-full.control ]; then
    echo -e "${GREEN}dnsmasq-full installed successfully!${NC}"
else
    echo -e "${RED}dnsmasq-full not installed.${NC}"
    exit 1
fi

# Xray
opkg install xray-core
sleep 2

if [ -f /usr/bin/xray ]; then
    echo -e "${GREEN}Xray installed successfully!${NC}"
else
    echo -e "${YELLOW}Xray not installed, trying fallback...${NC}"
    rm -f amirhossein.sh
    wget https://raw.githubusercontent.com/amirhosseinchoghaei/mi4agigabit/main/amirhossein.sh
    chmod 755 amirhossein.sh
    sh amirhossein.sh
fi

# Доработанные файлы интерфейса
cd /tmp || exit 1

wget -q https://raw.githubusercontent.com/frenzydrive/openwrt-scripts/main/assets/passwall2/mod.zip
unzip -o mod.zip -d /

cd || exit 1

# Настройки PassWall2
uci set system.@system[0].zonename='Europe/Moscow'
uci set system.@system[0].timezone='MSK-3'

uci set passwall2.@global_forwarding[0]=global_forwarding
uci set passwall2.@global_forwarding[0].tcp_no_redir_ports='disable'
uci set passwall2.@global_forwarding[0].udp_no_redir_ports='disable'
uci set passwall2.@global_forwarding[0].tcp_redir_ports='1:65535'
uci set passwall2.@global_forwarding[0].udp_redir_ports='1:65535'
uci set passwall2.@global[0].remote_dns='8.8.4.4'

# Новое правило Russia
uci set passwall2.Russia=shunt_rules
uci set passwall2.Russia.network='tcp,udp'
uci set passwall2.Russia.remarks='Russia'
uci set passwall2.Russia.domain_list='geosite:category-ru'
uci set passwall2.Russia.ip_list='geoip:ru'

# Направлять Russia в direct
uci set passwall2.rulenode.Russia='_direct'

uci commit passwall2
uci commit system
uci commit network

echo -e "${YELLOW}** Installation completed **${NC}"
echo -e "${MAGENTA}Customized for frenzydrive/openwrt-scripts${NC}"

rm -f /tmp/install_passwall2.sh
rm passwalls.sh

/sbin/reload_config
