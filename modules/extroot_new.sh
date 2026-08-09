#!/bin/sh

# ============================================================
# extroot.sh
# Universal + Safe Extroot installer for OpenWrt 24.x and 25.x
#
# OpenWrt 24.x -> opkg strategy
# OpenWrt 25.x -> apk strategy
#
# Based on the proven frenzydrive extroot.sh logic.
#
# Improvements over the previous version:
# - protects the system / boot disk from accidental formatting
# - lets you explicitly choose between multiple USB disks
# - preserves existing /etc/config/fstab instead of overwriting it
# - creates a named fstab.extroot entry by UUID
# - backs up and rolls back fstab if validation fails
# - validates the extroot configuration before reboot
# - copies the final fstab into the new external overlay
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
FSTAB_BACKUP=""
SAFE_DISKS_FILE=""

# Packages needed for extroot.
# Kept from the proven current script.
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
	clear 2>/dev/null || true
	echo "${YELLOW}"
	echo " ______      __                  __ "
	echo "/ ____/  __ / /_ _____ ____ ___ / /_"
	echo "/ __/ | |/_// __// ___// __ \`__ \ / __/"
	echo "/ /____>  < / /_ / /   / / / / / / /_  "
	echo "/_____/_/|_| \__//_/   /_/ /_/ /_/\__/  "
	echo "${NC}"
	echo "OpenWrt Extroot installer"
	echo "Universal + Safe edition"
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

# More robust than relying on one particular block-info field order.
is_extroot_active() {
	awk '
		$2 == "/overlay" && $3 == "ext4" { found=1 }
		END { exit(found ? 0 : 1) }
	' /proc/mounts 2>/dev/null && return 0

	block info 2>/dev/null |
	awk '
		/MOUNT="\/overlay"/ && /TYPE="ext4"/ { found=1 }
		END { exit(found ? 0 : 1) }
	'
}

# Convert /dev/sda1 -> /dev/sda.
# Only sdX disks are candidates in this script.
parent_sd_disk() {
	dev="$1"

	case "$dev" in
		/dev/sd[a-z])
			echo "$dev"
			return 0
			;;
		/dev/sd[a-z][0-9]*)
			echo "$dev" | sed 's/[0-9][0-9]*$//'
			return 0
			;;
	esac

	return 1
}

# Print sdX disks that must never be formatted.
#
# We protect disks that currently contain important system mountpoints,
# especially useful on x86 OpenWrt where /dev/sda may be the boot disk.
protected_disks() {
	{
		# Mounted system / boot paths.
		awk '
			$1 ~ "^/dev/" &&
			($2 == "/" || $2 == "/rom" || $2 == "/overlay" ||
			 $2 == "/boot" || $2 == "/boot/efi") {
				print $1
			}
		' /proc/mounts 2>/dev/null

		# block info may expose /rom or /overlay even when /proc/mounts
		# does not make the physical parent obvious.
		if command -v block >/dev/null 2>&1; then
			block info 2>/dev/null |
			awk '
				/MOUNT="\/rom"/ || /MOUNT="\/overlay"/ || /MOUNT="\/boot"/ {
					sub(/:$/, "", $1)
					print $1
				}
			'
		fi

		# lsblk is valuable on x86: a boot partition often appears as
		# /dev/sda1 mounted on /boot.
		if command -v lsblk >/dev/null 2>&1; then
			lsblk -nrpo NAME,MOUNTPOINT 2>/dev/null |
			awk '
				$2 == "/" || $2 == "/rom" || $2 == "/overlay" ||
				$2 == "/boot" || $2 == "/boot/efi" {
					print $1
				}
			'

			# Extra x86 protection: OpenWrt often boots with
			# root=PARTUUID=... even when the physical root partition is
			# not directly mounted as / or /rom. Resolve that PARTUUID/UUID
			# back to a block device and protect its parent disk.
			ROOT_SPEC="$(sed -n 's/.*[[:space:]]root=\([^[:space:]]*\).*/\1/p' /proc/cmdline 2>/dev/null | head -n1)"

			case "$ROOT_SPEC" in
				/dev/sd*)
					echo "$ROOT_SPEC"
					;;
				PARTUUID=*)
					ROOT_ID="${ROOT_SPEC#PARTUUID=}"
					lsblk -nrpo NAME,PARTUUID 2>/dev/null |
					awk -v id="$ROOT_ID" '$2 == id {print $1}'
					;;
				UUID=*)
					ROOT_ID="${ROOT_SPEC#UUID=}"
					lsblk -nrpo NAME,UUID 2>/dev/null |
					awk -v id="$ROOT_ID" '$2 == id {print $1}'
					;;
			esac
		fi
	} |
	while read dev; do
		parent_sd_disk "$dev" 2>/dev/null || true
	done |
	sort -u
}

disk_is_protected() {
	DISK_TO_CHECK="$1"

	protected_disks | grep -qx "$DISK_TO_CHECK"
}

list_candidate_disks() {
	lsblk -dn -o NAME,SIZE,TYPE 2>/dev/null |
	awk '$3=="disk" && $1 ~ /^sd[a-z]+$/ && $2!="0B" {print "/dev/"$1" "$2}'
}

# Safer replacement for "always choose the first /dev/sdX".
# UI goes to stderr because the selected disk is returned on stdout.
pick_disk() {
	ALL_DISKS="$(list_candidate_disks)"

	[ -n "$ALL_DISKS" ] || return 1

	SAFE_DISKS_FILE="/tmp/extroot-safe-disks.$$"
	: > "$SAFE_DISKS_FILE" || return 1

	echo -e "${CYAN}Detected storage devices:${NC}" >&2

	echo "$ALL_DISKS" |
	while read disk size; do
		[ -n "$disk" ] || continue

		if disk_is_protected "$disk"; then
			echo -e " - ${RED}[SYSTEM/PROTECTED]${NC} $disk $size" >&2
		else
			echo -e " - ${GREEN}[AVAILABLE]${NC}        $disk $size" >&2
			echo "$disk $size" >> "$SAFE_DISKS_FILE"
		fi
	done

	SAFE_COUNT="$(wc -l < "$SAFE_DISKS_FILE" 2>/dev/null | tr -d ' ')"

	if [ -z "$SAFE_COUNT" ] || [ "$SAFE_COUNT" -eq 0 ] 2>/dev/null; then
		rm -f "$SAFE_DISKS_FILE"
		echo -e "${RED}No safe USB disk is available.${NC}" >&2
		return 1
	fi

	echo >&2

	if [ "$SAFE_COUNT" -eq 1 ]; then
		DISK="$(awk 'NR==1{print $1}' "$SAFE_DISKS_FILE")"
		SIZE="$(awk 'NR==1{print $2}' "$SAFE_DISKS_FILE")"

		echo -e "${YELLOW}Selected:${NC} $DISK $SIZE" >&2
		printf "Use this disk? (y/N): " >&2
		read ans

		if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then
			rm -f "$SAFE_DISKS_FILE"
			return 2
		fi
	else
		echo -e "${YELLOW}More than one safe disk is available:${NC}" >&2

		awk '{printf " %d) %s %s\n", NR, $1, $2}' "$SAFE_DISKS_FILE" >&2
		echo >&2
		printf "Select disk number: " >&2
		read choice

		case "$choice" in
			''|*[!0-9]*)
				rm -f "$SAFE_DISKS_FILE"
				echo -e "${RED}Invalid selection.${NC}" >&2
				return 2
				;;
		esac

		DISK="$(sed -n "${choice}p" "$SAFE_DISKS_FILE" | awk '{print $1}')"

		if [ -z "$DISK" ]; then
			rm -f "$SAFE_DISKS_FILE"
			echo -e "${RED}Invalid selection.${NC}" >&2
			return 2
		fi
	fi

	rm -f "$SAFE_DISKS_FILE"

	# Final non-destructive safety check.
	if disk_is_protected "$DISK"; then
		echo -e "${RED}Safety check: $DISK is a system/protected disk. Refusing to use it.${NC}" >&2
		return 2
	fi

	echo "$DISK"
	return 0
}

wait_for_usb_storage() {
	echo -e "${YELLOW}Waiting for USB storage to appear...${NC}"

	sleep 5
	block info >/dev/null 2>&1 || true

	i=1
	while [ "$i" -le 10 ]; do
		DISKS="$(list_candidate_disks)"

		if [ -n "$DISKS" ]; then
			return 0
		fi

		sleep 2
		i=$((i + 1))
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
grep -qs ' /overlay ' /proc/mounts && mount -o remount,${OVERLAY_OPTS} /overlay 2>/dev/null || true\\
" /etc/rc.local

		chmod +x /etc/rc.local
	fi
}

backup_fstab() {
	if [ -f /etc/config/fstab ]; then
		FSTAB_BACKUP="/tmp/extroot-fstab.backup.$$"

		cp -a /etc/config/fstab "$FSTAB_BACKUP" || {
			echo -e "${RED}Could not back up /etc/config/fstab.${NC}"
			FSTAB_BACKUP=""
			return 1
		}
	else
		FSTAB_BACKUP="__NO_FSTAB__"
	fi

	return 0
}

restore_fstab() {
	if [ "$FSTAB_BACKUP" = "__NO_FSTAB__" ]; then
		rm -f /etc/config/fstab
		return 0
	fi

	if [ -n "$FSTAB_BACKUP" ] && [ -f "$FSTAB_BACKUP" ]; then
		cp -a "$FSTAB_BACKUP" /etc/config/fstab
		return $?
	fi

	return 1
}

cleanup_fstab_backup() {
	if [ -n "$FSTAB_BACKUP" ] &&
	   [ "$FSTAB_BACKUP" != "__NO_FSTAB__" ]; then
		rm -f "$FSTAB_BACKUP"
	fi

	FSTAB_BACKUP=""
}

get_partition_uuid() {
	PART="$1"

	block info "$PART" 2>/dev/null |
	sed -n 's/.*UUID="\([^"]*\)".*/\1/p' |
	head -n1
}

# Disable stale anonymous /overlay mount entries without deleting them.
# The new named fstab.extroot entry will become authoritative.
disable_stale_overlay_mounts() {
	i=0

	while uci -q get "fstab.@mount[$i]" >/dev/null 2>&1; do
		target="$(uci -q get "fstab.@mount[$i].target" 2>/dev/null || true)"

		if [ "$target" = "/overlay" ]; then
			uci -q set "fstab.@mount[$i].enabled=0"
		fi

		i=$((i + 1))
	done
}

# Preserve the existing fstab and only add/update a named extroot section.
configure_fstab_extroot() {
	PART="$1"

	UUID="$(get_partition_uuid "$PART")"

	if [ -z "$UUID" ]; then
		echo -e "${RED}Could not detect UUID for $PART.${NC}"
		return 1
	fi

	echo -e "${YELLOW}Configuring extroot in existing /etc/config/fstab...${NC}"

	backup_fstab || return 1
	touch /etc/config/fstab

	# Make sure a global section exists.
	if ! uci -q get 'fstab.@global[0]' >/dev/null 2>&1; then
		uci add fstab global >/dev/null || {
			echo -e "${RED}Could not create fstab global section.${NC}"
			restore_fstab >/dev/null 2>&1 || true
			return 1
		}
	fi

	disable_stale_overlay_mounts

	# Named section: easier to validate and does not depend on anonymous index.
	uci -q delete fstab.extroot
	uci set fstab.extroot='mount'
	uci set "fstab.extroot.uuid=$UUID"
	uci set 'fstab.extroot.target=/overlay'
	uci set 'fstab.extroot.fstype=ext4'
	uci set "fstab.extroot.options=$OVERLAY_OPTS"
	uci set 'fstab.extroot.enabled=1'
	uci set 'fstab.extroot.enabled_fsck=0'

	# Keep the original behavior: do not auto-enable swap.
	uci -q set fstab.@global[0].auto_swap='0' 2>/dev/null || true
	uci -q set fstab.@global[0].auto_mount='1' 2>/dev/null || true

	# Give USB storage a little time during boot, but preserve a larger
	# value if the user already configured one.
	CURRENT_DELAY="$(uci -q get fstab.@global[0].delay_root 2>/dev/null || true)"
	case "$CURRENT_DELAY" in
		''|0)
			uci -q set fstab.@global[0].delay_root='5' 2>/dev/null || true
			;;
	esac

	uci commit fstab || {
		echo -e "${RED}Could not commit extroot fstab configuration.${NC}"
		restore_fstab >/dev/null 2>&1 || true
		return 1
	}

	echo -e "${GREEN}Extroot UUID:${NC} $UUID"
	return 0
}

apply_longevity_tweaks() {
	echo -e "${YELLOW}Applying longevity tweaks...${NC}"

	# Keep system logs in RAM rather than writing a persistent log file.
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

	printf 'o\nn\np\n1\n\n\nw\n' |
	fdisk "$DISK" >/tmp/extroot-fdisk.log 2>&1 || {
		echo -e "${RED}fdisk failed.${NC}"
		cat /tmp/extroot-fdisk.log 2>/dev/null
		return 1
	}

	sync
	block info >/dev/null 2>&1 || true

	i=1
	while [ "$i" -le 15 ]; do
		if [ -b "$PART" ]; then
			rm -f /tmp/extroot-fdisk.log
			return 0
		fi

		sleep 1
		block info >/dev/null 2>&1 || true
		i=$((i + 1))
	done

	echo -e "${RED}Partition $PART not found after fdisk.${NC}"
	cat /tmp/extroot-fdisk.log 2>/dev/null
	rm -f /tmp/extroot-fdisk.log
	return 1
}

format_partition() {
	PART="$1"

	echo -e "${YELLOW}Formatting $PART as ext4 with zero reserved blocks...${NC}"

	mkfs.ext4 -F -m 0 -L extroot "$PART" || {
		echo -e "${RED}mkfs.ext4 failed.${NC}"
		return 1
	}

	sync
	sleep 2
	return 0
}

copy_overlay_to_usb() {
	PART="$1"
	MNT="$2"

	mkdir -p "$MNT"

	mount -t ext4 -o "$OVERLAY_OPTS" "$PART" "$MNT" || {
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

	umount "$MNT" 2>/dev/null || {
		echo -e "${YELLOW}Warning: normal unmount failed for $MNT.${NC}"
		sync
		umount -l "$MNT" 2>/dev/null || true
	}

	return 0
}

# The overlay was copied before fstab was modified, therefore put the
# final fstab into the external overlay explicitly.
sync_final_fstab_to_usb() {
	PART="$1"
	MNT="$2"

	mkdir -p "$MNT"

	mount -t ext4 -o "$OVERLAY_OPTS" "$PART" "$MNT" || {
		echo -e "${RED}Could not remount $PART to copy final fstab.${NC}"
		return 1
	}

	mkdir -p "$MNT/etc/config"

	cp -a /etc/config/fstab "$MNT/etc/config/fstab" || {
		umount "$MNT" 2>/dev/null || true
		echo -e "${RED}Could not copy final fstab to the external overlay.${NC}"
		return 1
	}

	sync
	umount "$MNT" 2>/dev/null || true
	return 0
}

validate_extroot_config() {
	PART="$1"
	MNT="$2"

	UUID="$(get_partition_uuid "$PART")"
	CFG_UUID="$(uci -q get fstab.extroot.uuid 2>/dev/null || true)"
	CFG_TARGET="$(uci -q get fstab.extroot.target 2>/dev/null || true)"
	CFG_TYPE="$(uci -q get fstab.extroot.fstype 2>/dev/null || true)"
	CFG_ENABLED="$(uci -q get fstab.extroot.enabled 2>/dev/null || true)"

	if [ -z "$UUID" ]; then
		echo -e "${RED}Validation: partition UUID is missing.${NC}"
		return 1
	fi

	if [ "$CFG_UUID" != "$UUID" ]; then
		echo -e "${RED}Validation: fstab UUID does not match the USB partition.${NC}"
		return 1
	fi

	if [ "$CFG_TARGET" != "/overlay" ]; then
		echo -e "${RED}Validation: fstab target is not /overlay.${NC}"
		return 1
	fi

	if [ "$CFG_TYPE" != "ext4" ]; then
		echo -e "${RED}Validation: fstab filesystem type is not ext4.${NC}"
		return 1
	fi

	if [ "$CFG_ENABLED" != "1" ]; then
		echo -e "${RED}Validation: extroot mount is not enabled.${NC}"
		return 1
	fi

	# Verify the external filesystem still mounts and contains the
	# copied overlay plus the final fstab.
	mkdir -p "$MNT"

	mount -t ext4 -o "$OVERLAY_OPTS" "$PART" "$MNT" || {
		echo -e "${RED}Validation: cannot mount the new extroot partition.${NC}"
		return 1
	}

	VALID=1

	if [ ! -d "$MNT/upper" ]; then
		echo -e "${RED}Validation: external overlay does not contain /upper.${NC}"
		VALID=0
	fi

	if [ ! -f "$MNT/etc/config/fstab" ]; then
		echo -e "${RED}Validation: final fstab is missing from external overlay.${NC}"
		VALID=0
	fi

	if [ "$VALID" = "1" ]; then
		EXT_UUID="$(uci -c "$MNT/etc/config" -q get fstab.extroot.uuid 2>/dev/null || true)"
		EXT_TARGET="$(uci -c "$MNT/etc/config" -q get fstab.extroot.target 2>/dev/null || true)"

		if [ "$EXT_UUID" != "$UUID" ] || [ "$EXT_TARGET" != "/overlay" ]; then
			echo -e "${RED}Validation: external fstab does not match the new extroot.${NC}"
			VALID=0
		fi
	fi

	sync
	umount "$MNT" 2>/dev/null || true

	[ "$VALID" = "1" ]
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

	if [ "$rc" = "1" ] || [ -z "$DISK" ]; then
		echo -e "${RED}No safe USB disk detected.${NC}"
		return 1
	fi

	PART="${DISK}1"
	MNT="/mnt/usb"

	echo
	echo -e "${RED}WARNING:${NC} This will erase all data on ${DISK}."
	echo -e "${YELLOW}The selected disk was checked against system/boot mountpoints.${NC}"
	printf "Type YES to continue: "
	read confirm

	if [ "$confirm" != "YES" ]; then
		echo -e "${YELLOW}Cancelled.${NC}"
		return 1
	fi

	# Critical final safety check immediately before destructive commands.
	if disk_is_protected "$DISK"; then
		echo -e "${RED}ABORTED: $DISK is now detected as a system/protected disk.${NC}"
		return 1
	fi

	unmount_old_mounts "$DISK" "$PART" "$MNT" || return 1

	# Check once more after unmounting candidate partitions.
	if disk_is_protected "$DISK"; then
		echo -e "${RED}ABORTED: $DISK is a system/protected disk.${NC}"
		return 1
	fi

	partition_disk "$DISK" "$PART" || return 1
	format_partition "$PART" || return 1
	copy_overlay_to_usb "$PART" "$MNT" || return 1

	configure_fstab_extroot "$PART" || {
		echo -e "${RED}Failed to configure fstab extroot.${NC}"
		return 1
	}

	if ! sync_final_fstab_to_usb "$PART" "$MNT"; then
		echo -e "${RED}Failed to synchronize final fstab to the new overlay.${NC}"
		echo -e "${YELLOW}Restoring the original fstab. Reboot cancelled.${NC}"
		restore_fstab >/dev/null 2>&1 || true
		return 1
	fi

	if ! validate_extroot_config "$PART" "$MNT"; then
		echo -e "${RED}Final extroot validation failed.${NC}"
		echo -e "${YELLOW}Restoring the original fstab. Reboot cancelled.${NC}"
		restore_fstab >/dev/null 2>&1 || true
		return 1
	fi

	apply_longevity_tweaks

	# apply_longevity_tweaks may update system/rc.local after the original
	# overlay copy. Sync those final config changes too.
	if ! mount -t ext4 -o "$OVERLAY_OPTS" "$PART" "$MNT" 2>/dev/null; then
		echo -e "${RED}Could not mount extroot for final configuration sync.${NC}"
		echo -e "${YELLOW}Restoring the original fstab. Reboot cancelled.${NC}"
		restore_fstab >/dev/null 2>&1 || true
		return 1
	fi

	mkdir -p "$MNT/etc/config"
	cp -a /etc/config/fstab "$MNT/etc/config/fstab" 2>/dev/null || true
	cp -a /etc/config/system "$MNT/etc/config/system" 2>/dev/null || true

	if [ -f /etc/rc.local ]; then
		cp -a /etc/rc.local "$MNT/etc/rc.local" 2>/dev/null || true
	fi

	sync
	umount "$MNT" 2>/dev/null || true

	cleanup_fstab_backup

	echo
	echo -e "${GREEN}Done.${NC}"
	echo -e "${GREEN}Final validation passed.${NC}"
	echo -e "${GREEN}Disk:${NC} $DISK"
	echo -e "${GREEN}Partition:${NC} $PART"
	echo -e "${GREEN}Target:${NC} /overlay"
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

	echo -e "${CYAN}[Block devices]${NC}"
	if command -v lsblk >/dev/null 2>&1; then
		lsblk 2>/dev/null | sed 's/^/ /'
	else
		echo " lsblk not installed"
	fi

	echo

	echo -e "${CYAN}[Protected system disks]${NC}"
	PROTECTED="$(protected_disks 2>/dev/null || true)"
	if [ -n "$PROTECTED" ]; then
		echo "$PROTECTED" | sed 's/^/ /'
	else
		echo " (no /dev/sdX system disk detected)"
	fi

	echo

	echo -e "${CYAN}[Block info]${NC}"
	block info 2>/dev/null | grep -E '/dev/sd|/overlay|UUID' || true

	echo

	echo -e "${CYAN}[fstab]${NC}"
	if [ -f /etc/config/fstab ]; then
		uci -q show fstab | sed 's/^/ /'
	else
		echo " /etc/config/fstab not found"
	fi

	echo

	echo -e "${CYAN}[Extroot named section]${NC}"
	if uci -q get fstab.extroot >/dev/null 2>&1; then
		uci -q show fstab.extroot | sed 's/^/ /'
	else
		echo " fstab.extroot not present"
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

	if is_extroot_active; then
		echo -e "${GREEN}STATUS: extroot is ACTIVE.${NC}"
	else
		echo -e "${YELLOW}STATUS: extroot is NOT active.${NC}"
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
