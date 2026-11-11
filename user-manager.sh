#!/usr/bin/env bash
# ==============================================================================
# Script: user-manager.sh
# Description: System User & Group Administration Suite
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_JSON="${SCRIPT_DIR}/../config.json"
BACKUP_DIR="/config/users"
DEFAULT_SHELL="/bin/bash"
DEFAULT_GROUP="media"

if [[ -f "${SCRIPT_DIR}/../lib.sh" ]]; then
    source "${SCRIPT_DIR}/../lib.sh"
elif [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root

backup_user_configs() {
    local timestamp dest
    timestamp=$(date +%Y%m%d_%H%M%S)
    dest="${BACKUP_DIR}/users_backup_${timestamp}"

    mkdir -p "${dest}"
    cp /etc/passwd "${dest}/passwd.bak"
    cp /etc/group "${dest}/group.bak"
    cp /etc/shadow "${dest}/shadow.bak" 2>/dev/null || true

    log_msg "INFO" "User and group configuration files backed up to ${dest}"
}

confirm_action() {
    local action="$1"
    local target="$2"
    local summary="$3"
    local is_destructive="${4:-false}"

    echo -e "\n${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}                         ACTION CONFIRMATION & SUMMARY                          ${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    printf "%-20s : %s\n" "Requested Action" "${action}"
    printf "%-20s : %s\n" "Target User/Account" "${target}"
    printf "%-20s : %s\n" "Summary of Changes" "${summary}"
    
    if [[ "$is_destructive" == "true" ]]; then
        echo -e "${COLOR_RED}WARNING: THIS DISABLES OR REMOVES A USER ACCOUNT FROM THE SYSTEM!${COLOR_RESET}"
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

list_users() {
    print_banner "SYSTEM USERS & GROUPS AUDIT"
    echo "--- Standard & Administrative Accounts ---"
    awk -F: '($3 >= 1000 || $3 == 0) {print "User: " $1 " (UID: " $3 ") | Shell: " $7}' /etc/passwd
    echo ""
    echo "--- System Groups ---"
    cut -d: -f1 /etc/group | tr '\n' ', '
    echo -e "\n"
}

add_user() {
    print_banner "ADD NEW USER ACCOUNT"
    read -rp "Enter username to create: " USERNAME
    validate_string "$USERNAME" "username" || return 1

    if id "$USERNAME" &>/dev/null; then
        log_msg "ERROR" "User '${USERNAME}' already exists."
        return 1
    fi

    confirm_action "Create Account" "$USERNAME" "Create account $USERNAME with home dir and add to docker group" "false" || return 0

    backup_user_configs
    groupadd -f "$DEFAULT_GROUP"
    useradd -m -s "$DEFAULT_SHELL" -g "$DEFAULT_GROUP" -G "docker" "$USERNAME"
    passwd "$USERNAME"
    log_msg "INFO" "User '${USERNAME}' created successfully."
}

delete_user() {
    print_banner "DELETE USER ACCOUNT"
    list_users
    read -rp "Enter username to delete: " USERNAME
    validate_string "$USERNAME" "username" || return 1

    if ! id "$USERNAME" &>/dev/null; then
        log_msg "ERROR" "User '${USERNAME}' does not exist."
        return 1
    fi

    read -rp "Delete home directory as well? [y/N]: " DEL_HOME
    local remove_home_flag="false"
    [[ "${DEL_HOME,,}" == "y" ]] && remove_home_flag="true"

    confirm_action "Delete User Account" "$USERNAME" "Remove account $USERNAME (Remove Home Directory: $remove_home_flag)" "true" || return 0

    backup_user_configs
    if [[ "$remove_home_flag" == "true" ]]; then
        userdel -r "$USERNAME"
    else
        userdel "$USERNAME"
    fi
    log_msg "INFO" "User '${USERNAME}' removed."
}

main_menu() {
    while true; do
        print_banner "USER MANAGER MENU"
        echo "1) List System Users & Groups"
        echo "2) Add New User Account"
        echo "3) Delete User Account"
        echo "4) Backup Account Configs (/etc/passwd, /etc/group)"
        echo "5) Exit"
        read -rp "Select Option [1-5]: " CHOICE

        case "$CHOICE" in
            1) list_users ;;
            2) add_user ;;
            3) delete_user ;;
            4) backup_user_configs ;;
            5) log_msg "INFO" "Exiting User Manager."; exit 0 ;;
            *) log_msg "ERROR" "Invalid choice." ;;
        esac
    done
}

main_menu
