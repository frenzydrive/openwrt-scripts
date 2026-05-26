#!/bin/sh

# Universal installer for frenzydrive/openwrt-scripts
# Supports:
#   OpenWrt 24.x -> opkg / ipk
#   OpenWrt 25.x -> apk / apk + packages.adb
#
# Installs/configures:
#   - basic WAN DNS settings
#   - timezone
#   - PassWall2
#   - Xray
#   - dnsmasq-full
#   - Argon theme
#   - Argon Russian translation from frenzydrive/openwrt-scripts
#   - custom LuCI title patch
#
# Usage:
#   sh install_all.sh
#   sh install_all.sh --passwall-only
#   sh install_all.sh --argon-only
#   sh install_all.sh --no-mods

set +e

# =========================
# User-tunable settings
# =========================

RAW_REPO="https://raw.githubusercontent.com/frenzydrive/openwrt-scripts/main"

ARGON_REPO="$RAW_REPO/assets/argon-config"
PASSWALL_MOD_ZIP="$RAW_REPO/assets/passwall2/mod.zip"

# Your existing repo assets for OpenWrt 24.x
ARGON_THEME_IPK="luci-theme-argon_2.4.3-r20250722_all.ipk"
ARGON_CONFIG_IPK="luci-app-argon-config_0.9_all.ipk"
ARGON_RU_LMO="argon-config.ru.lmo"

# Argon APK for OpenWrt 25.x.
# Source: official Argon GitHub release used by Radxa docs.
ARGON_THEME_APK_URL="https://github.com/jerrykuku/luci-theme-argon/releases/download/v2.4.3/luci-theme-argon-2.4.3-r20250722.apk"
ARGON_THEME_APK_FILE="luci-theme-argon-2.4.3-r20250722.apk"

# PassWall build repo
PASSWALL_SF_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build"

# Keep your old behavior:
WAN_DNS_IPV4="1.1.1.1"
WAN_DNS_IPV6="2001:4860:4860::8888"

# Your old script used Moscow time.
# Change here if needed, for example:
# TIMEZONE_NAME="Europe/Riga"
# TIMEZONE_VALUE="EET-2EEST,M3.5.0/3,M10.5.0/4"
TIMEZONE_NAME="Europe/Moscow"
TIMEZONE_VALUE="MSK-3"

INSTALL_PASSWALL=1
INSTALL_ARGON=1
INSTALL_MODS=1

# =========================
# Pretty output
# =========================

GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
RED="$(printf '\033[0;31m')"
MAGENTA="$(printf '\033[0;35m')"
NC="$(printf '\033[0m')"

log() {
	printf '%s[INFO]%s %s\n' "$GREEN" "$NC" "$*"
}

warn() {
	printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*" >&2
}

err() {
	printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2
}

die() {
	err "$*"
	exit 1
}

# =========================
# Args
# =========================

for arg in "$@"; do
	case "$arg" in
		--passwall-only)
			INSTALL_PASSWALL=1
			INSTALL_ARGON=0
			;;
		--argon-only)
			INSTALL_PASSWALL=0
			INSTALL_ARGON=1
			;;
		--no-mods)
			INSTALL_MODS=0
			;;
		--help|-h)
			cat <<EOF
Usage:
  sh $0
  sh $0 --passwall-only
  sh $0 --argon-only
  sh $0 --no-mods

Options:
  --passwall-only   Install/configure only PassWall2
  --argon-only      Install/configure only Argon
  --no-mods         Do not install custom PassWall2 UI mod.zip
EOF
			exit 0
			;;
		*)
			die "Unknown argument: $arg"
			;;
	esac
done

# =========================
# Basic helpers
# =========================

need_root() {
	[ "$(id -u)" = "0" ] || die "Run this script as root"
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

download() {
	url="$1"
	out="$2"

	rm -f "$out"

	if command_exists wget; then
		wget -q -O "$out" "$url"
	elif command_exists uclient-fetch; then
		uclient-fetch -q -O "$out" "$url"
	else
		die "Neither wget nor uclient-fetch found"
	fi

	[ -s "$out" ]
}

safe_mkdir() {
	mkdir -p "$1" || die "Cannot create directory: $1"
}

backup_file_once() {
	file="$1"

	[ -f "$file" ] || return 0

	if [ ! -f "$file.frenzydrive.bak" ]; then
		cp -f "$file" "$file.frenzydrive.bak" || warn "Failed to backup $file"
	fi
}

# =========================
# OpenWrt detection
# =========================

detect_openwrt() {
	[ -r /etc/openwrt_release ] || die "/etc/openwrt_release not found. This does not look like OpenWrt."

	# shellcheck disable=SC1091
	. /etc/openwrt_release

	OWRT_RELEASE="${DISTRIB_RELEASE:-unknown}"
	OWRT_ARCH="${DISTRIB_ARCH:-unknown}"
	OWRT_TARGET="${DISTRIB_TARGET:-unknown}"

	case "$OWRT_RELEASE" in
		*SNAPSHOT*)
			die "SNAPSHOT builds are not supported by this installer. Use stable OpenWrt release."
			;;
	esac

	OWRT_MAJOR="$(printf '%s' "$OWRT_RELEASE" | cut -d. -f1)"
	OWRT_FEED_RELEASE="$(printf '%s' "$OWRT_RELEASE" | cut -d. -f1,2)"

	log "Detected OpenWrt release : $OWRT_RELEASE"
	log "Detected OpenWrt arch    : $OWRT_ARCH"
	log "Detected OpenWrt target  : $OWRT_TARGET"
	log "Feed release branch      : $OWRT_FEED_RELEASE"
}

detect_pkg_manager() {
	PKG_MGR=""

	if [ "$OWRT_MAJOR" -ge 25 ] 2>/dev/null; then
		if command_exists apk; then
			PKG_MGR="apk"
		elif command_exists opkg; then
			warn "OpenWrt $OWRT_RELEASE detected, but apk not found. Falling back to opkg."
			PKG_MGR="opkg"
		fi
	else
		if command_exists opkg; then
			PKG_MGR="opkg"
		elif command_exists apk; then
			warn "OpenWrt $OWRT_RELEASE detected, but opkg not found. Falling back to apk."
			PKG_MGR="apk"
		fi
	fi

	[ -n "$PKG_MGR" ] || die "No supported package manager found: neither opkg nor apk"

	log "Using package manager   : $PKG_MGR"
}

# =========================
# Package manager wrappers
# =========================

pkg_update() {
	log "Updating package lists..."

	if [ "$PKG_MGR" = "apk" ]; then
		apk update
		rc="$?"
		if [ "$rc" != "0" ]; then
			warn "apk update returned non-zero status. Will continue, but package install may fail."
		fi
	else
		opkg update || die "opkg update failed"
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

pkg_install_required() {
	pkg="$1"

	if pkg_is_installed "$pkg"; then
		log "Already installed: $pkg"
		return 0
	fi

	log "Installing: $pkg"

	if [ "$PKG_MGR" = "apk" ]; then
		apk add --allow-untrusted "$pkg"
	else
		opkg install "$pkg"
	fi

	rc="$?"
	if [ "$rc" != "0" ]; then
		die "Failed to install required package: $pkg"
	fi
}

pkg_install_optional() {
	pkg="$1"

	if pkg_is_installed "$pkg"; then
		log "Already installed: $pkg"
		return 0
	fi

	log "Installing optional package: $pkg"

	if [ "$PKG_MGR" = "apk" ]; then
		apk add --allow-untrusted "$pkg"
	else
		opkg install "$pkg"
	fi

	rc="$?"
	if [ "$rc" != "0" ]; then
		warn "Optional package failed or unavailable: $pkg"
		return 1
	fi

	return 0
}

pkg_install_local_required() {
	file="$1"

	[ -f "$file" ] || die "Local package not found: $file"

	log "Installing local package: $file"

	case "$file" in
		*.ipk)
			[ "$PKG_MGR" = "opkg" ] || die "Cannot install .ipk with $PKG_MGR: $file"
			opkg install "./$file" || die "Failed to install $file"
			;;
		*.apk)
			[ "$PKG_MGR" = "apk" ] || die "Cannot install .apk with $PKG_MGR: $file"

	        case "$file" in
		    	/*)
			    	apk add --allow-untrusted "$file" || die "Failed to install $file"
			        ;;
		        *)
			        apk add --allow-untrusted "./$file" || die "Failed to install $file"
			        ;;
	        esac
	        ;;
		*)
			die "Unsupported local package format: $file"
			;;
	esac
}

pkg_install_local_optional() {
	file="$1"

	[ -f "$file" ] || {
		warn "Local package not found: $file"
		return 1
	}

	log "Installing optional local package: $file"

	case "$file" in
		*.ipk)
			[ "$PKG_MGR" = "opkg" ] || {
				warn "Skipping .ipk on $PKG_MGR: $file"
				return 1
			}
			opkg install "./$file"
			;;
		*.apk)
			[ "$PKG_MGR" = "apk" ] || {
		    	warn "Skipping .apk on $PKG_MGR: $file"
		        return 1
	        }

	        case "$file" in
		    	/*)
			    	apk add --allow-untrusted "$file"
			        ;;
		    *)
			        apk add --allow-untrusted "./$file"
			        ;;
	       esac
	       ;;
		*)
			warn "Unsupported local package format: $file"
			return 1
			;;
	esac
}

# =========================
# Common system setup
# =========================

configure_basic_system() {
	log "Applying basic network/timezone settings..."

	uci -q set network.wan.peerdns='0'
	uci -q set network.wan6.peerdns='0'
	uci -q set network.wan.dns="$WAN_DNS_IPV4"
	uci -q set network.wan6.dns="$WAN_DNS_IPV6"

	uci -q set system.@system[0].zonename="$TIMEZONE_NAME"
	uci -q set system.@system[0].timezone="$TIMEZONE_VALUE"

	uci -q commit network
	uci -q commit system

	/sbin/reload_config >/dev/null 2>&1 || true
}

configure_luci_language() {
	log "Setting LuCI language to Russian..."

	uci -q set luci.main.lang='ru'
	uci -q commit luci
}

install_common_tools() {
	pkg_update

	if [ "$PKG_MGR" = "apk" ]; then
		# OpenWrt 25.x
		pkg_install_optional ca-bundle
		pkg_install_optional unzip
		pkg_install_optional luci-base
		pkg_install_optional luci-i18n-base-ru
	else
		# OpenWrt 24.x
		pkg_install_optional ca-bundle
		pkg_install_optional wget-ssl
		pkg_install_optional unzip
		pkg_install_optional luci-base
		pkg_install_optional luci-i18n-base-ru
	fi
}

# =========================
# PassWall2 feeds
# =========================

setup_passwall_feed_opkg() {
	log "Configuring PassWall2 opkg feed..."

	key="/tmp/passwall-opkg.pub"

	if download "$PASSWALL_SF_BASE/ipk.pub/download" "$key"; then
		opkg-key add "$key" || warn "Failed to add ipk.pub"
	elif download "$PASSWALL_SF_BASE/passwall.pub/download" "$key"; then
		opkg-key add "$key" || warn "Failed to add passwall.pub"
	else
		warn "Could not download PassWall opkg public key. Continuing anyway."
	fi

	feed_file="/etc/opkg/customfeeds.conf"
	backup_file_once "$feed_file"
	touch "$feed_file"

	grep -v 'openwrt-passwall-build/releases/packages-' "$feed_file" \
		| grep -v '^src/gz passwall_' \
		| grep -v '^src/gz passwall2 ' \
		> "$feed_file.tmp"

	mv "$feed_file.tmp" "$feed_file"

	for feed in passwall_luci passwall_packages passwall2; do
		echo "src/gz $feed $PASSWALL_SF_BASE/releases/packages-$OWRT_FEED_RELEASE/$OWRT_ARCH/$feed" >> "$feed_file"
	done
}

setup_passwall_feed_apk() {
	log "Configuring PassWall2 apk feed..."

	safe_mkdir /etc/apk/repositories.d
	safe_mkdir /etc/apk/keys

	key="/etc/apk/keys/openwrt-passwall-build.pem"

	if command_exists uclient-fetch; then
		uclient-fetch -O "$key" "$PASSWALL_SF_BASE/apk.pub" || warn "Could not download apk.pub"
	elif command_exists wget; then
		wget -O "$key" "$PASSWALL_SF_BASE/apk.pub" || warn "Could not download apk.pub"
	else
		warn "No downloader found for apk.pub"
	fi

	[ -f "$key" ] && chmod 0644 "$key"

	feed_file="/etc/apk/repositories.d/passwall.list"
	backup_file_once "$feed_file"

	cat > "$feed_file" <<EOF
$PASSWALL_SF_BASE/releases/packages-$OWRT_FEED_RELEASE/$OWRT_ARCH/passwall_luci/packages.adb
$PASSWALL_SF_BASE/releases/packages-$OWRT_FEED_RELEASE/$OWRT_ARCH/passwall_packages/packages.adb
$PASSWALL_SF_BASE/releases/packages-$OWRT_FEED_RELEASE/$OWRT_ARCH/passwall2/packages.adb
EOF
}

setup_passwall_feeds() {
	if [ "$PKG_MGR" = "apk" ]; then
		setup_passwall_feed_apk
	else
		setup_passwall_feed_opkg
	fi

	pkg_update
}

# =========================
# dnsmasq-full
# =========================

install_dnsmasq_full() {
	if pkg_is_installed dnsmasq-full; then
		log "dnsmasq-full already installed"
		return 0
	fi

	log "Installing dnsmasq-full..."

	if [ "$PKG_MGR" = "apk" ]; then
		apk add --allow-untrusted dnsmasq-full
		rc="$?"

		if [ "$rc" != "0" ]; then
			warn "dnsmasq-full install failed. Trying to remove dnsmasq and retry."
			apk del dnsmasq
			apk add --allow-untrusted dnsmasq-full || die "Failed to install dnsmasq-full"
		fi
	else
		opkg remove dnsmasq
		opkg install dnsmasq-full || die "Failed to install dnsmasq-full"
	fi
}

# =========================
# PassWall2 install/config
# =========================

install_passwall2_packages() {
	log "Installing PassWall2 packages..."

	install_dnsmasq_full

	pkg_install_optional kmod-nft-socket
	pkg_install_optional kmod-nft-tproxy
	pkg_install_optional kmod-inet-diag
	pkg_install_optional kmod-netlink-diag
	pkg_install_optional kmod-tun
	pkg_install_optional ipset

	pkg_install_required luci-app-passwall2
	pkg_install_optional luci-i18n-passwall2-ru

	# Xray is important for your setup, but package name availability depends on feed/arch.
	if ! pkg_install_optional xray-core; then
		warn "xray-core package was not installed from feeds."
		warn "PassWall2 may still work with other cores, but VLESS/Xray nodes need xray-core."
	fi

	if [ -f /etc/init.d/passwall2 ]; then
		log "PassWall2 init script found"
	else
		die "PassWall2 installation failed: /etc/init.d/passwall2 not found"
	fi

	if command_exists xray || [ -x /usr/bin/xray ]; then
		log "Xray found"
	else
		warn "Xray binary not found at /usr/bin/xray"
	fi
}

install_passwall2_mods() {
	[ "$INSTALL_MODS" = "1" ] || {
		log "Skipping custom PassWall2 UI mods"
		return 0
	}

	log "Installing custom PassWall2 UI mods..."

	cd /tmp || return 1
	rm -f /tmp/passwall2-mod.zip

	if download "$PASSWALL_MOD_ZIP" /tmp/passwall2-mod.zip; then
		unzip -o /tmp/passwall2-mod.zip -d / >/dev/null 2>&1 \
			&& log "Custom PassWall2 mods installed" \
			|| warn "Failed to unzip custom PassWall2 mods"
	else
		warn "Could not download custom PassWall2 mod.zip"
	fi
}

ensure_passwall_section() {
	section_type="$1"

	if uci -q get "passwall2.@$section_type[0]" >/dev/null 2>&1; then
		return 0
	fi

	uci add passwall2 "$section_type" >/dev/null 2>&1
}

configure_passwall2() {
	log "Configuring PassWall2..."

	ensure_passwall_section global_forwarding
	ensure_passwall_section global

	uci -q set system.@system[0].zonename="$TIMEZONE_NAME"
	uci -q set system.@system[0].timezone="$TIMEZONE_VALUE"

	uci -q set passwall2.@global_forwarding[0].tcp_no_redir_ports='disable'
	uci -q set passwall2.@global_forwarding[0].udp_no_redir_ports='disable'
	uci -q set passwall2.@global_forwarding[0].tcp_redir_ports='1:65535'
	uci -q set passwall2.@global_forwarding[0].udp_redir_ports='1:65535'

	uci -q set passwall2.@global[0].direct_dns_protocol='auto'
	uci -q set passwall2.@global[0].direct_dns_query_strategy='UseIP'
	uci -q set passwall2.@global[0].remote_dns_protocol='doh'
	uci -q set passwall2.@global[0].remote_dns_query_strategy='UseIPv4'
	uci -q set passwall2.@global[0].dns_hosts='cloudflare-dns.com 1.1.1.1 dns.google.com 8.8.8.8'
	uci -q set passwall2.@global[0].remote_dns_detour='remote'
	uci -q set passwall2.@global[0].remote_dns_doh='https://1.1.1.1/dns-query'
	uci -q set passwall2.@global[0].dns_redirect='1'

	# Remove default rules if they exist
	uci -q delete passwall2.China
	uci -q delete passwall2.Iran

	# Your custom Russia shunt rule
	uci -q set passwall2.Russia='shunt_rules'
	uci -q set passwall2.Russia.network='tcp,udp'
	uci -q set passwall2.Russia.remarks='Russia'
	uci -q set passwall2.Russia.domain_list='geosite:category-ru'
	uci -q set passwall2.Russia.ip_list='geoip:ru'

	# This line depends on PassWall2 config schema.
	# Keep old behavior, but do not fail installer if schema changed.
	uci -q set passwall2.rulenode.Russia='_direct'

	uci -q commit passwall2
	uci -q commit system
	uci -q commit network

	/sbin/reload_config >/dev/null 2>&1 || true

	if [ -x /etc/init.d/passwall2 ]; then
		/etc/init.d/passwall2 enable >/dev/null 2>&1 || true
		/etc/init.d/passwall2 restart >/dev/null 2>&1 || warn "Failed to restart passwall2"
	fi
}

install_passwall2_all() {
	log "========== PassWall2 install start =========="
	setup_passwall_feeds
	install_passwall2_packages
	install_passwall2_mods
	configure_passwall2
	log "========== PassWall2 install done =========="
}

# =========================
# Argon install/config
# =========================

html_escape() {
	printf '%s' "$1" \
		| sed \
			-e 's/&/\&amp;/g' \
			-e 's/</\&lt;/g' \
			-e 's/>/\&gt;/g' \
			-e 's/"/\&quot;/g'
}

get_router_title() {
	title=""

	if [ -r /tmp/sysinfo/model ]; then
		title="$(cat /tmp/sysinfo/model 2>/dev/null)"
	fi

	if [ -z "$title" ]; then
		title="$(uci -q get system.@system[0].hostname 2>/dev/null)"
	fi

	[ -n "$title" ] || title="OpenWrt"

	title="$(printf '%s' "$title" | sed 's/[[:cntrl:]]//g; s/[[:space:]]\+/ /g; s/^ //; s/ $//')"

	html_escape "$title"
}

patch_argon_title_file() {
	file="$1"
	title="$2"

	[ -f "$file" ] || {
		warn "Argon template not found, skipping: $file"
		return 0
	}

	if grep -q "<title>$title</title>" "$file"; then
		log "Title already patched: $file"
		return 0
	fi

	backup_file_once "$file"

	if grep -q '<title>.*</title>' "$file"; then
		sed "s#<title>.*</title>#<title>$title</title>#g" "$file" > "$file.tmp" \
			&& mv "$file.tmp" "$file" \
			&& log "Patched title: $file" \
			|| warn "Failed to patch title: $file"
	else
		warn "No one-line <title>...</title> found in $file"
	fi
}

patch_argon_title() {
	title="$(get_router_title)"
	log "Browser tab title will be: $title"

	patch_argon_title_file /usr/lib/lua/luci/view/themes/argon/header.htm "$title"
	patch_argon_title_file /usr/lib/lua/luci/view/themes/argon/header_login.htm "$title"
}

install_argon_translation() {
	log "Installing Argon Russian translation..."

	cd /tmp || return 1
	rm -f "/tmp/$ARGON_RU_LMO"

	if download "$ARGON_REPO/$ARGON_RU_LMO" "/tmp/$ARGON_RU_LMO"; then
		safe_mkdir /usr/lib/lua/luci/i18n
		cp -f "/tmp/$ARGON_RU_LMO" /usr/lib/lua/luci/i18n/argon-config.ru.lmo
		chmod 0644 /usr/lib/lua/luci/i18n/argon-config.ru.lmo
	else
		warn "Could not download $ARGON_RU_LMO"
	fi
}

ensure_argon_menu() {
	menu="/usr/share/luci/menu.d/luci-app-argon-config.json"

	if [ -f "$menu" ]; then
		return 0
	fi

	log "Creating missing Argon Config menu entry..."

	safe_mkdir /usr/share/luci/menu.d

	cat > "$menu" <<'EOF'
{
	"admin/system/argon-config": {
		"title": "Argon Config",
		"order": 60,
		"action": {
			"type": "view",
			"path": "argon-config"
		}
	}
}
EOF
}

fix_argon_postinst_defaults() {
	file="/etc/uci-defaults/luci-argon-config"

	[ -f "$file" ] && return 0

	log "Creating missing Argon uci-defaults helper..."

	safe_mkdir /etc/uci-defaults

	cat > "$file" <<'EOF'
#!/bin/sh
exit 0
EOF

	chmod +x "$file"
}

install_argon_opkg() {
	log "Installing Argon via opkg/ipk..."

	cd /tmp || die "Cannot cd /tmp"

	if ! pkg_is_installed luci-theme-argon; then
		download "$ARGON_REPO/$ARGON_THEME_IPK" "/tmp/$ARGON_THEME_IPK" \
			|| die "Failed to download $ARGON_THEME_IPK"
		pkg_install_local_required "/tmp/$ARGON_THEME_IPK"
	else
		log "Already installed: luci-theme-argon"
	fi

	if ! pkg_is_installed luci-app-argon-config; then
		download "$ARGON_REPO/$ARGON_CONFIG_IPK" "/tmp/$ARGON_CONFIG_IPK" \
			|| warn "Failed to download $ARGON_CONFIG_IPK"

		if [ -f "/tmp/$ARGON_CONFIG_IPK" ]; then
			pkg_install_local_optional "/tmp/$ARGON_CONFIG_IPK" \
				|| warn "Argon Config ipk install failed"
		fi
	else
		log "Already installed: luci-app-argon-config"
	fi
}

install_argon_apk() {
	log "Installing Argon via apk..."

	cd /tmp || die "Cannot cd /tmp"

	if ! pkg_is_installed luci-theme-argon; then
		if download "$ARGON_THEME_APK_URL" "/tmp/$ARGON_THEME_APK_FILE"; then
			pkg_install_local_required "/tmp/$ARGON_THEME_APK_FILE"
		else
			warn "Could not download Argon APK from GitHub release."
			warn "Trying apk add luci-theme-argon from configured feeds..."
			pkg_install_required luci-theme-argon
		fi
	else
		log "Already installed: luci-theme-argon"
	fi

	# Argon Config for apk may not be available on all feeds/builds.
	# Do not fail the whole installation because of it.
	if ! pkg_is_installed luci-app-argon-config; then
		pkg_install_optional luci-app-argon-config \
			|| warn "Argon Config is unavailable for this OpenWrt/APK feed. Theme will still work."
	else
		log "Already installed: luci-app-argon-config"
	fi
}

set_luci_theme_argon() {
	log "Setting LuCI theme to Argon..."

	uci -q set luci.main.mediaurlbase='/luci-static/argon'
	uci -q commit luci
}

restart_luci() {
	log "Restarting LuCI services..."

	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true

	[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1
	[ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd restart >/dev/null 2>&1
}

install_argon_all() {
	log "========== Argon install start =========="

	pkg_update

	if ! pkg_is_installed luci-base; then
		die "LuCI/luci-base is not installed. Install LuCI first, then run this script."
	fi

	fix_argon_postinst_defaults

	if [ "$PKG_MGR" = "apk" ]; then
		install_argon_apk
	else
		install_argon_opkg
	fi

	install_argon_translation
	ensure_argon_menu
	patch_argon_title
	set_luci_theme_argon
	restart_luci

	log "========== Argon install done =========="
}

# =========================
# Main
# =========================

main() {
	need_root
	detect_openwrt
	detect_pkg_manager

	configure_basic_system
	install_common_tools
	configure_luci_language

	if [ "$INSTALL_PASSWALL" = "1" ]; then
		install_passwall2_all
	fi

	if [ "$INSTALL_ARGON" = "1" ]; then
		install_argon_all
	fi

	echo
	printf '%s** Installation completed **%s\n' "$YELLOW" "$NC"
	printf '%sCustomized for frenzydrive/openwrt-scripts%s\n' "$MAGENTA" "$NC"
	echo
	echo "OpenWrt release : $OWRT_RELEASE"
	echo "Architecture    : $OWRT_ARCH"
	echo "Target          : $OWRT_TARGET"
	echo "Package manager : $PKG_MGR"
	echo
	echo "If LuCI is already open, refresh browser with Ctrl+F5."
}

main "$@"
