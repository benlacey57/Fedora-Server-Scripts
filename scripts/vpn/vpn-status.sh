#!/usr/bin/env bash
# ==============================================================================
# Script: vpn-status.sh
# Description: Displays system details, local IP, VPN status, and geolocation
# ==============================================================================
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
BOLD='\033[1m'

PUBLIC_INFO=$(curl -s --max-time 5 https://ipinfo.io/json 2>/dev/null || echo "{}")
PUB_IP=$(echo "$PUBLIC_INFO" | jq -r '.ip // "Unknown"')
CITY=$(echo "$PUBLIC_INFO" | jq -r '.city // "Unknown"')
COUNTRY=$(echo "$PUBLIC_INFO" | jq -r '.country // "Unknown"')
ORG=$(echo "$PUBLIC_INFO" | jq -r '.org // "Unknown"')

HOSTNAME=$(hostname)
LOCAL_IP=$(hostname -I | awk '{print $1}')
ACTIVE_CONF=$(readlink -f /etc/openvpn/client/airvpn-active.conf 2>/dev/null || echo "None")

if ip link show tun0 >/dev/null 2>&1; then
    STATUS="${GREEN}[ CONNECTED ]${NC}"
    ACTIVE_IFACE="tun0 (OpenVPN)"
    ACTIVE_FILE=$(basename "$ACTIVE_CONF")
else
    STATUS="${RED}[ DISCONNECTED ]${NC}"
    ACTIVE_IFACE="None"
    ACTIVE_FILE="N/A"
fi

echo -e "${BOLD}====================================================${NC}"
echo -e "${BOLD}              SYSTEM & VPN STATUS BANNER            ${NC}"
echo -e "${BOLD}====================================================${NC}"
echo -e " Hostname        : ${HOSTNAME}"
echo -e " Local IP        : ${LOCAL_IP}"
echo -e " VPN Status      : ${STATUS}"
echo -e " Active Interface: ${ACTIVE_IFACE}"
echo -e " Active Config   : ${ACTIVE_FILE}"
echo -e " Public IP       : ${PUB_IP}"
echo -e " Location        : ${CITY}, ${COUNTRY}"
echo -e " ISP / Provider  : ${ORG}"
echo -e "${BOLD}====================================================${NC}"
