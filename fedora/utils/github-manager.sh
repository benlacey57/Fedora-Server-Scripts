#!/usr/bin/env bash
# ==============================================================================
# Script: github-manager.sh
# Description: GitHub Repositories Lifecycle, Git Identity & Tools Checkout Manager
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_JSON="${ROOT_DIR}/config.json"
BACKUP_DIR="/config/github"

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

# Target user directory resolution (~/tools/)
REAL_USER="${SUDO_USER:-$USER}"
REAL_USER_HOME=$(eval echo "~${REAL_USER}")
TOOLS_REL_DIR=$(read_json_config "$CONFIG_JSON" '.system.tools_base_dir // "tools"')
TARGET_TOOLS_DIR="${REAL_USER_HOME}/${TOOLS_REL_DIR}"

# Docbloc: Backup active repository metadata and commit hashes to /config/github
backup_repo_state() {
    local timestamp dest
    timestamp=$(date +%Y%m%d_%H%M%S)
    dest="${BACKUP_DIR}/repos_backup_${timestamp}"

    mkdir -p "${dest}"
    log_msg "INFO" "Backing up repository metadata and commit SHAs to ${dest}..."

    if [[ -d "$TARGET_TOOLS_DIR" ]]; then
        for repo_dir in "${TARGET_TOOLS_DIR}"/*; do
            if [[ -d "${repo_dir}/.git" ]]; then
                local r_name sha
                r_name=$(basename "$repo_dir")
                sha=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo "unknown")
                echo "${r_name}: ${sha}" >> "${dest}/repo_commit_shas.txt"
            fi
        done
    fi

    log_msg "INFO" "Repository state successfully backed up."
}

# Docbloc: Action confirmation prompt with change summary and warnings
confirm_action() {
    local action="$1"
    local target="$2"
    local summary="$3"
    local is_destructive="${4:-false}"

    echo -e "\n${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}                         ACTION CONFIRMATION & SUMMARY                          ${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    printf "%-20s : %s\n" "Requested Action" "${action}"
    printf "%-20s : %s\n" "Target Directory" "${target}"
    printf "%-20s : %s\n" "Summary of Changes" "${summary}"

    if [[ "$is_destructive" == "true" ]]; then
        echo -e "${COLOR_RED}WARNING: THIS WILL REVERT LOCAL CHANGES OR REMOVE REPOSITORY DIRECTORIES!${COLOR_RESET}"
        echo -e "${COLOR_ORANGE}================================================================================${COLOR_RESET}"
        read -rp "Type 'CONFIRM' to execute this action: " CONFIRM_INPUT
        if [[ "$CONFIRM_INPUT" != "CONFIRM" ]]; then
            log_msg "WARN" "Operation canceled by user."
            return 1
        fi
    else
        echo -e "${COLOR_ORANGE}================================================================================${COLOR_RESET}"
        read -rp "Proceed with these changes? [y/N]: " CONFIRM_INPUT
        if [[ "${CONFIRM_INPUT,,}" != "y" ]]; then
            log_msg "WARN" "Operation canceled by user."
            return 1
        fi
    fi
    return 0
}

# Docbloc: Display clean overview of configured GitHub repositories and their local checkout status
show_repo_overview() {
    print_banner "GITHUB REPOSITORIES OVERVIEW (~/${TOOLS_REL_DIR}/)"

    if [[ ! -f "$CONFIG_JSON" ]]; then
        log_msg "ERROR" "Configuration file ${CONFIG_JSON} not found."
        return 1
    fi

    printf "%-18s %-12s %-45s %-20s\n" "Repo Name" "Status" "Remote URL" "Last Commit SHA"
    echo "----------------------------------------------------------------------------------------------------"

    local repo_count
    repo_count=$(read_json_config "$CONFIG_JSON" '.github_repos | length // 0')

    for (( i=0; i<repo_count; i++ )); do
        local name url dest status commit_sha
        name=$(read_json_config "$CONFIG_JSON" ".github_repos[$i].name")
        url=$(read_json_config "$CONFIG_JSON" ".github_repos[$i].url")
        dest="${TARGET_TOOLS_DIR}/${name}"

        if [[ -d "${dest}/.git" ]]; then
            status="Checked Out"
            commit_sha=$(git -C "$dest" rev-parse --short HEAD 2>/dev/null || echo "unknown")
            printf "${COLOR_GREEN}%-18s %-12s${COLOR_RESET} %-45s %-20s\n" "$name" "$status" "${url:0:44}" "$commit_sha"
        else
            status="Missing"
            commit_sha="N/A"
            printf "${COLOR_RED}%-18s %-12s${COLOR_RESET} %-45s %-20s\n" "$name" "$status" "${url:0:44}" "$commit_sha"
        fi
    done
    echo ""
}

# Docbloc: Configure global Git user.name, user.email, and init.defaultBranch from config.json
configure_git_identity() {
    print_banner "CONFIGURE GLOBAL GIT IDENTITY"

    local git_name git_email git_branch
    git_name=$(read_json_config "$CONFIG_JSON" '.git.user_name // ""')
    git_email=$(read_json_config "$CONFIG_JSON" '.git.user_email // ""')
    git_branch=$(read_json_config "$CONFIG_JSON" '.git.default_branch // "main"')

    if [[ -z "$git_name" || -z "$git_email" ]]; then
        log_msg "WARN" "Git identity incomplete in ${CONFIG_JSON}."
        read -rp "Enter Git Full Name: " git_name
        read -rp "Enter Git Email Address: " git_email
    fi

    confirm_action "Configure Git Identity" "Global Config" "Set user.name='$git_name', user.email='$git_email', defaultBranch='$git_branch'" "false" || return 0

    log_msg "INFO" "Applying global Git identity for user '${REAL_USER}'..."
    sudo -u "${REAL_USER}" git config --global user.name "$git_name"
    sudo -u "${REAL_USER}" git config --global user.email "$git_email"
    sudo -u "${REAL_USER}" git config --global init.defaultBranch "$git_branch"

    log_msg "INFO" "Global Git identity updated successfully:"
    echo "  user.name          : ${git_name}"
    echo "  user.email         : ${git_email}"
    echo "  init.defaultBranch : ${git_branch}"
    echo ""
}

# Docbloc: Display instructions and public key for adding SSH key to GitHub
show_github_ssh_instructions() {
    print_banner "INSTRUCTIONS: ADD SSH KEY TO GITHUB"

    local ssh_dir="${REAL_USER_HOME}/.ssh"
    local pub_key="${ssh_dir}/id_ed25519.pub"

    if [[ ! -f "$pub_key" ]]; then
        log_msg "WARN" "No default Ed25519 public key found at ${pub_key}."
        log_msg "INFO" "Generating new Ed25519 key for GitHub..."
        mkdir -p "$ssh_dir"
        local email
        email=$(read_json_config "$CONFIG_JSON" '.git.user_email // "user@hostname"')
        sudo -u "${REAL_USER}" ssh-keygen -t ed25519 -C "$email" -f "${ssh_dir}/id_ed25519" -N ""
        chmod 700 "$ssh_dir"
        chmod 600 "${ssh_dir}/id_ed25519"
        chmod 644 "$pub_key"
    fi

    echo -e "${COLOR_GREEN}Your Public SSH Key (${pub_key}):${COLOR_RESET}\n"
    cat "$pub_key"
    echo ""

    echo -e "${COLOR_CYAN}Follow these steps to add this key to your GitHub Account:${COLOR_RESET}"
    echo "  1. Copy the public key text displayed above."
    echo "  2. Open your browser and log into GitHub (https://github.com)."
    echo "  3. Go to Settings -> SSH and GPG keys (https://github.com/settings/keys)."
    echo "  4. Click 'New SSH key'."
    echo "  5. Give your key a descriptive title (e.g., 'Fedora Homelab Server')."
    echo "  6. Paste your key into the 'Key' field and click 'Add SSH key'."
    echo ""
    echo -e "${COLOR_CYAN}Test your SSH connection to GitHub:${COLOR_RESET}"
    echo "  Run: ssh -T git@github.com"
    echo ""
}

# Docbloc: Clone missing repositories declared in config.json
clone_missing_repos() {
    print_banner "CLONE MISSING REPOSITORIES"

    local repo_count to_clone=()
    repo_count=$(read_json_config "$CONFIG_JSON" '.github_repos | length // 0')

    for (( i=0; i<repo_count; i++ )); do
        local name dest
        name=$(read_json_config "$CONFIG_JSON" ".github_repos[$i].name")
        dest="${TARGET_TOOLS_DIR}/${name}"

        if [[ ! -d "$dest" ]]; then
            to_clone+=("$i")
        fi
    done

    if (( ${#to_clone[@]} == 0 )); then
        log_msg "INFO" "All repositories listed in config.json are already checked out."
        return 0
    fi

    confirm_action "Clone Missing Repositories" "$TARGET_TOOLS_DIR" "Clone ${#to_clone[@]} missing repositories into ${TARGET_TOOLS_DIR}" "false" || return 0

    mkdir -p "$TARGET_TOOLS_DIR"
    backup_repo_state

    for index in "${to_clone[@]}"; do
        local name url desc dest
        name=$(read_json_config "$CONFIG_JSON" ".github_repos[$index].name")
        url=$(read_json_config "$CONFIG_JSON" ".github_repos[$index].url")
        desc=$(read_json_config "$CONFIG_JSON" ".github_repos[$index].description")
        dest="${TARGET_TOOLS_DIR}/${name}"

        log_msg "INFO" "Cloning '${name}' (${desc})..."
        sudo -u "${REAL_USER}" git clone "$url" "$dest"
        log_msg "INFO" "Cloned ${name} into ${dest}"
    done

    chown -R "${REAL_USER}:${REAL_USER}" "$TARGET_TOOLS_DIR"
    log_msg "INFO" "All missing repositories cloned successfully."
}

# Docbloc: Pull latest git updates for all existing repositories in ~/tools/
pull_latest_updates() {
    print_banner "PULL LATEST REPOSITORY UPDATES"

    confirm_action "Pull Git Updates" "$TARGET_TOOLS_DIR" "Execute git pull --rebase on all repositories in ${TARGET_TOOLS_DIR}" "false" || return 0

    backup_repo_state

    if [[ -d "$TARGET_TOOLS_DIR" ]]; then
        for repo_dir in "${TARGET_TOOLS_DIR}"/*; do
            if [[ -d "${repo_dir}/.git" ]]; then
                local r_name
                r_name=$(basename "$repo_dir")
                log_msg "INFO" "Pulling updates for '${r_name}'..."
                (cd "$repo_dir" && sudo -u "${REAL_USER}" git pull --rebase) || log_msg "WARN" "Failed to update ${r_name}."
            fi
        done
        chown -R "${REAL_USER}:${REAL_USER}" "$TARGET_TOOLS_DIR"
        log_msg "INFO" "Finished updating repositories."
    else
        log_msg "WARN" "Tools directory '${TARGET_TOOLS_DIR}' does not exist."
    fi
}

# Docbloc: Hard reset local repository branches to match remote origin/HEAD
hard_reset_repos() {
    print_banner "HARD RESET REPOSITORIES TO ORIGIN"

    confirm_action "Git Hard Reset" "$TARGET_TOOLS_DIR" "Discard all uncommitted local modifications and hard reset to remote origin HEAD" "true" || return 0

    backup_repo_state

    if [[ -d "$TARGET_TOOLS_DIR" ]]; then
        for repo_dir in "${TARGET_TOOLS_DIR}"/*; do
            if [[ -d "${repo_dir}/.git" ]]; then
                local r_name
                r_name=$(basename "$repo_dir")
                log_msg "INFO" "Resetting '${r_name}'..."
                (cd "$repo_dir" && sudo -u "${REAL_USER}" git fetch origin && sudo -u "${REAL_USER}" git reset --hard origin/HEAD) || log_msg "WARN" "Failed to reset ${r_name}."
            fi
        done
        log_msg "INFO" "Hard reset completed on all repositories."
    fi
}

# Docbloc: Main Menu Loop
main_menu() {
    while true; do
        show_repo_overview
        print_banner "GITHUB MANAGER MENU"
        echo "1) Refresh Overview"
        echo "2) Configure Git Identity"
        echo "3) Add SSH Key to GitHub"
        echo "4) Clone Missing Repositories"
        echo "5) Pull Latest Updates"
        echo "6) Hard Reset Local Repositories"
        echo "7) Backup Repository Metadata"
        echo "8) Exit"
        read -rp "Select Option [1-8]: " CHOICE

        case "$CHOICE" in
            1) clear ;;
            2) configure_git_identity ;;
            3) show_github_ssh_instructions ;;
            4) clone_missing_repos ;;
            5) pull_latest_updates ;;
            6) hard_reset_repos ;;
            7) backup_repo_state ;;
            8) log_msg "INFO" "Exiting GitHub Manager."; exit 0 ;;
            *) log_msg "ERROR" "Invalid choice." ;;
        esac
    done
}

main_menu
