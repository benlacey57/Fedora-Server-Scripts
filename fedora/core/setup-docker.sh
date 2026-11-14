#!/usr/bin/env bash
# ==============================================================================
# Script: setup-docker.sh
# Description: Docker Engine Setup & Post-Installation Image Pull Provisioner
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_JSON="${ROOT_DIR}/config/docker.json"
CUSTOM_LOG_FILE="/var/log/homelab-docker.log"

if [[ -f "${ROOT_DIR}/lib.sh" ]]; then
    source "${ROOT_DIR}/lib.sh"
elif [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root
check_dependency "jq"

mkdir -p "$(dirname "$CUSTOM_LOG_FILE")"

log_docker_event() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}" | tee -a "$CUSTOM_LOG_FILE"
}

print_banner "DOCKER ENGINE PROVISIONING & SETUP"

# 1. Ensure Docker is installed & running
if ! command -v docker &>/dev/null; then
    log_docker_event "INFO" "Installing Docker Engine..."
    dnf install -y dnf-plugins-core
    dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
    dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

systemctl enable --now docker
log_docker_event "INFO" "Docker daemon is active and running."

# 2. Post-Installation Image Pull Routine
if [[ -f "$DOCKER_JSON" ]]; then
    print_banner "POST-INSTALLATION: PULLING DOCKER IMAGES"
    log_docker_event "INFO" "Reading container image registry from ${DOCKER_JSON}..."

    mapfile -t keys < <(jq -r '.containers | keys[]' "$DOCKER_JSON")
    
    for k in "${keys[@]}"; do
        img=$(jq -r --arg key "$k" '.containers[$key]' "$DOCKER_JSON")
        log_docker_event "INFO" "Pulling container image for '${k}' (${img})..."
        docker pull "$img" || log_docker_event "WARN" "Failed to pull image: ${img}"
    done

    log_docker_event "INFO" "Post-installation image pull completed successfully."
else
    log_docker_event "WARN" "Configuration file ${DOCKER_JSON} not found. Skipping automated image pull."
fi

print_banner "DOCKER SETUP COMPLETE"
