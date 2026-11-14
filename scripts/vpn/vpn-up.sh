#!/usr/bin/env bash
# ==============================================================================
# Script: vpn-up.sh
# Description: Randomly selects an AirVPN profile, connects, & sets kill-switch
# ==============================================================================
set -euo pipefail

CONFIG_DIR="/home/media/docker/scripts/vpn/config"
SYSTEM_OVPN_LINK="/etc/openvpn/client/airvpn-active.conf"

if [ "$EUID" -ne 0 ]; then
    echo "⚠️  Please run with root privileges (sudo)." >&2
    exit 1
fi

CONFIG_FILES=("${CONFIG_DIR}"/*.ovpn)
if [ ! -f "${CONFIG_FILES[0]}" ]; then
    echo "❌ No .ovpn config files found in ${CONFIG_DIR}!" >&2
    exit 1
fi

# Pick a random configuration file
RANDOM_CONFIG="${CONFIG_FILES[RANDOM % ${#CONFIG_FILES[@]}]}"
echo "--> Selected Random AirVPN Config: $(basename "$RANDOM_CONFIG")"

mkdir -p /etc/openvpn/client
ln -sf "$RANDOM_CONFIG" "$SYSTEM_OVPN_LINK"

echo "--> Stopping existing OpenVPN instances..."
systemctl stop openvpn-client@airvpn-active 2>/dev/null || killall openvpn 2>/dev/null || true
sleep 1

echo "--> Starting OpenVPN daemon..."
openvpn --config "$SYSTEM_OVPN_LINK" --daemon airvpn_tun

# Extract Remote Server details for firewall whitelisting
REMOTE_LINE=$(grep -E '^\s*remote\s+' "$RANDOM_CONFIG" | head -n1)
SERVER_IP=$(echo "$REMOTE_LINE" | awk '{print $2}')
SERVER_PORT=$(echo "$REMOTE_LINE" | awk '{print $3}')
SERVER_PROTO=$(grep -E '^\s*proto\s+' "$RANDOM_CONFIG" | head -n1 | awk '{print $2}' || echo "udp")
[[ "$SERVER_PROTO" == "udp"* ]] && PROTO="udp" || PROTO="tcp"

echo "--> Configuring Firewall Kill Switch..."
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

if command -v ufw &>/dev/null; then
    ufw --force reset > /dev/null
    ufw default deny outgoing
    ufw default deny incoming
    ufw allow in on lo
    ufw allow out on lo
    ufw allow out to 192.168.0.0/16
    ufw allow out to 10.0.0.0/8
    ufw allow out on tun0
    if [ -n "$SERVER_IP" ] && [ -n "$SERVER_PORT" ]; then
        ufw allow out on "$DEFAULT_IFACE" to "$SERVER_IP" port "$SERVER_PORT" proto "$PROTO"
    fi
    ufw --force enable > /dev/null
elif command -v firewall-cmd &>/dev/null; then
    # FirewallD configuration handling if preferred on Fedora
    firewall-cmd --set-default-zone=drop
    firewall-cmd --permanent --zone=trusted --add-interface=tun0
    firewall-cmd --permanent --zone=external --add-interface="$DEFAULT_IFACE"
    firewall-cmd --reload
fi
echo "✅ Firewall Kill Switch activated."

echo "--> Verifying VPN routing..."
for i in {1..10}; do
    if ip link show tun0 >/dev/null 2>&1; then break; fi
    sleep 1
done

if ping -c 2 1.1.1.1 > /dev/null 2>&1; then
    echo "✅ Internet connection active via VPN."
    /home/media/docker/scripts/vpn/vpn-status.sh
else
    echo "❌ Connection check failed! Tearing down..."
    killall openvpn 2>/dev/null || true
    if command -v ufw &>/dev/null; then ufw --force disable > /dev/null; fi
    exit 1
fi
