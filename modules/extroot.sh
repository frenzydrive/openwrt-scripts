#!/bin/sh

# ============================================================
# extroot.sh
# Universal Extroot installer for OpenWrt 24.x and 25.x
#
# OpenWrt 24.x -> opkg strategy
# OpenWrt 25.x -> apk strategy
#
# WARNING:
# This script will erase the selected USB drive.
# ============================================================

# ===== Colors =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ===== Longevity tunables =====
OVERLAY_OPTS='noatime,nodiratime,commit=60'
LOG_SIZE='32'

# ===== Global vars =====
OPENWRT_RELEASE=""
OPENWRT_MAJOR=""
PKG_MGR=""

# Packages needed for extroot.
# Keep this list focused on real extroot requirements.
REQUIRED_PKGS="
block-mount
e2fsprogs
kmod-fs-ext4
kmod-usb-storage
kmod-usb-storage-extras
kmod-usb-storage-uas
kmod-usb3
kmod-usb-xhci-hcd
fdisk
lsblk
"

# Nice to have, but not required.
# If some of these are absent in a feed, the script will continue.
OPTIONAL_PKGS="
usbutils
nano-full
kmod-usb-ohci
kmod-usb-uhci
"

pause() {
	printf "\nPress Enter to continue..."
	read _
}

banner() {
	clear
	echo "${YELLOW}"
	echo " ______      __                  __ "
	echo "/ ____/  __ / /_ _____ ____ ___ / /_"
	echo "/ __/ | |/_// __// ___// __ \`__ \ / __/"
	echo "/ /____>  < / /_ / /   / / / / / / /_  "
	echo "/_____/_/|_| \__//_/   /_/ /_/ /_/\__/  "
	echo "${NC}"
	echo "OpenWrt Extroot installer"
	echo "--------------------------------------"
}

check_root() {
	if [ "$(id -u)" != "0" ]; then
		echo -e "${RED}Run as root!${NC}"
		return 1
	fi

	return 0
}

detect_openwrt_strategy() {
	if [ ! -r /etc/openwrt_release ]; then
		echo -e "${RED}Cannot read /etc/openwrt_release. This does not look like OpenWrt.${NC}"
		return 1
	fi

	# shellcheck disable=SC1091
	. /etc/openwrt_release

	OPENWRT_RELEASE="${DISTRIB_RELEASE:-unknown}"
	OPENWRT_MAJOR="$(echo "$OPENWRT_RELEASE" | cut -d. -f1)"

	echo -e "${GREEN}Detected OpenWrt version:${NC} $OPENWRT_RELEASE"

	case "$OPENWRT_MAJOR" in
		24)
			PKG_MGR="opkg"
			echo -e "${GREEN}Selected strategy:${NC} OpenWrt 24.x / opkg"
			;;
		25)
			PKG_MGR="apk"
			echo -e "${GREEN}Selected strategy:${NC} OpenWrt 25.x / apk"
			;;
		*)
			echo -e "${YELLOW}Unsupported or unknown OpenWrt major version: $OPENWRT_MAJOR${NC}"
			echo -e "${YELLOW}Trying to auto-detect package manager...${NC}"

			if command -v apk >/dev/null 2>&1; then
				PKG_MGR="apk"
			elif command -v opkg >/dev/null 2>&1; then
				PKG_MGR="opkg"
			else
				echo -e "${RED}Neither apk nor opkg found.${NC}"
				return 1
			fi

			echo -e "${YELLOW}Auto-detected package manager:${NC} $PKG_MGR"
			;;
	esac

	if [ "$PKG_MGR" = "opkg" ] && ! command -v opkg >/dev/null 2>&1; then
		echo -e "${RED}OpenWrt 24.x strategy selected, but opkg was not found.${NC}"
		return 1
	fi

	if [ "$PKG_MGR" = "apk" ] && ! command -v apk >/dev/null 2>&1; then
		echo -e "${RED}OpenWrt 25.x strategy selected, but apk was not found.${NC}"
		return 1
	fi

	return 0
}

pkg_update() {
	if [ "$PKG_MGR" = "apk" ]; then
		apk update
	else
		opkg update
	fi
}

pkg_install() {
	if [ "$PKG_MGR" = "apk" ]; then
		apk add "$@"
	else
		opkg install "$@"
	fi
}

pkg_is_installed() {
	pkg="$1"

	if [ "$PKG_MGR" = "apk" ]; then
		apk info -e "$pkg" >/dev/null 2>&1
	else
		opkg list-installed 2>/dev/null | grep -q "^$pkg "
	fi
}

install_required_pkgs() {
	MISSING=""

	for pkg in $REQUIRED_PKGS; do
		if ! pkg_is_installed "$pkg"; then
			MISSING="$MISSING $pkg"
		fi
	done

	if [ -z "$MISSING" ]; then
		echo -e "${GREEN}All required packages already installed.${NC}"
		return 0
	fi

	echo -e "${YELLOW}Missing required packages:${NC}$MISSING"
	echo -e "${GREEN}Updating package lists using ${PKG_MGR}...${NC}"

	pkg_update || {
		echo -e "${RED}Failed to update package lists using ${PKG_MGR}.${NC}"
		return 1
	}

	echo -e "${GREEN}Installing required packages using ${PKG_MGR}...${NC}"

	pkg_install $MISSING || {
		echo -e "${RED}Failed to install required packages using ${PKG_MGR}.${NC}"
		return 1
	}

	return 0
}

install_optional_pkgs() {
	MISSING=""

	for pkg in $OPTIONAL_PKGS; do
		if ! pkg_is_installed "$pkg"; then
			MISSING="$MISSING $pkg"
		fi
	done

	if [ -z "$MISSING" ]; then
		return 0
	fi

	echo -e "${YELLOW}Optional packages:${NC}$MISSING"
	echo -e "${YELLOW}Trying to install optional packages. Failures here are not critical.${NC}"

	pkg_install $MISSING || {
		echo -e "${YELLOW}Some optional packages were not installed. Continuing.${NC}"
		return 0
	}

	return 0
}

is_extroot_active() {
	block info 2>/dev/null | grep -qE 'MOUNT="/overlay".*TYPE="ext4"'
}

pick_disk() {
	DISKS="$(lsblk -dn -o NAME,SIZE,TYPE 2>/dev/null | awk '$3=="disk" && $1 ~ /^sd/ && $2!="0B" {print "/dev/"$1" "$2}')"

	[ -n "$DISKS" ] || return 1

	echo -e "${CYAN}Detected storage devices:${NC}" >&2
	echo "$DISKS" | sed 's/^/ - /' >&2
	echo >&2

	DISK="$(echo "$DISKS" | awk 'NR==1{print $1}')"

	echo -e "${YELLOW}Selected by default:${NC} $DISK" >&2
	printf "Use this disk? (y/N): " >&2
	read ans

	[ "$ans" = "y" ] || [ "$ans" = "Y" ] || return 2

	echo "$DISK"
	return 0
}

wait_for_usb_storage() {
	echo -e "${YELLOW}Waiting for USB storage to appear...${NC}"

	sleep 5

	block info >/dev/null 2>&1 || true

	for i in $(seq 1 10); do
		DISKS="$(lsblk -dn -o NAME,SIZE,TYPE 2>/dev/null | awk '$3=="disk" && $1 ~ /^sd/ && $2!="0B" {print "/dev/"$1" "$2}')"

		if [ -n "$DISKS" ]; then
			return 0
		fi

		sleep 2
	done

	return 1
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

	echo -e "${YELLOW}Generating /etc/config/fstab using block detect...${NC}"

	block detect > /etc/config/fstab

	UUID="$(block info "$PART" 2>/dev/null | sed -n 's/.*UUID="\([^"]*\)".*/\1/p' | head -n1)"

	if [ -z "$UUID" ]; then
		echo -e "${RED}Could not detect UUID for $PART.${NC}"
		return 1
	fi

	idx=""
	i=0

	while uci -q get "fstab.@mount[$i]" >/dev/null 2>&1; do
		cur_uuid="$(uci -q get "fstab.@mount[$i].uuid" 2>/dev/null || true)"

		if [ "$cur_uuid" = "$UUID" ]; then
			idx="$i"
			break
		fi

		i=$((i + 1))
	done

	if [ -z "$idx" ]; then
		uci add fstab mount >/dev/null
		idx="-1"
		uci set "fstab.@mount[$idx].uuid=$UUID"
	fi

	uci set "fstab.@mount[$idx].target=/overlay"
	uci set "fstab.@mount[$idx].enabled=1"
	uci set "fstab.@mount[$idx].options=$OVERLAY_OPTS"

	uci -q set fstab.@global[0].auto_swap='0' 2>/dev/null || true

	uci commit fstab

	return 0
}

apply_longevity_tweaks() {
	echo -e "${YELLOW}Applying longevity tweaks...${NC}"

	uci -q delete system.@system[0].log_file 2>/dev/null || true
	uci -q set system.@system[0].log_size="$LOG_SIZE" 2>/dev/null || true
	uci -q commit system 2>/dev/null || true

	ensure_rc_local_remount

	LOGS_FOUND="$(find /overlay -type f \( -name '*.log' -o -name '*access*' -o -name '*error*' \) 2>/dev/null | head -n 5 || true)"

	if [ -n "$LOGS_FOUND" ]; then
		echo -e "${YELLOW}[WARN] Found possible log files on /overlay. They may increase writes:${NC}"
		echo "$LOGS_FOUND"
	fi
}

unmount_old_mounts() {
	DISK="$1"
	PART="$2"
	MNT="$3"

	mount | grep -q "^$PART " && umount "$PART" 2>/dev/null || true
	mount | grep -q " $MNT " && umount "$MNT" 2>/dev/null || true

	# Try to unmount existing partitions from selected disk.
	for dev in "${DISK}"*; do
		[ "$dev" = "$DISK" ] && continue
		[ -b "$dev" ] || continue
		umount "$dev" 2>/dev/null || true
	done
}

partition_disk() {
	DISK="$1"
	PART="$2"

	echo -e "${YELLOW}Repartitioning ${DISK}...${NC}"

	printf 'o\nn\np\n1\n\n\nw\n' | fdisk "$DISK" >/dev/null 2>&1

	sleep 2
	block info >/dev/null 2>&1 || true

	if [ ! -b "$PART" ]; then
		echo -e "${RED}Partition $PART not found after fdisk.${NC}"
		return 1
	fi

	return 0
}

format_partition() {
	PART="$1"

	echo -e "${YELLOW}Formatting $PART as ext4 with zero reserved blocks...${NC}"

	mkfs.ext4 -F -m 0 "$PART" || {
		echo -e "${RED}mkfs.ext4 failed.${NC}"
		return 1
	}

	sleep 2

	return 0
}

copy_overlay_to_usb() {
	PART="$1"
	MNT="$2"

	mkdir -p "$MNT"

	mount "$PART" "$MNT" || {
		echo -e "${RED}Mount failed: $PART -> $MNT.${NC}"
		return 1
	}

	if [ ! -d "$MNT/upper" ]; then
		echo -e "${YELLOW}Copying /overlay to USB...${NC}"

		tar -C /overlay -cpf - . | tar -C "$MNT" -xpf - || {
			umount "$MNT" 2>/dev/null || true
			echo -e "${RED}Overlay copy failed.${NC}"
			return 1
		}

		sync
	else
		echo -e "${GREEN}Overlay already copied. Directory 'upper' exists.${NC}"
	fi

	umount "$MNT" 2>/dev/null || true

	return 0
}

do_install() {
	check_root || return 1
	detect_openwrt_strategy || return 1

	if is_extroot_active; then
		echo -e "${GREEN}Extroot already active: /overlay is on ext4 USB.${NC}"
		echo -e "${YELLOW}Installation skipped.${NC}"
		return 0
	fi

	install_required_pkgs || {
		echo -e "${RED}Required package installation failed.${NC}"
		return 1
	}

	install_optional_pkgs

	wait_for_usb_storage || {
		echo -e "${RED}No USB disk detected.${NC}"
		return 1
	}

	DISK="$(pick_disk)"
	rc="$?"

	if [ "$rc" = "2" ]; then
		echo -e "${YELLOW}Cancelled by user.${NC}"
		return 1
	fi

	if [ "$rc" = "1" ]; then
		echo -e "${RED}No USB disk detected.${NC}"
		return 1
	fi

	PART="${DISK}1"
	MNT="/mnt/usb"

	echo
	echo -e "${RED}WARNING:${NC} This will erase all data on ${DISK}."
	printf "Type YES to continue: "
	read confirm

	if [ "$confirm" != "YES" ]; then
		echo -e "${YELLOW}Cancelled.${NC}"
		return 1
	fi

	unmount_old_mounts "$DISK" "$PART" "$MNT" || return 1
	partition_disk "$DISK" "$PART" || return 1
	format_partition "$PART" || return 1
	copy_overlay_to_usb "$PART" "$MNT" || return 1

	configure_fstab_extroot "$PART" || {
		echo -e "${RED}Failed to configure fstab extroot.${NC}"
		return 1
	}

	apply_longevity_tweaks

	echo
	echo -e "${GREEN}Done.${NC}"
	echo -e "${YELLOW}Router will reboot now.${NC}"

	sleep 2
	reboot

	return 0
}

check_status() {
	banner

	echo -e "${GREEN}Status report${NC}"
	echo "--------------------------------------"

	echo -e "${CYAN}[OpenWrt version / strategy]${NC}"

	if [ -r /etc/openwrt_release ]; then
		# shellcheck disable=SC1091
		. /etc/openwrt_release
		echo " release: ${DISTRIB_RELEASE:-unknown}"
		echo " target : ${DISTRIB_TARGET:-unknown}"
		echo " arch   : ${DISTRIB_ARCH:-unknown}"
	else
		echo " /etc/openwrt_release not found"
	fi

	if command -v apk >/dev/null 2>&1; then
		echo " package manager available: apk"
	fi

	if command -v opkg >/dev/null 2>&1; then
		echo " package manager available: opkg"
	fi

	echo

	echo -e "${CYAN}[Overlay mount]${NC}"
	mount | grep -E ' on /overlay | overlayfs:' || echo " (no overlay mounts found?)"

	echo

	echo -e "${CYAN}[Disk usage]${NC}"
	df -h | sed 's/^/ /'

	echo

	echo -e "${CYAN}[Block info]${NC}"
	block info | grep -E 'sda|/overlay|UUID' || true

	echo

	echo -e "${CYAN}[fstab]${NC}"

	if [ -f /etc/config/fstab ]; then
		uci -q show fstab | sed 's/^/ /'
	else
		echo " /etc/config/fstab not found"
	fi

	echo

	echo -e "${CYAN}[Swap]${NC}"
	free | sed 's/^/ /'
	swapon -s 2>/dev/null | sed 's/^/ /'

	echo

	echo -e "${CYAN}[System logging]${NC}"
	lf="$(uci -q get system.@system[0].log_file 2>/dev/null || true)"
	ls="$(uci -q get system.@system[0].log_size 2>/dev/null || true)"

	if [ -n "$lf" ]; then
		echo -e " log_file: ${YELLOW}$lf${NC}"
	else
		echo -e " log_file: ${GREEN}(not set)${NC} — logs should stay in RAM"
	fi

	if [ -n "$ls" ]; then
		echo " log_size: $ls"
	else
		echo " log_size: (not set)"
	fi

	echo

	echo -e "${CYAN}[rc.local extroot remount]${NC}"

	if [ -f /etc/rc.local ]; then
		if grep -q "extroot-tune: remount /overlay" /etc/rc.local; then
			echo -e " ${GREEN}present${NC}"
			grep -n "extroot-tune: remount /overlay\|mount -o remount" /etc/rc.local | sed 's/^/ /'
		else
			echo -e " ${YELLOW}not present${NC}"
		fi
	else
		echo -e " ${YELLOW}/etc/rc.local not found${NC}"
	fi

	echo

	echo -e "${CYAN}[Potential log files on /overlay]${NC}"
	logs="$(find /overlay -type f \( -name '*.log' -o -name '*access*' -o -name '*error*' \) 2>/dev/null | head -n 20 || true)"

	if [ -n "$logs" ]; then
		echo -e "${YELLOW} Found:${NC}"
		echo "$logs" | sed 's/^/ /'
	else
		echo -e "${GREEN} None found${NC}"
	fi

	echo
}

while true; do
	banner

	echo "1) Install / Configure Extroot"
	echo "2) Check status"
	echo "3) Exit"
	echo "--------------------------------------"
	printf "Select option: "
	read opt

	case "$opt" in
		1)
			do_install
			pause
			;;
		2)
			check_status
			pause
			;;
		3)
			exit 0
			;;
		*)
			echo -e "${RED}Invalid option.${NC}"
			sleep 1
			;;
	esac
done
