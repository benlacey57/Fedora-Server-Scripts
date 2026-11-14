#!/usr/bin/env bash
# ==============================================================================
# Script: setup-network.sh
# Description: Configure NetworkManager settings and local DNS/bridge interfaces
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${ROOT_DIR}/lib.sh" ]]; then
    source "${ROOT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root
check_dependency "nmcli"

print_banner "NETWORK CONFIGURATION"

# Example: Ensure NetworkManager is running and set hostname
systemctl enable --now NetworkManager
hostnamectl set-hostname homelab-server

# Setup DNS?
# Install Tailscale

log_msg "INFO" "NetworkManager is active and hostname is configured."
