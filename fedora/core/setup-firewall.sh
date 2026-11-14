#!/usr/bin/env bash
# ==============================================================================
# Script: setup-firewall.sh
# Description: Configures firewalld rules for homelab services
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
check_dependency "firewall-cmd"

print_banner "FIREWALLD SECURITY CONFIGURATION"

systemctl enable --now firewalld

# Open essential services permanently
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --add-service=samba
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-port=22/tcp
firewall-cmd --permanent --add-port=8096/tcp
firewall-cmd --permanent --add-port=8989/tcp
firewall-cmd --permanent --add-port=7878/tcp

firewall-cmd --reload
log_msg "INFO" "Firewall rules applied and reloaded successfully."
