#!/bin/sh

REPO_URL="https://raw.githubusercontent.com/sadraimam/proxymaster_passwall2/main"

echo "Updating package lists and installing dependencies..."
opkg update
opkg install lua curl luci-lib-jsonc

echo "Creating directories..."
mkdir -p /www/proxymaster /www/cgi-bin

echo "Downloading files from GitHub..."
curl -sL "$REPO_URL/www/index.html" -o /www/proxymaster/index.html
curl -sL "$REPO_URL/www/app.js" -o /www/proxymaster/app.js
curl -sL "$REPO_URL/www/style.css" -o /www/proxymaster/style.css
curl -sL "$REPO_URL/cgi-bin/api.lua" -o /www/cgi-bin/proxymaster-api

echo "Setting permissions and fixing line endings..."
sed -i 's/\r$//' /www/cgi-bin/proxymaster-api
chmod +x /www/cgi-bin/proxymaster-api

echo "Configuring Passwall2..."

# 1. Remove legacy rule sections if present
uci del passwall2.China >/dev/null 2>&1 || true
uci del passwall2.Russia_Block >/dev/null 2>&1 || true
uci del passwall2.Russia >/dev/null 2>&1 || true

# 2. Ensure global section exists and set defaults
GLOBAL=$(uci show passwall2 2>/dev/null | grep "=global$" | head -n1 | cut -d'.' -f2 | cut -d'=' -f1)
if [ -z "$GLOBAL" ]; then
    GLOBAL=$(uci add passwall2 global)
fi
uci set passwall2."$GLOBAL".remote_dns='8.8.4.4'
uci set passwall2."$GLOBAL".node='rulenode'

# 3. Ensure global_rules section exists and set rule URLs
RULES=$(uci show passwall2 2>/dev/null | grep "=global_rules$" | head -n1 | cut -d'.' -f2 | cut -d'=' -f1)
if [ -z "$RULES" ]; then
    RULES=$(uci add passwall2 global_rules)
fi
uci set passwall2."$RULES".geosite_update='1'
uci set passwall2."$RULES".geoip_update='1'
uci set passwall2."$RULES".geoip_url='https://github.com/Chocolate4U/Iran-v2ray-rules/releases/latest/download/geoip.dat'
uci set passwall2."$RULES".geosite_url='https://github.com/Chocolate4U/Iran-v2ray-rules/releases/latest/download/geosite.dat'
uci set passwall2."$RULES".update_week_mode='7'
uci set passwall2."$RULES".update_time_mode='4:00'

# 4. Ensure global_subscribe section exists and set default cores
SUB=$(uci show passwall2 2>/dev/null | grep "=global_subscribe$" | head -n1 | cut -d'.' -f2 | cut -d'=' -f1)
if [ -z "$SUB" ]; then
    SUB=$(uci add passwall2 global_subscribe)
fi
uci set passwall2."$SUB".ss_type='sing-box'
uci set passwall2."$SUB".trojan_type='sing-box'
uci set passwall2."$SUB".vmess_type='sing-box'
uci set passwall2."$SUB".vless_type='sing-box'
uci set passwall2."$SUB".hysteria2_type='sing-box'

# 5. Initialize named section 'rulenode' for shunt routing
uci set passwall2.rulenode='nodes'
uci set passwall2.rulenode.remarks='Shunt'
uci set passwall2.rulenode.type='sing-box'
uci set passwall2.rulenode.protocol='_shunt'
uci set passwall2.rulenode.domainStrategy='IPOnDemand'
uci set passwall2.rulenode.domainMatcher='hybrid'
uci set passwall2.rulenode.write_ipset_direct='1'
uci set passwall2.rulenode.enable_geoview_ip='1'
uci set passwall2.rulenode.Iran='_direct'
uci set passwall2.rulenode.PrivateIP='_direct'

# 6. Commit changes to /etc/config/passwall2
uci commit passwall2

ROUTER_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d'/' -f1)
[ -z "$ROUTER_IP" ] && ROUTER_IP="192.168.1.1"

HOSTNAME=$(uci get system.@system[0].hostname 2>/dev/null || echo "openwrt")
case "$HOSTNAME" in
    *.lan) DOMAIN_ADDR="$HOSTNAME" ;;
    *) DOMAIN_ADDR="${HOSTNAME}.lan" ;;
esac

echo "Installation complete!"
echo "Visit http://$ROUTER_IP/proxymaster"
echo "Or visit http://$DOMAIN_ADDR/proxymaster"
