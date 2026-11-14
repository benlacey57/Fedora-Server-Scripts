#!/usr/bin/env bash
# ==============================================================================
# Script: vpn-stats.sh
# Description: Displays active tunnel metrics and firewall status
# ==============================================================================
set -euo pipefail

echo "=== Active OpenVPN Process ==="
pgrep -a openvpn || echo "No active OpenVPN process."

echo -e "\n=== OpenVPN Interface Metrics ==="
ip -s link show tun0 2>/dev/null || echo "No active tun0 interface."

echo -e "\n=== Active Firewall Rules ==="
if command -v ufw &>/dev/null; then
    sudo ufw status verbose
elif command -v firewall-cmd &>/dev/null; then
    sudo firewall-cmd --list-all
fi
