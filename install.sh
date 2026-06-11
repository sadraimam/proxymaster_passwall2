#!/bin/bash
IP="192.168.11.1" # Change to your OpenWrt IP

# Create directories
ssh root@$IP "mkdir -p /www/proxymaster /www/cgi-bin"

# Copy files
scp www/* root@$IP:/www/proxymaster/
scp cgi-bin/api.lua root@$IP:/www/cgi-bin/proxymaster-api

# Fix line endings (CRLF to LF) and set permissions
ssh root@$IP "sed -i 's/\r$//' /www/cgi-bin/proxymaster-api && chmod +x /www/cgi-bin/proxymaster-api"

# Ensure dependencies are installed
ssh root@$IP "opkg update && opkg install lua curl luci-lib-jsonc"

echo "Deployed. Visit http://openwrt.lan/proxymaster"
