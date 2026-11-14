#!/usr/bin/env bash
# ==============================================================================
# Script: setup-fedora.sh
# Description: Fedora System Hardening, DNF Auto-tuning, and Tools Setup
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_JSON="${SCRIPT_DIR}/config.json"

if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root
check_dependency "jq"

print_banner "FEDORA SERVER SYSTEM AUTO-TUNING & TOOLS SETUP"

# --- 1. DNF Speed & Performance Improvements ---
log_msg "INFO" "Configuring DNF speed enhancements..."
DNF_CONF="/etc/dnf/dnf.conf"

MAX_PARALLEL=$(read_json_config "$CONFIG_JSON" '.dnf.max_parallel_downloads // 10')
FASTESTMIRROR=$(read_json_config "$CONFIG_JSON" '.dnf.fastestmirror // true')
DELTARPM=$(read_json_config "$CONFIG_JSON" '.dnf.deltarpm // false')

if [[ -f "$DNF_CONF" && ! -f "${DNF_CONF}.bak" ]]; then
    cp "$DNF_CONF" "${DNF_CONF}.bak"
    log_msg "INFO" "Backed up ${DNF_CONF} to ${DNF_CONF}.bak"
fi

grep -q "^max_parallel_downloads=" "$DNF_CONF" && \
    sed -i "s/^max_parallel_downloads=.*/max_parallel_downloads=${MAX_PARALLEL}/" "$DNF_CONF" || \
    echo "max_parallel_downloads=${MAX_PARALLEL}" >> "$DNF_CONF"

grep -q "^fastestmirror=" "$DNF_CONF" && \
    sed -i "s/^fastestmirror=.*/fastestmirror=${FASTESTMIRROR}/" "$DNF_CONF" || \
    echo "fastestmirror=${FASTESTMIRROR}" >> "$DNF_CONF"

grep -q "^deltarpm=" "$DNF_CONF" && \
    sed -i "s/^deltarpm=.*/deltarpm=${DELTARPM}/" "$DNF_CONF" || \
    echo "deltarpm=${DELTARPM}" >> "$DNF_CONF"

log_msg "INFO" "DNF configuration optimized."

# --- 2. System Packages Installation ---
log_msg "INFO" "Updating package lists and upgrading system packages..."
dnf upgrade -y --refresh -q

log_msg "INFO" "Reading system packages from ${CONFIG_JSON}..."
PACKAGES=$(read_json_config "$CONFIG_JSON" '.packages[]' | tr '\n' ' ')

if [[ -n "$PACKAGES" ]]; then
    log_msg "INFO" "Installing packages: ${PACKAGES}"
    dnf install -y $PACKAGES
fi

# --- 3. Directory Structure Creation ---
log_msg "INFO" "Creating standard homelab directories..."
REAL_USER="${SUDO_USER:-$USER}"
REAL_USER_HOME=$(eval echo "~${REAL_USER}")
TOOLS_REL_DIR=$(read_json_config "$CONFIG_JSON" '.system.tools_base_dir // "tools"')
TARGET_TOOLS_DIR="${REAL_USER_HOME}/${TOOLS_REL_DIR}"

SCRIPTS_DIR=$(read_json_config "$CONFIG_JSON" '.system.scripts_dir // "/home/media/scripts"')
STORAGE_DIR=$(read_json_config "$CONFIG_JSON" '.system.storage_dir // "/mnt/storage"')
BACKUP_DIR=$(read_json_config "$CONFIG_JSON" '.system.backup_dir // "/mnt/backup"')

mkdir -p "$TARGET_TOOLS_DIR" "$SCRIPTS_DIR" "$STORAGE_DIR" "$BACKUP_DIR"
chown -R "${REAL_USER}:${REAL_USER}" "$TARGET_TOOLS_DIR" "$SCRIPTS_DIR"
log_msg "INFO" "Tools directory initialized at: ${TARGET_TOOLS_DIR}"

# --- 4. Checkout Repositories directly to ~/tools/ ---
log_msg "INFO" "Checking out GitHub repositories into ${TARGET_TOOLS_DIR}..."
REPO_COUNT=$(read_json_config "$CONFIG_JSON" '.github_repos | length')

for (( i=0; i<REPO_COUNT; i++ )); do
    NAME=$(read_json_config "$CONFIG_JSON" ".github_repos[$i].name")
    URL=$(read_json_config "$CONFIG_JSON" ".github_repos[$i].url")
    DESC=$(read_json_config "$CONFIG_JSON" ".github_repos[$i].description")
    DEST_PATH="${TARGET_TOOLS_DIR}/${NAME}"

    log_msg "INFO" "Processing repository '${NAME}': ${DESC}"

    if [[ ! -d "$DEST_PATH" ]]; then
        log_msg "INFO" "Cloning ${NAME} into ${DEST_PATH}..."
        sudo -u "${REAL_USER}" git clone "$URL" "$DEST_PATH"
    else
        log_msg "WARN" "Directory ${DEST_PATH} already exists. Fetching updates..."
        (cd "$DEST_PATH" && sudo -u "${REAL_USER}" git pull) || log_msg "WARN" "Git update failed for ${NAME}."
    fi
done

# --- 5. Security Service Initialization ---
log_msg "INFO" "Enabling Fail2ban security service..."
systemctl enable --now fail2ban

print_banner "SETUP COMPLETE"
log_msg "INFO" "Fedora homelab setup and code checkouts completed successfully."