#!/bin/sh
# =============================================================================
# First-boot setup for OpenWrt + Passwall2 (Iran build)
# Runs ONCE automatically on first boot, then OpenWrt deletes it.
# Filename should start with "zzz-" so it runs AFTER luci-passwall2.
# =============================================================================

[ -x /sbin/uci ] || exit 0

# =============================================================================
# PART 1: Base setup (WiFi / Password / LAN IP)
# =============================================================================

wlan_name="OpenWrt-2G"
wlan_password="Asus40xx"

root_password="root"

lan_ip_address="192.168.10.1/24"

exec >/tmp/setup.log 2>&1

if [ -n "$root_password" ]; then
  (echo "$root_password"; sleep 1; echo "$root_password") | passwd > /dev/null
fi

if [ -n "$lan_ip_address" ]; then
  uci set network.lan.ipaddr="$lan_ip_address"
  uci commit network
fi

if [ -n "$wlan_name" -a -n "$wlan_password" -a ${#wlan_password} -ge 8 ]; then
  uci set wireless.@wifi-device[0].disabled='0'
  uci set wireless.@wifi-iface[0].disabled='0'
  uci set wireless.@wifi-iface[0].encryption='psk2'
  uci set wireless.@wifi-iface[0].ssid="$wlan_name"
  uci set wireless.@wifi-iface[0].key="$wlan_password"
  uci commit wireless
fi

echo "Base setup done!"

# =============================================================================
# PART 2: Passwall2 Iran Bypass
# =============================================================================

# --- 0) Safety net: make sure Passwall2's default config is present ----------
if [ ! -s /etc/config/passwall2 ] && [ -f /usr/share/passwall2/0_default_config ]; then
	cp -f /usr/share/passwall2/0_default_config /etc/config/passwall2
fi

# --- 1) Create the "Iran Bypass" shunt rule ----------------------------------
DOMAIN_LIST='regexp:.*\.ir$
regexp:.*\.xn--mgba3a4f16a$
ext:geosite_IR.dat:ir'

IP_LIST='ext:geoip_IR.dat:ir'

uci -q delete passwall2.IranBypass 2>/dev/null

uci set passwall2.IranBypass='shunt_rules'
uci set passwall2.IranBypass.remarks='Iran Bypass'
uci set passwall2.IranBypass.network='tcp,udp'
uci set passwall2.IranBypass.domain_list="$DOMAIN_LIST"
uci set passwall2.IranBypass.ip_list="$IP_LIST"

# --- 2) Attach the rule to every shunt node as Direct (bypass) ---------------
SHUNT_NODES=$(uci show passwall2 2>/dev/null \
	| sed -n "s/^passwall2\.\([^.]*\)\.protocol='_shunt'\$/\1/p")
[ -z "$SHUNT_NODES" ] && SHUNT_NODES="rulenode"

for node in $SHUNT_NODES; do
	uci -q set "passwall2.$node.IranBypass"='_direct'
done

uci commit passwall2

# --- 3) Remove ONLY the broken openwrt.org Passwall feeds --------------------
for feed_file in \
	/etc/apk/repositories.d/distfeeds.list \
	/etc/apk/repositories.d/passwall.list \
	/etc/apk/repositories.d/customfeeds.list \
	/etc/apk/repositories \
	/etc/opkg/distfeeds.conf \
	/etc/opkg/customfeeds.conf
do
	[ -f "$feed_file" ] || continue
	sed -i -e '\#passwall#d' "$feed_file"
done

# --- 4) Ensure the Passwall apk signing key is present (correct name!) --------
PW_KEY="/etc/apk/keys/openwrt-passwall-build.pem"
if [ ! -s "$PW_KEY" ]; then
	mkdir -p /etc/apk/keys
	cat > "$PW_KEY" <<'PWKEY'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEOmXHYLJGWFQCtbWqDqlxMvcAvkZZ
Owy7UzzBIOxrGSAiu1blMeX96Q55Q9PH5GyjPwYiT4nrrwRgIttggGK62w==
-----END PUBLIC KEY-----
PWKEY
fi
rm -f /etc/apk/keys/passwall.pub 2>/dev/null

# --- 5) Write the correct, signed Passwall apk feeds (no duplicates) ---------
if [ -f /etc/openwrt_release ]; then
	. /etc/openwrt_release
	PW_REL="${DISTRIB_RELEASE%.*}"
	PW_ARCH="${DISTRIB_ARCH}"
	if [ -n "$PW_REL" ] && [ -n "$PW_ARCH" ]; then
		mkdir -p /etc/apk/repositories.d
		PW_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${PW_REL}/${PW_ARCH}"
		{
			echo "${PW_BASE}/passwall_luci/packages.adb"
			echo "${PW_BASE}/passwall_packages/packages.adb"
			echo "${PW_BASE}/passwall2/packages.adb"
		} > /etc/apk/repositories.d/passwall.list
	fi
fi

# --- refresh LuCI caches so the new rule shows immediately -------------------
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null
rm -rf /tmp/luci-modulecache/ 2>/dev/null
killall -HUP rpcd 2>/dev/null

exit 0
