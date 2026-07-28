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

echo "Configuring Passwall2"
uci del passwall2.China
uci del passwall2.Russia_Block
uci del passwall2.Russia
uci set passwall2.@global[0].remote_dns='8.8.4.4'
uci set passwall2.@global_rules[0].geosite_update='1'
uci set passwall2.@global_rules[0].geoip_update='1'
uci set passwall2.@global_rules[0].geoip_url='https://github.com/Chocolate4U/Iran-v2ray-rules/releases/latest/download/geoip.dat'
uci set passwall2.@global_rules[0].geosite_url='https://github.com/Chocolate4U/Iran-v2ray-rules/releases/latest/download/geosite.dat'
uci set passwall2.@global_rules[0].update_week_mode='7'
uci set passwall2.@global_rules[0].update_time_mode='4:00'
uci set passwall2.@global_subscribe[0].ss_type='sing-box'
uci set passwall2.@global_subscribe[0].trojan_type='sing-box'
uci set passwall2.@global_subscribe[0].vmess_type='sing-box'
uci set passwall2.@global_subscribe[0].vless_type='sing-box'
uci set passwall2.@global_subscribe[0].hysteria2_type='sing-box'
uci set passwall2.rulenode.type='sing-box'
uci set passwall2.rulenode.protocol='_shunt'
uci set passwall2.rulenode.domainStrategy='IPOnDemand'
uci set passwall2.rulenode.domainMatcher='hybrid'
uci set passwall2.rulenode.write_ipset_direct='1'
uci set passwall2.rulenode.enable_geoview_ip='1'
uci set passwall2.rulenode.Iran='_direct'
uci set passwall2.rulenode.PrivateIP='_direct'

ROUTER_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo 'openwrt.lan')
echo "Installation complete! Visit http://$ROUTER_IP/proxymaster"
