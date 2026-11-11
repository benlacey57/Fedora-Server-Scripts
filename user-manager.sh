#!/usr/bin/env bash
# ==============================================================================
# Script: user-manager.sh
# Description: System User & Group Administration Suite with Password Management
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

# Docbloc: Backup user and group system configuration files
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

# Docbloc: Action confirmation prompt with change summary and destructive warnings
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
        echo -e "${COLOR_RED}WARNING: THIS DIRECTLY MODIFIES USER CREDENTIALS OR SYSTEM ACCOUNTS!${COLOR_RESET}"
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

# Docbloc: List users (UID >= 1000 and UID 0) and system groups
list_users() {
    print_banner "SYSTEM USERS & GROUPS AUDIT"
    echo "--- Standard & Administrative Accounts ---"
    awk -F: '($3 >= 1000 || $3 == 0) {print "User: " $1 " (UID: " $3 ") | Shell: " $7}' /etc/passwd
    echo ""
    echo "--- System Groups ---"
    cut -d: -f1 /etc/group | tr '\n' ', '
    echo -e "\n"
}

# Docbloc: Add a new system user
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

# Docbloc: Delete an existing system user account
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

# Docbloc: Helper to generate a random 16-character alphanumeric password
generate_random_password() {
    if command -v openssl &>/dev/null; then
        openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16
    else
        tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16
    fi
}

# Docbloc: Change password for a single specific user
change_single_password() {
    print_banner "CHANGE SINGLE USER PASSWORD"
    list_users
    read -rp "Enter username to update password: " USERNAME
    validate_string "$USERNAME" "username" || return 1

    if ! id "$USERNAME" &>/dev/null; then
        log_msg "ERROR" "User '${USERNAME}' does not exist."
        return 1
    fi

    confirm_action "Change User Password" "$USERNAME" "Update account authentication password for $USERNAME" "false" || return 0

    backup_user_configs
    passwd "$USERNAME"
    log_msg "INFO" "Password updated for user '${USERNAME}'."
}

# Docbloc: Batch change passwords for all standard system users and export to secure file
change_all_passwords() {
    print_banner "CHANGE ALL USER PASSWORDS (BATCH AUTO-GENERATE)"
    
    local target_users
    target_users=$(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1}' /etc/passwd)

    if [[ -z "$target_users" ]]; then
        log_msg "WARN" "No standard user accounts (UID >= 1000) found to update."
        return 0
    fi

    echo "Found standard accounts to update:"
    for u in $target_users; do
        echo "  - $u"
    done
    echo ""

    local timestamp output_file
    timestamp=$(date +%Y%m%d_%H%M%S)
    mkdir -p "${BACKUP_DIR}"
    output_file="${BACKUP_DIR}/passwords_${timestamp}.txt"

    confirm_action "Batch Password Reset" "All Standard Users" "Auto-generate new random passwords for all standard users and write report to $output_file" "true" || return 0

    backup_user_configs

    log_msg "INFO" "Generating new passwords..."
    
    {
        echo "================================================================================"
        echo "                     GENERATED USER CREDENTIALS REPORT                          "
        echo "                     Timestamp: $(date)                                         "
        echo "================================================================================"
        printf "%-25s : %s\n" "Username" "New Generated Password"
        echo "--------------------------------------------------------------------------------"
    } > "$output_file"

    chmod 600 "$output_file"

    for user in $target_users; do
        local new_pass
        new_pass=$(generate_random_password)
        
        echo "${user}:${new_pass}" | chpasswd
        printf "%-25s : %s\n" "$user" "$new_pass" >> "$output_file"
        log_msg "INFO" "Password updated for user '${user}'."
    done

    echo "================================================================================" >> "$output_file"

    log_msg "INFO" "All user passwords updated successfully."
    echo -e "${COLOR_GREEN}Credential export file saved to:${COLOR_RESET} ${output_file}"
    echo -e "${COLOR_ORANGE}Permissions set to 600. Keep this file secure!${COLOR_RESET}\n"
}

# Docbloc: Password Management Sub-Menu
password_menu() {
    while true; do
        print_banner "PASSWORD MANAGEMENT MENU"
        echo "1) Change Password for a Specific User"
        echo "2) Change Passwords for ALL Standard Users (Auto-generate & Save to File)"
        echo "3) Back to Main Menu"
        read -rp "Select Option [1-3]: " PASS_CHOICE

        case "$PASS_CHOICE" in
            1) change_single_password ;;
            2) change_all_passwords ;;
            3) return 0 ;;
            *) log_msg "ERROR" "Invalid option." ;;
        esac
    done
}

# Docbloc: Main Menu Loop
main_menu() {
    while true; do
        print_banner "USER MANAGER MENU"
        echo "1) List System Users & Groups"
        echo "2) Add New User Account"
        echo "3) Delete User Account"
        echo "4) Change Passwords"
        echo "5) Backup Account Configs (/etc/passwd, /etc/group)"
        echo "6) Exit"
        read -rp "Select Option [1-6]: " CHOICE

        case "$CHOICE" in
            1) list_users ;;
            2) add_user ;;
            3) delete_user ;;
            4) password_menu ;;
            5) backup_user_configs ;;
            6) log_msg "INFO" "Exiting User Manager."; exit 0 ;;
            *) log_msg "ERROR" "Invalid option." ;;
        esac
    done
}

main_menu
