#!/usr/bin/env bash
# ==============================================================================
# Script: setup-updates.sh
# Description: Automated System Updates Setup & Systemd Timer Provisioner
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
UPDATES_JSON="${ROOT_DIR}/config/updates.json"
CUSTOM_LOG_FILE="/var/log/homelab-updates.log"

if [[ -f "${ROOT_DIR}/lib.sh" ]]; then
    source "${ROOT_DIR}/lib.sh"
elif [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root
check_dependency "dnf"
check_dependency "jq"

mkdir -p "$(dirname "$CUSTOM_LOG_FILE")"

log_msg "INFO" "Starting automated updates provisioning..."

# Install dnf-automatic or dnf5-plugin-automatic
if ! rpm -q dnf-automatic &>/dev/null && ! rpm -q dnf5-plugin-automatic &>/dev/null; then
    log_msg "INFO" "Installing DNF automatic package..."
    dnf install -y dnf5-plugin-automatic 2>/dev/null || dnf install -y dnf-automatic || true
fi

# Configure automatic.conf if present
AUTO_CONF="/etc/dnf/automatic.conf"
if [[ -f "$AUTO_CONF" && -f "$UPDATES_JSON" ]]; then
    log_msg "INFO" "Configuring ${AUTO_CONF} from ${UPDATES_JSON}..."
    
    apply_upd=$(jq -r '.update_settings.apply_updates // true' "$UPDATES_JSON")
    upd_type=$(jq -r '.update_settings.upgrade_type // "default"' "$UPDATES_JSON")
    reboot_pol=$(jq -r '.update_settings.reboot_policy // "when-changed"' "$UPDATES_JSON")

    sed -i "s/^upgrade_type.*/upgrade_type = ${upd_type}/" "$AUTO_CONF" 2>/dev/null || true
    sed -i "s/^apply_updates.*/apply_updates = ${apply_upd}/" "$AUTO_CONF" 2>/dev/null || true
    sed -i "s/^reboot.*/reboot = ${reboot_pol}/" "$AUTO_CONF" 2>/dev/null || true
fi

# Enable timer
if systemctl list-unit-files | grep -q "dnf5-automatic.timer"; then
    systemctl enable --now dnf5-automatic.timer
    log_msg "INFO" "Enabled dnf5-automatic.timer."
elif systemctl list-unit-files | grep -q "dnf-automatic.timer"; then
    systemctl enable --now dnf-automatic.timer
    log_msg "INFO" "Enabled dnf-automatic.timer."
fi

log_msg "INFO" "Automated updates provisioning complete. All logs routed to ${CUSTOM_LOG_FILE}."
