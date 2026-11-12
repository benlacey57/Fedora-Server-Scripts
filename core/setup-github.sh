#!/usr/bin/env bash
# ==============================================================================
# Script: setup-github.sh
# Description: Sets up git configuration and deployment keys for repo synchronization
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
check_dependency "git"

print_banner "GITHUB REPOSITORY INTEGRATION SETUP"

read -rp "Enter Git repository URL: " REPO_URL

if [[ -n "$REPO_URL" ]]; then
    cd "$ROOT_DIR"
    if [[ ! -d ".git" ]]; then
        git init
        git remote add origin "$REPO_URL"
        log_msg "INFO" "Git repository initialized and remote origin linked."
    else
        log_msg "INFO" "Git repository already initialized."
    fi
else
    log_msg "WARN" "No repository URL provided. Skipping git remote initialization."
fi
