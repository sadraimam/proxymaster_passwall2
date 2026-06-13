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

ROUTER_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo 'openwrt.lan')
echo "Installation complete! Visit http://$ROUTER_IP/proxymaster"
