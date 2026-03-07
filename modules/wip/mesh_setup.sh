#!/bin/sh
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_NAME="OpenWrt Mesh Setup"
BACKUP_DIR="/root/mesh-backup-$(date +%Y%m%d-%H%M%S)"

require_root() {
    [ "$(id -u)" -eq 0 ] || {
        echo -e "${RED}Please run this script as root.${NC}"
        exit 1
    }
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo -e "${RED}Required command not found: $1${NC}"
        exit 1
    }
}

pause_enter() {
    echo
    printf "Press Enter to continue..."
    read _
}

ask_text() {
    title="$1"
    description="$2"
    recommended="$3"
    default="$4"

    echo
    echo -e "${CYAN}${title}${NC}"
    echo "$description"
    echo "Recommended: $recommended"
    printf "Enter value [%s]: " "$default"
    read value
    [ -n "$value" ] || value="$default"
    REPLY="$value"
}

ask_yes_no() {
    title="$1"
    description="$2"
    default="$3"

    echo
    echo -e "${CYAN}${title}${NC}"
    echo "$description"
    if [ "$default" = "y" ]; then
        printf "Choose [Y/n]: "
    else
        printf "Choose [y/N]: "
    fi

    read answer
    case "$answer" in
        y|Y|yes|YES) REPLY="y" ;;
        n|N|no|NO) REPLY="n" ;;
        "") REPLY="$default" ;;
        *) REPLY="$default" ;;
    esac
}

check_base_tools() {
    require_cmd uci
    require_cmd opkg
    require_cmd wifi
    require_cmd awk
    require_cmd grep
    require_cmd cut
}

detect_installed_wpad() {
    opkg list-installed | awk '/^wpad/ {print $1; exit}'
}

find_candidate_wpad() {
    for pkg in wpad-mbedtls wpad-openssl wpad-wolfssl wpad-mesh-mbedtls wpad; do
        if opkg list | awk '{print $1}' | grep -qx "$pkg"; then
            echo "$pkg"
            return 0
        fi
    done
    return 1
}

ensure_mesh_packages() {
    local installed_wpad candidate

    echo
    echo -e "${CYAN}Checking required packages for mesh...${NC}"

    installed_wpad="$(detect_installed_wpad || true)"

    if [ -n "$installed_wpad" ]; then
        echo -e "${GREEN}Detected installed wpad package: $installed_wpad${NC}"
        return 0
    fi

    echo -e "${YELLOW}No installed wpad package was detected.${NC}"
    echo "802.11s mesh requires a mesh-capable wpad package."

    candidate="$(find_candidate_wpad || true)"

    if [ -z "$candidate" ]; then
        echo -e "${RED}Could not find a suitable wpad package in current repositories.${NC}"
        echo "Please install a mesh-capable wpad package manually and run the script again."
        exit 1
    fi

    echo "Recommended package: $candidate"
    ask_yes_no \
        "Install required mesh package automatically?" \
        "The script can install the recommended wpad package now." \
        "y"

    if [ "$REPLY" = "y" ]; then
        echo -e "${GREEN}Updating package lists...${NC}"
        opkg update
        echo -e "${GREEN}Installing $candidate ...${NC}"
        opkg install "$candidate"
    else
        echo -e "${RED}Package installation cancelled.${NC}"
        exit 1
    fi
}

backup_configs() {
    mkdir -p "$BACKUP_DIR"
    cp -f /etc/config/wireless "$BACKUP_DIR"/wireless.bak
    cp -f /etc/config/network  "$BACKUP_DIR"/network.bak
    cp -f /etc/config/dhcp     "$BACKUP_DIR"/dhcp.bak
    echo -e "${GREEN}Backups saved to: $BACKUP_DIR${NC}"
}

list_radios() {
    uci show wireless | grep "=wifi-device" | cut -d. -f2 | cut -d= -f1
}

radio_enabled() {
    radio="$1"
    disabled="$(uci -q get wireless."$radio".disabled || true)"
    [ "$disabled" != "1" ]
}

pick_radio() {
    echo
    echo -e "${CYAN}Available radios${NC}"
    i=1
    RADIOS=""
    for r in $(list_radios); do
        channel="$(uci -q get wireless."$r".channel || echo '?')"
        band="$(uci -q get wireless."$r".band || echo 'unknown')"
        hwmode="$(uci -q get wireless."$r".hwmode || echo '')"
        if radio_enabled "$r"; then
            state="enabled"
        else
            state="disabled"
        fi
        echo "  $i) $r | band: $band $hwmode | channel: $channel | $state"
        RADIOS="$RADIOS $r"
        i=$((i+1))
    done

    echo
    echo "This radio will be used for the internal wireless link between mesh routers."
    echo "Recommended: use the same radio number on all routers."
    printf "Select radio number [1]: "
    read num
    [ -n "$num" ] || num="1"

    i=1
    for r in $RADIOS; do
        if [ "$i" = "$num" ]; then
            SELECTED_RADIO="$r"
            return 0
        fi
        i=$((i+1))
    done

    echo -e "${RED}Invalid radio selection.${NC}"
    exit 1
}

cleanup_old_generated_sections() {
    echo -e "${YELLOW}Removing previously generated mesh sections from wireless config...${NC}"
    sections="$(uci show wireless | grep "mesh_auto='1'" | cut -d. -f2 | cut -d= -f1 || true)"
    for s in $sections; do
        uci delete wireless."$s"
    done
    uci commit wireless
}

set_radio_defaults() {
    radio="$1"
    uci set wireless."$radio".disabled='0'
}

create_mesh_iface() {
    radio="$1"
    mesh_name="$2"
    mesh_password="$3"

    section="$(uci add wireless wifi-iface)"
    uci set wireless."$section".device="$radio"
    uci set wireless."$section".mode='mesh'
    uci set wireless."$section".mesh_id="$mesh_name"
    uci set wireless."$section".network='lan'
    uci set wireless."$section".encryption='sae'
    uci set wireless."$section".key="$mesh_password"
    uci set wireless."$section".mesh_auto='1'
    uci set wireless."$section".disabled='0'
}

create_ap_iface() {
    radio="$1"
    ssid="$2"
    key="$3"

    section="$(uci add wireless wifi-iface)"
    uci set wireless."$section".device="$radio"
    uci set wireless."$section".mode='ap'
    uci set wireless."$section".network='lan'
    uci set wireless."$section".ssid="$ssid"
    uci set wireless."$section".encryption='psk2'
    uci set wireless."$section".key="$key"
    uci set wireless."$section".mesh_auto='1'
    uci set wireless."$section".disabled='0'
}

show_summary_gateway() {
    echo
    echo -e "${CYAN}Summary${NC}"
    echo "Role: main mesh router"
    echo "Radio: $SELECTED_RADIO"
    echo "Mesh name: $MESH_NAME"
    echo "Create client Wi-Fi: $CREATE_AP"
    [ "$CREATE_AP" = "y" ] && echo "Client Wi-Fi name: $AP_SSID"
    echo
}

show_summary_node() {
    echo
    echo -e "${CYAN}Summary${NC}"
    echo "Role: secondary mesh router"
    echo "Radio: $SELECTED_RADIO"
    echo "Mesh name: $MESH_NAME"
    echo "Main router IP: $MAIN_IP"
    echo "This router IP: $NODE_IP"
    echo "Create client Wi-Fi: $CREATE_AP"
    [ "$CREATE_AP" = "y" ] && echo "Client Wi-Fi name: $AP_SSID"
    echo
}

confirm_apply() {
    ask_yes_no \
        "Apply these settings now?" \
        "The script will modify wireless, network and DHCP settings on this router." \
        "y"

    [ "$REPLY" = "y" ] || {
        echo -e "${YELLOW}Operation cancelled.${NC}"
        return 1
    }
}

show_status() {
    echo
    echo "=== Mesh Status ==="
    echo

    mesh_section="$(uci show wireless | grep ".mode='mesh'" | head -n1 | cut -d. -f2 | cut -d= -f1)"
    ap_sections="$(uci show wireless | grep ".mode='ap'" | cut -d. -f2 | cut -d= -f1 || true)"

    lan_ip="$(uci -q get network.lan.ipaddr || echo 'not set')"
    lan_mask="$(uci -q get network.lan.netmask || echo 'not set')"
    lan_gw="$(uci -q get network.lan.gateway || echo 'not set')"
    lan_dns="$(uci -q get network.lan.dns || echo 'not set')"
    dhcp_ignore="$(uci -q get dhcp.lan.ignore || echo '0')"

    echo "Mesh interface:"
    if [ -n "$mesh_section" ]; then
        mesh_radio="$(uci -q get wireless.$mesh_section.device || echo 'unknown')"
        mesh_id="$(uci -q get wireless.$mesh_section.mesh_id || echo 'unknown')"
        mesh_enc="$(uci -q get wireless.$mesh_section.encryption || echo 'unknown')"
        mesh_disabled="$(uci -q get wireless.$mesh_section.disabled || echo '0')"

        echo "- Found: yes"
        echo "- Radio: $mesh_radio"
        echo "- Mesh network name: $mesh_id"
        echo "- Encryption: $mesh_enc"

        if [ "$mesh_disabled" = "1" ]; then
            echo "- Status: disabled"
        else
            echo "- Status: enabled"
        fi
    else
        echo "- Found: no"
    fi

    echo
    echo "Client Wi-Fi access points:"
    if [ -n "$ap_sections" ]; then
        for s in $ap_sections; do
            ssid="$(uci -q get wireless.$s.ssid || echo 'unknown')"
            radio="$(uci -q get wireless.$s.device || echo 'unknown')"
            disabled="$(uci -q get wireless.$s.disabled || echo '0')"

            if [ "$disabled" = "1" ]; then
                state="disabled"
            else
                state="enabled"
            fi

            echo "- SSID: $ssid (radio: $radio, status: $state)"
        done
    else
        echo "- No access points found"
    fi

    echo
    echo "LAN settings:"
    echo "- IP address: $lan_ip"
    echo "- Netmask: $lan_mask"
    echo "- Gateway: $lan_gw"
    echo "- DNS: $lan_dns"

    echo
    echo "DHCP:"
    if [ "$dhcp_ignore" = "1" ]; then
        echo "- DHCP server is disabled"
    else
        echo "- DHCP server is enabled"
    fi

    echo
    echo "Summary:"
    if [ -z "$mesh_section" ]; then
        echo "- Mesh is not configured on this router"
        if [ "$dhcp_ignore" = "1" ]; then
            echo "- This router currently looks like a secondary router or manually configured node without mesh"
        else
            echo "- This router currently looks like a normal main router or standard access point"
        fi
    else
        if [ "$dhcp_ignore" = "1" ]; then
            echo "- This router looks like a secondary mesh router"
        else
            echo "- This router looks like a main mesh router"
        fi

        if [ "$mesh_disabled" = "1" ]; then
            echo "- Warning: mesh interface exists but is disabled"
        fi
    fi
}

configure_gateway() {
    echo
    echo -e "${GREEN}Configuring main mesh router...${NC}"

    pick_radio

    ask_text \
        "Internal mesh network name" \
        "This is the internal wireless name used only between OpenWrt routers." \
        "Use a simple unique name like HomeMesh" \
        "HomeMesh"
    MESH_NAME="$REPLY"

    ask_text \
        "Mesh password" \
        "This password protects the internal wireless link between routers." \
        "Use a strong password with at least 8 characters" \
        "StrongMeshPass123"
    MESH_PASSWORD="$REPLY"

    ask_yes_no \
        "Create regular Wi-Fi for phones and laptops?" \
        "Mesh is only for communication between routers. Phones and laptops need a normal Wi-Fi network." \
        "y"
    CREATE_AP="$REPLY"

    if [ "$CREATE_AP" = "y" ]; then
        ask_text \
            "Client Wi-Fi name" \
            "This is the normal Wi-Fi network for phones, laptops and other devices." \
            "Use your home Wi-Fi name" \
            "HomeWiFi"
        AP_SSID="$REPLY"

        ask_text \
            "Client Wi-Fi password" \
            "This password will be used by phones, laptops and other devices." \
            "Use your normal home Wi-Fi password" \
            "StrongWiFiPass123"
        AP_KEY="$REPLY"
    fi

    show_summary_gateway
    confirm_apply || return 0

    backup_configs
    cleanup_old_generated_sections
    set_radio_defaults "$SELECTED_RADIO"
    create_mesh_iface "$SELECTED_RADIO" "$MESH_NAME" "$MESH_PASSWORD"

    if [ "$CREATE_AP" = "y" ]; then
        create_ap_iface "$SELECTED_RADIO" "$AP_SSID" "$AP_KEY"
    fi

    uci commit wireless
    uci commit network

    wifi reload
    /etc/init.d/network restart

    echo
    echo -e "${GREEN}Main mesh router configuration applied.${NC}"
    echo "DHCP remains enabled on this router."
    echo "Backup directory: $BACKUP_DIR"
}

configure_node() {
    echo
    echo -e "${GREEN}Configuring secondary mesh router...${NC}"

    pick_radio

    ask_text \
        "Internal mesh network name" \
        "This must exactly match the internal mesh network name on the main router." \
        "Use the same value as on the main router, for example HomeMesh" \
        "HomeMesh"
    MESH_NAME="$REPLY"

    ask_text \
        "Mesh password" \
        "This must exactly match the mesh password on the main router." \
        "Use the same value as on the main router" \
        "StrongMeshPass123"
    MESH_PASSWORD="$REPLY"

    ask_text \
        "Main router IP address" \
        "This is the LAN IP address of the main router that provides internet and DHCP." \
        "Usually 192.168.1.1" \
        "192.168.1.1"
    MAIN_IP="$REPLY"

    ask_text \
        "This router local IP address" \
        "This is the LAN IP address for the secondary router. It must be in the same subnet, but different from the main router." \
        "Usually 192.168.1.2 or the next free address" \
        "192.168.1.2"
    NODE_IP="$REPLY"

    ask_yes_no \
        "Create regular Wi-Fi for phones and laptops on this router?" \
        "This creates a normal Wi-Fi access point for client devices on this mesh router." \
        "y"
    CREATE_AP="$REPLY"

    if [ "$CREATE_AP" = "y" ]; then
        ask_text \
            "Client Wi-Fi name" \
            "For easier roaming, use the same Wi-Fi name as on the main router." \
            "Use the same SSID as the main router" \
            "HomeWiFi"
        AP_SSID="$REPLY"

        ask_text \
            "Client Wi-Fi password" \
            "For easier roaming, use the same Wi-Fi password as on the main router." \
            "Use the same Wi-Fi password as the main router" \
            "StrongWiFiPass123"
        AP_KEY="$REPLY"
    fi

    show_summary_node
    confirm_apply || return 0

    backup_configs
    cleanup_old_generated_sections
    set_radio_defaults "$SELECTED_RADIO"
    create_mesh_iface "$SELECTED_RADIO" "$MESH_NAME" "$MESH_PASSWORD"

    if [ "$CREATE_AP" = "y" ]; then
        create_ap_iface "$SELECTED_RADIO" "$AP_SSID" "$AP_KEY"
    fi

    uci set network.lan.ipaddr="$NODE_IP"
    uci set network.lan.netmask='255.255.255.0'
    uci set network.lan.gateway="$MAIN_IP"
    uci set network.lan.dns="$MAIN_IP"

    uci set dhcp.lan.ignore='1'

    uci commit wireless
    uci commit network
    uci commit dhcp

    wifi reload
    /etc/init.d/network restart
    /etc/init.d/dnsmasq restart

    echo
    echo -e "${GREEN}Secondary mesh router configuration applied.${NC}"
    echo "DHCP is disabled on this router."
    echo "Backup directory: $BACKUP_DIR"
}

main_menu() {
    while true; do
        echo
        echo "=== $SCRIPT_NAME ==="
        echo "1) Configure main mesh router"
        echo "2) Configure secondary mesh router"
        echo "3) Show current mesh status"
        echo "4) Exit"
        printf "Choose an option: "
        read choice

        case "$choice" in
            1) configure_gateway; pause_enter ;;
            2) configure_node; pause_enter ;;
            3) show_status; pause_enter ;;
            4) exit 0 ;;
            *) echo -e "${RED}Invalid option.${NC}" ;;
        esac
    done
}

require_root
check_base_tools
ensure_mesh_packages
main_menu
