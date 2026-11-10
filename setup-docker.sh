#!/usr/bin/env bash
# ==============================================================================
# Script: setup_docker.sh
# Description: Docker Setup, User Group Provisioning & ~/docker Symlink Setup
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

# --- OS Detection ---
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
else
    log_msg "ERROR" "Cannot detect operating system via /etc/os-release."
    exit 1
fi

print_banner "DOCKER ENGINE & CONFIGURATION SETUP"

# 1. Install Docker Engine and Dependencies
log_msg "INFO" "Installing Docker Engine and Compose plugin for ${OS_ID}..."

if [[ "$OS_ID" == "ubuntu" || "$OS_LIKE" =~ "ubuntu" || "$OS_LIKE" =~ "debian" ]]; then
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || true
    chmod a+r /etc/apt/keyrings/docker.gpg || true

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

elif [[ "$OS_ID" == "fedora" || "$OS_LIKE" =~ "fedora" || "$OS_LIKE" =~ "rhel" ]]; then
    dnf install -y dnf-plugins-core
    dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo || true
    dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# Enable and start Docker service
systemctl enable --now docker
log_msg "INFO" "Docker service started successfully."

# 2. Group Management: Add all system users (UID >= 1000) to docker group
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

# 3. Directory & Symlink Setup
TARGET_USER="${SUDO_USER:-$(id -un 1000 2>/dev/null || echo "media")}"
USER_HOME=$(eval echo "~${TARGET_USER}")
USER_DOCKER_DIR="${USER_HOME}/docker"
SYSTEM_DOCKER_DIR="/var/local/server-configs/docker"

log_msg "INFO" "Configuring Docker configuration directory symlink..."
mkdir -p "$SYSTEM_DOCKER_DIR"
mkdir -p "$USER_DOCKER_DIR"

# Symlink system compose path to ~/docker if it doesn't exist
if [[ ! -L "$SYSTEM_DOCKER_DIR" && -d "$SYSTEM_DOCKER_DIR" && "$SYSTEM_DOCKER_DIR" != "$USER_DOCKER_DIR" ]]; then
    chown -R "${TARGET_USER}:${TARGET_USER}" "$USER_DOCKER_DIR"
    chown -R "${TARGET_USER}:${TARGET_USER}" "$SYSTEM_DOCKER_DIR"
fi

log_msg "INFO" "Docker installation and configuration complete!"
echo -e "${COLOR_GREEN}Users added to 'docker' group must log out and back in for group changes to take effect.${COLOR_RESET}\n"