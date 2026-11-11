#!/usr/bin/env bash
# ==============================================================================
# Script: ssh-manager.sh
# Description: SSH Daemon Hardening, Key Lifecycle & Multi-User Key Backups
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_JSON="${ROOT_DIR}/config.json"
SSH_JSON="${ROOT_DIR}/config/ssh.json"
BACKUP_DIR="/config/ssh"
KEY_BACKUP_DIR="/config/ssh/user_keys_backups"

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
check_dependency "ssh-keygen"

REAL_USER="${SUDO_USER:-$USER}"
REAL_USER_HOME=$(eval echo "~${REAL_USER}")

# Docbloc: Backup active SSH daemon configuration files
backup_ssh_configs() {
    local timestamp dest
    timestamp=$(date +%Y%m%d_%H%M%S)
    dest="${BACKUP_DIR}/sshd_backup_${timestamp}"

    mkdir -p "${dest}"
    log_msg "INFO" "Backing up SSH daemon configuration files to ${dest}..."

    [[ -f /etc/ssh/sshd_config ]] && cp /etc/ssh/sshd_config "${dest}/sshd_config.bak" 2>/dev/null || true
    [[ -d /etc/ssh/sshd_config.d ]] && cp -r /etc/ssh/sshd_config.d "${dest}/sshd_config.d.bak" 2>/dev/null || true
    [[ -f "${REAL_USER_HOME}/.ssh/authorized_keys" ]] && cp "${REAL_USER_HOME}/.ssh/authorized_keys" "${dest}/authorized_keys.bak" 2>/dev/null || true

    log_msg "INFO" "SSH daemon configuration successfully backed up."
}

# Docbloc: Display confirmation prompt with change summary box
confirm_action() {
    local action="$1"
    local target="$2"
    local summary="$3"
    local is_destructive="${4:-false}"

    echo -e "\n${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}                         ACTION CONFIRMATION & SUMMARY${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    printf "%-20s : %s\n" "Requested Action" "${action}"
    printf "%-20s : %s\n" "Target File/User" "${target}"
    printf "%-20s : %s\n" "Summary of Changes" "${summary}"

    if [[ "$is_destructive" == "true" ]]; then
        echo -e "${COLOR_RED}WARNING: THIS MODIFIES SYSTEM SSH SECURITY RULES, USER KEYS, OR RESTARTS DAEMON!${COLOR_RESET}"
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

# Docbloc: Display SSH daemon overview and active login sessions
show_ssh_overview() {
    print_banner "SSH DAEMON & SESSION OVERVIEW"

    local active_port
    active_port=$(ss -tulpn | grep sshd | awk '{print $5}' \vert{} awk -F: '{print$NF}' | head -n1 || echo "22")

    echo -e "SSH Daemon Service State : ${COLOR_GREEN}$(systemctl is-active sshd 2>/dev/null \vert{}\vert{} systemctl is-active ssh 2>/dev/null \vert{}\vert{} echo "inactive")${COLOR_RESET}"
    echo -e "Listening Port           : ${COLOR_GREEN}${active_port}${COLOR_RESET}"
    echo -e "Target Admin User Home   : ${REAL_USER_HOME}/.ssh"
    echo ""

    echo -e "${COLOR_CYAN}Active Remote SSH Sessions (who / w):${COLOR_RESET}"
    who | grep -i pts || echo "  No active remote SSH logins."
    echo ""
}

# Docbloc: Prompt user creation flow if targeted user does not exist
create_new_user_prompt() {
    local target_user="$1"
    log_msg "WARN" "User '${target_user}' does not exist on this system."
    read -rp "Create user '${target_user}' now? [Y/n]: " CREATE_CONF
    CREATE_CONF="${CREATE_CONF:-Y}"

    if [[ "${CREATE_CONF,,}" != "y" ]]; then
        log_msg "ERROR" "User creation cancelled."
        return 1
    fi

    read -rp "Enter home directory [/home/${target_user}]: " CUSTOM_HOME
    CUSTOM_HOME="${CUSTOM_HOME:-/home/${target_user}}"

    read -rp "Enter shell [/bin/bash]: " CUSTOM_SHELL
    CUSTOM_SHELL="${CUSTOM_SHELL:-/bin/bash}"

    read -rp "Enter groups (e.g., wheel,docker,media): " CUSTOM_GROUPS

    local useradd_cmd=("useradd" "-m" "-d" "$CUSTOM_HOME" "-s" "$CUSTOM_SHELL")
    if [[ -n "$CUSTOM_GROUPS" ]]; then
        useradd_cmd+=("-G" "$CUSTOM_GROUPS")
    fi
    useradd_cmd+=("$target_user")

    log_msg "INFO" "Creating user '${target_user}'..."
    "${useradd_cmd[@]}"

    log_msg "INFO" "Setting password for user '${target_user}':"
    passwd "$target_user"

    read -rp "Force password change on first login? [y/N]: " FORCE_EXP
    if [[ "${FORCE_EXP,,}" == "y" ]]; then
        chage -d 0 "$target_user"
        log_msg "INFO" "Password expiration set for '${target_user}'."
    fi

    log_msg "INFO" "User '${target_user}' created successfully."
    return 0
}

# Docbloc: Apply SSH hardening parameters defined in config/ssh.json
apply_ssh_hardening() {
    print_banner "APPLY SSH HARDENING CONFIGURATION"

    local port permit_root pass_auth pubkey_auth max_tries
    if [[ -f "$SSH_JSON" ]] && command -v jq &>/dev/null; then
        port=$(jq -r '.ssh_daemon.port // 22' "$SSH_JSON")
        permit_root=$(jq -r '.ssh_daemon.permit_root_login // "no"' "$SSH_JSON")
        pass_auth=$(jq -r '.ssh_daemon.password_authentication // "no"' "$SSH_JSON")
        pubkey_auth=$(jq -r '.ssh_daemon.pubkey_authentication // "yes"' "$SSH_JSON")
        max_tries=$(jq -r '.ssh_daemon.max_auth_tries // 3' "$SSH_JSON")
    else
        port="22"
        permit_root="no"
        pass_auth="no"
        pubkey_auth="yes"
        max_tries="3"
    fi

    local summary_msg="Apply drop-in /etc/ssh/sshd_config.d/99-hardening.conf (Port: ${port}, RootLogin: ${permit_root}, PassAuth:${pass_auth})"
    confirm_action "SSH Hardening" "/etc/ssh/sshd_config.d/99-hardening.conf" "$summary_msg" "true" || return 0

    backup_ssh_configs

    mkdir -p /etc/ssh/sshd_config.d
    cat <<EOF > /etc/ssh/sshd_config.d/99-hardening.conf
# Managed by Homelab SSH Manager
Port ${port}
PermitRootLogin ${permit_root}
PasswordAuthentication ${pass_auth}
PubkeyAuthentication ${pubkey_auth}
MaxAuthTries ${max_tries}
X11Forwarding no
AllowTcpForwarding yes
EOF

    log_msg "INFO" "Validating sshd configuration syntax..."
    if sshd -t; then
        log_msg "INFO" "Configuration valid. Restarting sshd service..."
        systemctl restart sshd 2>/dev/null || systemctl restart ssh
        log_msg "INFO" "SSH hardening applied successfully."
    else
        log_msg "ERROR" "Invalid sshd configuration syntax. Rolling back..."
        rm -f /etc/ssh/sshd_config.d/99-hardening.conf
        return 1
    fi
}

# Docbloc: Generate new SSH key pair with overwrite and custom filename prompts
generate_ssh_key() {
    print_banner "GENERATE USER SSH KEYPAIR"

    local key_type="ed25519"
    if [[ -f "$SSH_JSON" ]] && command -v jq &>/dev/null; then
        key_type=$(jq -r '.key_defaults.key_type // "ed25519"' "$SSH_JSON")
    fi

    read -rp "Enter username [default: ${REAL_USER}]: " TARGET_USER
    TARGET_USER="${TARGET_USER:-$REAL_USER}"
    validate_string "$TARGET_USER" "username" || return 1

    if ! id "$TARGET_USER" &>/dev/null; then
        create_new_user_prompt "$TARGET_USER" || return 1
    fi

    local target_home
    target_home=$(eval echo "~${TARGET_USER}")
    local ssh_dir="${target_home}/.ssh"
    mkdir -p "$ssh_dir"

    local default_key="${ssh_dir}/id_${key_type}"
    local final_key="$default_key"

    if [[ -f "$default_key" ]]; then
        log_msg "WARN" "Key already exists at ${default_key}"
        read -rp "Overwrite existing key? [y/N]: " OVERWRITE_CHOICE
        if [[ "${OVERWRITE_CHOICE,,}" != "y" ]]; then
            read -rp "Enter filename [default: id_${key_type}_custom]: " CUSTOM_FILENAME
            CUSTOM_FILENAME="${CUSTOM_FILENAME:-id_${key_type}_custom}"

            if [[ "$CUSTOM_FILENAME" =~ ^/ ]]; then
                final_key="$CUSTOM_FILENAME"
            else
                final_key="${ssh_dir}/${CUSTOM_FILENAME}"
            fi
        fi
    fi

    confirm_action "Generate SSH Key" "$final_key" "Generate ${key_type^^} SSH keypair for user '${TARGET_USER}'" "false" || return 0

    log_msg "INFO" "Generating ${key_type^^} key at '${final_key}'..."
    ssh-keygen -t "$key_type" -N "" -f "$final_key" -C "${TARGET_USER}@$(hostname)"

    local pub_key="${final_key}.pub"
    local auth_keys="${ssh_dir}/authorized_keys"

    touch "$auth_keys"
    if ! grep -q -f "$pub_key" "$auth_keys" 2>/dev/null; then
        cat "$pub_key" >> "$auth_keys"
        log_msg "INFO" "Appended public key to ${auth_keys}"
    fi

    chown -R "${TARGET_USER}:${TARGET_USER}" "$ssh_dir"
    chmod 700 "$ssh_dir"
    chmod 600 "$final_key" "$auth_keys"
    chmod 644 "$pub_key"

    log_msg "INFO" "SSH key generated for '${TARGET_USER}':"
    echo -e "  Private Key : ${final_key}"
    echo -e "  Public Key  : ${pub_key}\n"
}

# Docbloc: List SSH key files and authorized_keys entries for a specified user
list_user_keys() {
    print_banner "AUDIT USER SSH KEYS"

    read -rp "Enter username [default: ${REAL_USER}]: " TARGET_USER
    TARGET_USER="${TARGET_USER:-$REAL_USER}"
    validate_string "$TARGET_USER" "username" || return 1

    if ! id "$TARGET_USER" &>/dev/null; then
        log_msg "ERROR" "User '${TARGET_USER}' does not exist."
        return 1
    fi

    local target_home
    target_home=$(eval echo "~${TARGET_USER}")
    local ssh_dir="${target_home}/.ssh"

    if [[ ! -d "$ssh_dir" ]]; then
        log_msg "WARN" "No ~/.ssh directory found for user '${TARGET_USER}'."
        return 0
    fi

    echo -e "${COLOR_CYAN}Files in ${ssh_dir}:${COLOR_RESET}"
    ls -la "$ssh_dir"

    local auth_keys="${ssh_dir}/authorized_keys"
    if [[ -f "$auth_keys" ]]; then
        echo -e "\n${COLOR_CYAN}Entries in authorized_keys:${COLOR_RESET}"
        cat -n "$auth_keys"
    fi
    echo ""
}

# Docbloc: Interactively delete key files or authorized entries for a user
delete_user_keys() {
    print_banner "DELETE USER SSH KEYS"

    read -rp "Enter username [default: ${REAL_USER}]: " TARGET_USER
    TARGET_USER="${TARGET_USER:-$REAL_USER}"
    validate_string "$TARGET_USER" "username" || return 1

    if ! id "$TARGET_USER" &>/dev/null; then
        log_msg "ERROR" "User '${TARGET_USER}' does not exist."
        return 1
    fi

    local target_home
    target_home=$(eval echo "~${TARGET_USER}")
    local ssh_dir="${target_home}/.ssh"

    if [[ ! -d "$ssh_dir" ]]; then
        log_msg "WARN" "No ~/.ssh directory found for user '${TARGET_USER}'."
        return 0
    fi

    echo "1) Delete key file"
    echo "2) Delete line from authorized_keys"
    echo "3) Remove entire .ssh folder"
    read -rp "Select Option [1-3]: " DEL_CHOICE

    case "$DEL_
    
