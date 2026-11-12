#!/usr/bin/env bash
# ==============================================================================
# Script: setup-users.sh
# Description: Provisions system users and groups for homelab services
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

print_banner "SYSTEM USERS PROVISIONING"

# Create media user if it doesn't exist
if ! id "media" &>/dev/null; then
    useradd -r -s /usr/sbin/nologin -d /var/sftp/media -m media
    log_msg "INFO" "Created system user 'media'."
else
    log_msg "INFO" "User 'media' already exists."
fi

usermod -aG sftpusers media
log_msg "INFO" "Users and groups successfully configured."
