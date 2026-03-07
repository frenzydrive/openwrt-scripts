#!/bin/sh

# ===== Colors =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ===== Longevity tunables =====
OVERLAY_OPTS='noatime,nodiratime,commit=60'
LOG_SIZE='32'

pause() { printf "\nPress Enter to continue..."; read _; }

banner() {
    clear
    echo "${YELLOW}
    ______     __  ____              __
   / ____/  __/ /_/ __ \\____  ____  / /_
  / __/ | |/_/ __/ /_/ / __ \\/ __ \\/ __/
 / /____>  </ /_/ _, _/ /_/ / /_/ / /_
/_____/_/|_|\\__/_/ |_|\\____/\\____/\\__/
${NC}"
    echo "${CYAN}• OpenWrt Extroot Installer •${NC}"
    echo "--------------------------------------"
}

is_installed() { opkg list-installed 2>/dev/null | grep -q "^$1 "; }

install_missing_pkgs() {
    REQUIRED_PKGS="
kmod-usb-storage
kmod-usb-storage-extras
kmod-usb-storage-uas
kmod-usb-ohci
kmod-usb-uhci
e2fsprogs
kmod-fs-ext4
block-mount
lsblk
usbutils
fdisk
nano-full
"

    MISSING=""
    for pkg in $REQUIRED_PKGS; do
        if ! is_installed "$pkg"; then
            MISSING="$MISSING $pkg"
        fi
    done

    if [ -n "$MISSING" ]; then
        echo -e "${YELLOW}Installing missing packages:${NC}$MISSING"
        opkg update || return 1
        opkg install $MISSING || return 1
    else
        echo -e "${GREEN}All required packages already installed.${NC}"
    fi
    return 0
}

pick_disk() {
    # List sd* disks only
    DISKS="$(lsblk -o NAME,SIZE,MODEL,TYPE | awk '$4=="disk" && $1 ~ /^sd/ {print "/dev/"$1"  "$2"  "$3}')"
    [ -n "$DISKS" ] || return 1

    echo -e "${CYAN}Detected storage devices:${NC}"
    echo "$DISKS" | sed 's/^/  - /'
    echo

    # Default: first disk
    DISK="$(echo "$DISKS" | awk 'NR==1{print $1}')"

    echo -e "${YELLOW}Selected by default:${NC} $DISK"
    printf "Use this disk? (y/N): "
    read ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || return 2

    echo "$DISK"
    return 0
}

ensure_rc_local_remount() {
    [ -f /etc/rc.local ] || {
        cat > /etc/rc.local <<'EOF'
#!/bin/sh
exit 0
EOF
        chmod +x /etc/rc.local
    }

    if ! grep -q "extroot-tune: remount /overlay" /etc/rc.local; then
        sed -i "/^exit 0$/i\\
# extroot-tune: remount /overlay with flash-friendly options\\
mountpoint -q /overlay && mount -o remount,${OVERLAY_OPTS} /overlay 2>/dev/null || true\\
" /etc/rc.local
        chmod +x /etc/rc.local
    fi
}

configure_fstab_extroot() {
    PART="$1"

    echo -e "${YELLOW}Generating /etc/config/fstab (block detect)...${NC}"
    block detect > /etc/config/fstab

    UUID="$(block info "$PART" 2>/dev/null | sed -n 's/.*UUID="\([^"]*\)".*/\1/p' | head -n1)"
    [ -n "$UUID" ] || return 1

    # Find mount section that matches this UUID, else create new
    idx=""
    i=0
    while uci -q get "fstab.@mount[$i]" >/dev/null 2>&1; do
        cur_uuid="$(uci -q get "fstab.@mount[$i].uuid" 2>/dev/null || true)"
        if [ "$cur_uuid" = "$UUID" ]; then
            idx="$i"
            break
        fi
        i=$((i+1))
    done

    if [ -z "$idx" ]; then
        uci add fstab mount >/dev/null
        idx="-1"
        uci set "fstab.@mount[$idx].uuid=$UUID"
    fi

    uci set "fstab.@mount[$idx].target=/overlay"
    uci set "fstab.@mount[$idx].enabled=1"
    uci set "fstab.@mount[$idx].options=$OVERLAY_OPTS"

    # Flash longevity defaults
    uci -q set fstab.@global[0].auto_swap='0' 2>/dev/null || true
    uci commit fstab

    return 0
}

apply_longevity_tweaks() {
    # Keep logs in RAM
    uci -q delete system.@system[0].log_file 2>/dev/null || true
    uci -q set system.@system[0].log_size="$LOG_SIZE" 2>/dev/null || true
    uci -q commit system 2>/dev/null || true

    ensure_rc_local_remount

    # Passive log scan
    LOGS_FOUND="$(find /overlay -type f \( -name '*.log' -o -name '*access*' -o -name '*error*' \) 2>/dev/null | head -n 5 || true)"
    if [ -n "$LOGS_FOUND" ]; then
        echo -e "${YELLOW}[WARN] Found possible log files on /overlay (may increase writes):${NC}"
        echo "$LOGS_FOUND"
    fi
}

do_install() {
    [ "$(id -u)" = "0" ] || { echo -e "${RED}Run as root!${NC}"; return 1; }

    # ---- Check if extroot already active ----
    if block info 2>/dev/null | grep -qE 'MOUNT="/overlay".*TYPE="ext4"'; then
        echo -e "${GREEN}Extroot already active: /overlay is on ext4 USB.${NC}"
        echo -e "${YELLOW}Installation skipped.${NC}"
        return 0
    fi

    install_missing_pkgs || { echo -e "${RED}Package install failed.${NC}"; return 1; }

    DISK="$(pick_disk)" || {
        rc=$?
        [ $rc -eq 2 ] && echo -e "${YELLOW}Cancelled by user.${NC}"
        [ $rc -eq 1 ] && echo -e "${RED}No USB disk detected.${NC}"
        return 1
    }

    PART="${DISK}1"
    MNT="/mnt/usb"

    echo -e "${YELLOW}WARNING:${NC} This will (re)partition/format ${DISK} if needed."
    printf "Type YES to continue: "
    read confirm
    [ "$confirm" = "YES" ] || { echo -e "${YELLOW}Cancelled.${NC}"; return 1; }

    # Unmount if mounted
    mount | grep -q "^$PART " && umount "$PART" 2>/dev/null || true
    mount | grep -q " $MNT " && umount "$MNT" 2>/dev/null || true

    # Partition if missing
    if [ ! -b "$PART" ]; then
        echo -e "${YELLOW}Creating MBR + single primary partition...${NC}"
        printf 'o\nn\np\n1\n\n\nw\n' | fdisk "$DISK" >/dev/null 2>&1
        sleep 2
    fi
    [ -b "$PART" ] || { echo -e "${RED}Partition $PART not found after fdisk.${NC}"; return 1; }

    # Format if not ext4
    FSTYPE="$(block info "$PART" 2>/dev/null | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p' | head -n1)"
    if [ "$FSTYPE" != "ext4" ]; then
        echo -e "${YELLOW}Formatting $PART as ext4 (no reserved blocks)...${NC}"
        mkfs.ext4 -F -m 0 "$PART" || { echo -e "${RED}mkfs.ext4 failed.${NC}"; return 1; }
    else
        echo -e "${GREEN}Filesystem already ext4.${NC}"
    fi

    # Mount temp
    mkdir -p "$MNT"
    mount "$PART" "$MNT" || { echo -e "${RED}Mount failed.${NC}"; return 1; }

    # Copy overlay once
    if [ ! -d "$MNT/upper" ]; then
        echo -e "${YELLOW}Copying /overlay to USB...${NC}"
        tar -C /overlay -cpf - . | tar -C "$MNT" -xpf - || { umount "$MNT" 2>/dev/null; echo -e "${RED}Overlay copy failed.${NC}"; return 1; }
        sync
    else
        echo -e "${GREEN}Overlay already copied (upper exists).${NC}"
    fi

    umount "$MNT" 2>/dev/null || true

    configure_fstab_extroot "$PART" || { echo -e "${RED}Failed to configure fstab extroot.${NC}"; return 1; }
    apply_longevity_tweaks

    echo -e "${GREEN}Done. Rebooting...${NC}"
    sleep 2
    reboot
    return 0
}

check_status() {
    banner
    echo -e "${GREEN}Status report${NC}"
    echo "--------------------------------------"

    echo -e "${CYAN}[Overlay mount]${NC}"
    mount | grep -E ' on /overlay | overlayfs:' || echo "  (no overlay mounts found?)"
    echo

    echo -e "${CYAN}[Block info]${NC}"
    block info | grep -E 'sda1|/overlay' || true
    echo

    echo -e "${CYAN}[fstab]${NC}"
    if [ -f /etc/config/fstab ]; then
        uci -q show fstab | sed 's/^/  /'
    else
        echo "  /etc/config/fstab not found"
    fi
    echo

    echo -e "${CYAN}[Swap]${NC}"
    free | sed 's/^/  /'
    echo
    swapon -s | sed 's/^/  /'
    echo

    echo -e "${CYAN}[System logging]${NC}"
    lf="$(uci -q get system.@system[0].log_file 2>/dev/null || true)"
    ls="$(uci -q get system.@system[0].log_size 2>/dev/null || true)"
    [ -n "$lf" ] && echo -e "  log_file: ${YELLOW}$lf${NC}" || echo -e "  log_file: ${GREEN}(not set)${NC} (logs in RAM)"
    [ -n "$ls" ] && echo "  log_size: $ls" || echo "  log_size: (not set)"
    echo

    echo -e "${CYAN}[rc.local extroot remount]${NC}"
    if [ -f /etc/rc.local ]; then
        if grep -q "extroot-tune: remount /overlay" /etc/rc.local; then
            echo -e "  ${GREEN}present${NC}"
            grep -n "extroot-tune: remount /overlay\|mount -o remount" /etc/rc.local | sed 's/^/  /'
        else
            echo -e "  ${YELLOW}not present${NC}"
        fi
    else
        echo -e "  ${YELLOW}/etc/rc.local not found${NC}"
    fi
    echo

    echo -e "${CYAN}[Potential log files on /overlay]${NC}"
    logs="$(find /overlay -type f \( -name '*.log' -o -name '*access*' -o -name '*error*' \) 2>/dev/null | head -n 20 || true)"
    if [ -n "$logs" ]; then
        echo -e "${YELLOW}  Found:${NC}"
        echo "$logs" | sed 's/^/  /'
    else
        echo -e "${GREEN}  None found${NC}"
    fi
    echo
}

while true; do
    banner
    echo "1) Install / Configure Extroot (with longevity tweaks)"
    echo "2) Check status"
    echo "3) Exit"
    echo "--------------------------------------"
    printf "Select option: "
    read opt

    case "$opt" in
        1) do_install; pause ;;
        2) check_status; pause ;;
        3) exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
    esac
done
