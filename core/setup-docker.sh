#!/usr/bin/env bash
# ==============================================================================
# Script: core/setup-docker.sh
# Description: Fedora Docker Engine Provisioner, User Permissions & Log Limits
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_JSON="${ROOT_DIR}/config.json"
SYSTEM_JSON="${ROOT_DIR}/config/system.json"

if [[ -f "${ROOT_DIR}/lib.sh" ]]; then
    source "${ROOT_DIR}/lib.sh"
elif [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root

print_banner "DOCKER ENGINE & CONFIGURATION SETUP (FEDORA)"

# 1. Install Docker Engine & Dependencies via DNF
log_msg "INFO" "Installing Docker Engine and Compose plugin for Fedora..."
dnf install -y dnf-plugins-core
dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo || true
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 2. Configure Global Log Rotation Daemon Limits
RAW_LOG_SIZE="1GB"
LOG_MAX_FILES="3"

if [[ -f "$SYSTEM_JSON" ]] && command -v jq &>/dev/null; then
    RAW_LOG_SIZE=$(jq -r '.maintenance.docker_log_max_file_size // "1GB"' "$SYSTEM_JSON")
    LOG_MAX_FILES=$(jq -r '.maintenance.docker_log_max_files // "3"' "$SYSTEM_JSON")
elif [[ -f "$CONFIG_JSON" ]] && command -v jq &>/dev/null; then
    RAW_LOG_SIZE=$(jq -r '.maintenance.docker_log_max_file_size // "1GB"' "$CONFIG_JSON")
    LOG_MAX_FILES=$(jq -r '.maintenance.docker_log_max_files // "3"' "$CONFIG_JSON")
fi

# Convert human-readable size (e.g., 1GB, 500MB) to Docker daemon format (1g, 500m)
DOCKER_FORMATTED_SIZE="1g"
if command -v format_docker_log_size &>/dev/null; then
    DOCKER_FORMATTED_SIZE=$(format_docker_log_size "$RAW_LOG_SIZE" "1g")
fi

log_msg "INFO" "Configuring Docker daemon log limits (Max Size: ${DOCKER_FORMATTED_SIZE}, Max Files: ${LOG_MAX_FILES})..."
mkdir -p /etc/docker
cat <<EOF > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${DOCKER_FORMATTED_SIZE}",
    "max-file": "${LOG_MAX_FILES}"
  }
}
EOF

# 3. Enable and Start Docker Service
systemctl daemon-reload
systemctl enable --now docker
log_msg "INFO" "Docker service started successfully."

# 4. Group Management: Add all system users (UID >= 1000) to docker group
log_msg "INFO" "Creating docker group and assigning system users..."
groupadd -f docker

while IFS=: read -r username _ uid _ _ home shell; do
    if (( uid >= 1000 )) && [[ "$username" != "nobody" ]]; then
        log_msg "INFO" "Adding user '${username}' to the docker group."
        usermod -aG docker "$username"
    fi
done < /etc/passwd

# Add SUDO_USER if invoked via sudo
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    log_msg "INFO" "Adding sudo caller '${SUDO_USER}' to the docker group."
    usermod -aG docker "$SUDO_USER"
fi

# 5. Directory & Symlink Setup
TARGET_USER="${SUDO_USER:-$(id -un 1000 2>/dev/null || echo "media")}"
USER_HOME=$(eval echo "~${TARGET_USER}")
USER_DOCKER_DIR="${USER_HOME}/docker"
SYSTEM_DOCKER_DIR="/var/local/server-configs/docker"

if [[ -f "$CONFIG_JSON" ]] && command -v jq &>/dev/null; then
    SYSTEM_DOCKER_DIR=$(jq -r '.paths.docker_configs_local // "/var/local/server-configs/docker"' "$CONFIG_JSON")
fi

log_msg "INFO" "Configuring Docker configuration directory structure..."
mkdir -p "$SYSTEM_DOCKER_DIR"
mkdir -p "$USER_DOCKER_DIR"

if [[ ! -L "$SYSTEM_DOCKER_DIR" && -d "$SYSTEM_DOCKER_DIR" && "$SYSTEM_DOCKER_DIR" != "$USER_DOCKER_DIR" ]]; then
    chown -R "${TARGET_USER}:${TARGET_USER}" "$USER_DOCKER_DIR"
    chown -R "${TARGET_USER}:${TARGET_USER}" "$SYSTEM_DOCKER_DIR"
fi

print_banner "DOCKER PROVISIONING COMPLETE"
log_msg "INFO" "Docker installation and configuration complete!"
echo -e "${COLOR_GREEN}Users added to 'docker' group must log out and back in for group changes to take effect.${COLOR_RESET}\n"
