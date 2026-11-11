#!/usr/bin/env bash
# ==============================================================================
# Script: sftp-manager.sh
# Description: Secure Chrooted SFTP Jail & User Lifecycle Manager
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_JSON="${ROOT_DIR}/config.json"
SFTP_JSON="${ROOT_DIR}/config/sftp.json"
BACKUP_DIR="/config/sftp"

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

# Docbloc: Backup SFTP and SSH configuration drop-ins
backup_sftp_configs() {
    local timestamp dest
    timestamp=$(date +%Y%m%d_%H%M%S)
    dest="${BACKUP_DIR}/sftp_backup_${timestamp}"

    mkdir -p "${dest}"
    log_msg "INFO" "Backing up SFTP configurations to ${dest}..."
    [[ -f /etc/ssh/sshd_config ]] && cp /etc/ssh/sshd_config "${dest}/sshd_config.bak" 2>/dev/null || true
    [[ -d /etc/ssh/sshd_config.d ]] && cp -r /etc/ssh/sshd_config.d "${dest}/sshd_config.d.bak" 2>/dev/null || true
    [[ -f "$SFTP_JSON" ]] && cp "$SFTP_JSON" "${dest}/sftp.json.bak" 2>/dev/null || true
    log_msg "INFO" "SFTP configurations backed up successfully."
}

# Docbloc: Display confirmation prompt with change summary box
confirm_action() {
    local action="$1"
    local target="$2"
    local summary="$3"
    local is_destructive="${4:-false}"

    echo -e "\n${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}                         ACTION CONFIRMATION & SUMMARY                          ${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    printf "%-20s : %s\n" "Requested Action" "${action}"
    printf "%-20s : %s\n" "Target User/Path" "${target}"
    printf "%-20s : %s\n" "Summary of Changes" "${summary}"
    
    if [[ "$is_destructive" == "true" ]]; then
        echo -e "${COLOR_RED}WARNING: THIS MODIFIES SSH JAIL SECURITY OR REMOVES USER ACCOUNTS!${COLOR_RESET}"
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

# Docbloc: Display overview of current SFTP chroot base and jailed members
show_sftp_overview() {
    print_banner "SFTP JAILS & USERS OVERVIEW"

    local group_name="sftpusers"
    local chroot_base="/var/sftp"
    if [[ -f "$SFTP_JSON" ]] && command -v jq &>/dev/null; then
        group_name=$(jq -r '.sftp_settings.group_name // "sftpusers"' "$SFTP_JSON")
        chroot_base=$(jq -r '.sftp_settings.chroot_base // "/var/sftp"' "$SFTP_JSON")
    fi

    echo -e "SFTP Chroot Base Directory : ${COLOR_GREEN}${chroot_base}${COLOR_RESET}"
    echo -e "Enforced Chroot Group      : ${COLOR_GREEN}${group_name}${COLOR_RESET}"
    echo ""

    echo -e "${COLOR_CYAN}Jailed Members in Group '${group_name}':${COLOR_RESET}"
    if getent group "$group_name" &>/dev/null; then
        local members
        members=$(getent group "$group_name" | cut -d: -f4)
        if [[ -n "$members" ]]; then
            echo "  Members: ${members}"
        else
            echo "  No members assigned to this group yet."
        fi
    else
        echo "  Group '${group_name}' does not exist yet."
    fi
    echo ""
}

# Docbloc: Initialize chroot directories and configure sshd_config.d rules
setup_sftp_environment() {
    print_banner "INITIALIZE SFTP CHROOT ENVIRONMENT"

    local group_name="sftpusers"
    local chroot_base="/var/sftp"
    if [[ -f "$SFTP_JSON" ]] && command -v jq &>/dev/null; then
        group_name=$(jq -r '.sftp_settings.group_name // "sftpusers"' "$SFTP_JSON")
        chroot_base=$(jq -r '.sftp_settings.chroot_base // "/var/sftp"' "$SFTP_JSON")
    fi

    confirm_action "Initialize SFTP" "$chroot_base" "Create chroot root directory and setup SSH Match Group rules for '${group_name}'" "false" || return 0

    backup_sftp_configs

    groupadd --force "$group_name"
    mkdir -p "$chroot_base"
    chown root:root "$chroot_base"
    chmod 755 "$chroot_base"

    local drop_in="/etc/ssh/sshd_config.d/99-sftp-jails.conf"
    mkdir -p /etc/ssh/sshd_config.d

    cat <<EOF > "$drop_in"
# Managed by Homelab SFTP Manager
Subsystem sftp internal-sftp

Match Group ${group_name}
    ChrootDirectory ${chroot_base}/%u
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
EOF

    log_msg "INFO" "Validating sshd configuration syntax..."
    if sshd -t; then
        systemctl restart sshd 2>/dev/null || systemctl restart ssh
        log_msg "INFO" "SFTP chroot environment initialized successfully."
    else
        log_msg "ERROR" "Invalid sshd configuration syntax. Rolling back..."
        rm -f "$drop_in"
        return 1
    fi
}

# Docbloc: Create a jailed SFTP user with correct permissions
create_sftp_user() {
    print_banner "CREATE JAILED SFTP USER"

    read -rp "Enter new SFTP username: " TARGET_USER
    validate_string "$TARGET_USER" "username" || return 1

    if id "$TARGET_USER" &>/dev/null; then
        log_msg "ERROR" "User '${TARGET_USER}' already exists."
        return 1
    fi

    local group_name="sftpusers"
    local chroot_base="/var/sftp"
    if [[ -f "$SFTP_JSON" ]] && command -v jq &>/dev/null; then
        group_name=$(jq -r '.sftp_settings.group_name // "sftpusers"' "$SFTP_JSON")
        chroot_base=$(jq -r '.sftp_settings.chroot_base // "/var/sftp"' "$SFTP_JSON")
    fi

    confirm_action "Create SFTP User" "$TARGET_USER" "Create jailed user '$TARGET_USER' in group '$group_name' with home at '$chroot_base/$TARGET_USER'" "false" || return 0

    backup_sftp_configs

    # Ensure chroot group exists
    groupadd --force "$group_name"

    # Create user with nologin shell
    useradd -m -g "$group_name" -s /usr/sbin/nologin -d "${chroot_base}/${TARGET_USER}" "$TARGET_USER"
    
    log_msg "INFO" "Set password for user '${TARGET_USER}':"
    passwd "$TARGET_USER"

    # Setup correct chroot permissions (ChrootDirectory requires root ownership and 755)
    chown root:root "${chroot_base}/${TARGET_USER}"
    chmod 755 "${chroot_base}/${TARGET_USER}"

    # Create writable upload directory inside the jail
    local upload_dir="${chroot_base}/${TARGET_USER}/uploads"
    mkdir -p "$upload_dir"
    chown "${TARGET_USER}:${group_name}" "$upload_dir"
    chmod 775 "$upload_dir"

    log_msg "INFO" "Jailed SFTP user '${TARGET_USER}' created successfully."
    echo -e "  Jail Root  : ${chroot_base}/${TARGET_USER} (Owned by root:root, 755)"
    echo -e "  Upload Dir : ${upload_dir} (Owned by ${TARGET_USER}:${group_name}, 775)\n"
}

# Docbloc: Delete an existing SFTP user and optionally purge their home directory
delete_sftp_user() {
    print_banner "DELETE JAILED SFTP USER"
    show_sftp_overview

    read -rp "Enter username to delete: " TARGET_USER
    validate_string "$TARGET_USER" "username" || return 1

    if ! id "$TARGET_USER" &>/dev/null; then
        log_msg "ERROR" "User '${TARGET_USER}' does not exist."
        return 1
    fi

    local chroot_base="/var/sftp"
    if [[ -f "$SFTP_JSON" ]] && command -v jq &>/dev/null; then
        chroot_base=$(jq -r '.sftp_settings.chroot_base // "/var/sftp"' "$SFTP_JSON")
    fi

    confirm_action "Delete SFTP User" "$TARGET_USER" "Remove system user '$TARGET_USER' and optionally purge home directory" "true" || return 0

    read -rp "Purge home directory (${chroot_base}/${TARGET_USER})? [y/N]: " PURGE_HOME
    if [[ "${PURGE_HOME,,}" == "y" ]]; then
        userdel -r "$TARGET_USER"
        log_msg "INFO" "Deleted user '${TARGET_USER}' and purged home directory."
    else
        userdel "$TARGET_USER"
        log_msg "INFO" "Deleted user '${TARGET_USER}' (home directory retained)."
    fi
}

# Docbloc: Main Menu Loop
main_menu() {
    while true; do
        show_sftp_overview
        print_banner "SFTP MANAGER MENU"
        echo "1) Refresh Overview"
        echo "2) Configure SFTP Environment"
        echo "3) Create SFTP User"
        echo "4) Delete SFTP User"
        echo "5) Backup Configuration"
        echo "6) Exit"
        read -rp "Select Option [1-6]: " CHOICE

        case "$CHOICE" in
            1) clear ;;
            2) setup_sftp_environment ;;
            3) create_sftp_user ;;
            4) delete_sftp_user ;;
            5) backup_sftp_configs ;;
            6) log_msg "INFO" "Exiting SFTP Manager."; exit 0 ;;
            *) log_msg "ERROR" "Invalid option." ;;
        esac
    done
}

main_menu
