#!/bin/bash
IP="192.168.1.1" # Change to your OpenWrt IP

# Create directories
ssh root@$IP "mkdir -p /www/proxymaster /www/cgi-bin"

# Copy files
scp www/* root@$IP:/www/proxymaster/
scp cgi-bin/api.lua root@$IP:/www/cgi-bin/proxymaster-api

# Set permissions
ssh root@$IP "chmod +x /www/cgi-bin/proxymaster-api"

echo "Deployed. Visit http://openwrt.lan/proxymaster"
