#!/usr/bin/env bash
# ==============================================================================
# Script: setup-github.sh
# Description: Configures Git, installs GitHub CLI, and clones target homelab repositories
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
GITHUB_JSON="${ROOT_DIR}/config/github.json"
CUSTOM_LOG_FILE="/var/log/homelab-github.log"

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
check_dependency "git"

mkdir -p "$(dirname "$CUSTOM_LOG_FILE")"

log_github_event() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}" | tee -a "$CUSTOM_LOG_FILE"
}

print_banner "GITHUB & REPOSITORY SETUP"

if [[ ! -f "$GITHUB_JSON" ]]; then
    log_github_event "ERROR" "Configuration file ${GITHUB_JSON} not found."
    exit 1
fi

# 1. Read configuration values
GIT_NAME=$(jq -r '.git.user_name // "Homelab Admin"' "$GITHUB_JSON")
GIT_EMAIL=$(jq -r '.git.user_email // "admin@homelab.lan"' "$GITHUB_JSON")
GIT_BRANCH=$(jq -r '.git.default_branch // "main"' "$GITHUB_JSON")
INSTALL_GH=$(jq -r '.github_cli.install // true' "$GITHUB_JSON")

# 2. Configure Global Git settings
log_github_event "INFO" "Configuring global Git user and settings..."
git config --global user.name "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"
git config --global init.defaultBranch "$GIT_BRANCH"

# 3. Install GitHub CLI if enabled
if [[ "$INSTALL_GH" == "true" ]]; then
    if ! command -v gh &>/dev/null; then
        log_github_event "INFO" "Installing GitHub CLI (gh) on Fedora..."
        dnf install -y 'dnf-command(config-manager)' || true
        dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
        dnf install -y gh
        log_github_event "SUCCESS" "GitHub CLI installed successfully."
    else
        log_github_event "INFO" "GitHub CLI (gh) is already installed."
    fi
fi

# 4. Clone or update repositories defined in config
print_banner "CLONING CONFIGURED HOMELAB REPOSITORIES"
repo_count=$(jq '.repositories | length' "$GITHUB_JSON")

for ((i=0; i<repo_count; i++)); do
    repo_name=$(jq -r ".repositories[$i].name" "$GITHUB_JSON")
    repo_url=$(jq -r ".repositories[$i].url" "$GITHUB_JSON")
    output_dir=$(jq -r ".repositories[$i].output_dir" "$GITHUB_JSON")

    log_github_event "INFO" "Processing repository: ${repo_name} (${repo_url})"
    
    if [[ -d "${output_dir}/.git" ]]; then
        log_github_event "INFO" "Repository directory ${output_dir} already exists. Pulling latest updates..."
        git -C "$output_dir" pull origin "$GIT_BRANCH" || log_github_event "WARN" "Failed to pull updates for ${repo_name}"
    else
        mkdir -p "$(dirname "$output_dir")"
        log_github_event "INFO" "Cloning ${repo_name} into ${output_dir}..."
        git clone "$repo_url" "$output_dir" || log_github_event "ERROR" "Failed to clone ${repo_name}"
    fi
done

print_banner "GITHUB & REPOSITORY SETUP COMPLETE"
