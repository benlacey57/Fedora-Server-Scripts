#!/usr/bin/env bash
# ==============================================================================
# Script: vpn-down.sh
# Description: Disconnects VPN and restores standard network routing
# ==============================================================================
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "⚠️  Please run with root privileges (sudo)." >&2
    exit 1
fi

echo "--> Terminating OpenVPN..."
killall openvpn 2>/dev/null || true
rm -f /etc/openvpn/client/airvpn-active.conf

echo "--> Resetting Firewall Rules..."
if command -v ufw &>/dev/null; then
    ufw --force reset > /dev/null
    ufw default allow outgoing
    ufw default deny incoming
    ufw --force enable > /dev/null
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --set-default-zone=public
    firewall-cmd --reload
fi

echo "✅ VPN disconnected. Standard routing restored."
/home/media/docker/scripts/vpn/vpn-status.sh
