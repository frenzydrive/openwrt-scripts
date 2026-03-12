#!/bin/bash
set -euo pipefail

# Цвета для логов
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "$1"; }

# 1. Восстанавливаем системные репозитории (без них не встанет dnsmasq-full)
log "${GREEN}Restoring system repositories...${NC}"
cat > /etc/apk/repositories.d/distfeeds.list <<EOF
https://downloads.openwrt.org/releases/25.12.0/targets/mediatek/filogic/packages
https://downloads.openwrt.org/releases/25.12.0/packages/aarch64_cortex-a53/base
https://downloads.openwrt.org/releases/25.12.0/packages/aarch64_cortex-a53/luci
https://downloads.openwrt.org/releases/25.12.0/packages/aarch64_cortex-a53/packages
https://downloads.openwrt.org/releases/25.12.0/packages/aarch64_cortex-a53/routing
https://downloads.openwrt.org/releases/25.12.0/packages/aarch64_cortex-a53/telephony
EOF

# 2. Установка зависимостей и PassWall
log "${GREEN}Installing dependencies and PassWall2...${NC}"
cd /tmp

# Удаляем стандартный dnsmasq
apk del dnsmasq || true

# Скачиваем пакеты напрямую
# Используем зеркало downloads.sourceforge.net для стабильности
BASE_URL="https://downloads.sourceforge.net/project/openwrt-passwall-build/releases/packages-25.12/aarch64_cortex-a53"

wget -qO passwall2.apk "$BASE_URL/passwall_packages/passwall2_2.0-86_all.apk"
wget -qO luci-passwall2.apk "$BASE_URL/passwall_luci/luci-app-passwall2_2.0-86_all.apk"

# Устанавливаем всё разом. Зависимости (ipset, xray и т.д.) подтянутся из официальных реп.
apk add --allow-untrusted \
    dnsmasq-full \
    ipset \
    wget-ssl \
    unzip \
    ca-bundle \
    kmod-nft-socket \
    kmod-nft-tproxy \
    ./passwall2.apk \
    ./luci-passwall2.apk

# 3. Базовая настройка UCI
log "${GREEN}Applying configuration...${NC}"
uci set passwall2.Russia='shunt_rules'
uci set passwall2.Russia.remarks='Russia'
uci set passwall2.Russia.domain_list='geosite:category-ru'
uci set passwall2.Russia.ip_list='geoip:ru'
uci set passwall2.rulenode.Russia='_direct'
uci commit passwall2

/sbin/reload_config
log "${YELLOW}Done! WR3000 is ready.${NC}"
