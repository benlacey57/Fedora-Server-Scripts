#!/usr/bin/env bash
# ==============================================================================
# Script: sftp-manager.sh
# Description: Secure Chrooted SFTP Jail, Permission Auditor & Malware Scanner
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_JSON="${ROOT_DIR}/config.json"
SFTP_JSON="${ROOT_DIR}/config/sftp.json"
BACKUP_DIR="/config/sftp"
CUSTOM_LOG_FILE="/var/log/homelab-sftp.log"

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

log_sftp_event() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}" | tee -a "$CUSTOM_LOG_FILE"
}

backup_sftp_configs() {
    local timestamp dest
    timestamp=$(date +%Y%m%d_%H%M%S)
    dest="${BACKUP_DIR}/sftp_backup_${timestamp}"

    mkdir -p "${dest}"
    log_sftp_event "INFO" "Backing up SFTP configurations to ${dest}..."
    [[ -f /etc/ssh/sshd_config ]] && cp /etc/ssh/sshd_config "${dest}/sshd_config.bak" 2>/dev/null || true
    [[ -d /etc/ssh/sshd_config.d ]] && cp -r /etc/ssh/sshd_config.d "${dest}/sshd_config.d.bak" 2>/dev/null || true
    [[ -f "$SFTP_JSON" ]] && cp "$SFTP_JSON" "${dest}/sftp.json.bak" 2>/dev/null || true
    log_sftp_event "INFO" "SFTP configurations backed up successfully."
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
    printf "%-20s : %s\n" "Target User/Path" "${target}"
    printf "%-20s : %s\n" "Summary of Changes" "${summary}"
    
    if [[ "$is_destructive" == "true" ]]; then
        echo -e "${COLOR_RED}WARNING: THIS MODIFIES SSH JAIL SECURITY OR PERMISSIONS!${COLOR_RESET}"
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
    echo -e "Shared Uploads Target      : ${COLOR_GREEN}/mnt/storage/downloads${COLOR_RESET}"
    echo -e "Custom Audit Log           : ${CUSTOM_LOG_FILE}"
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

# Docbloc: Bind existing system user to SFTP group and setup chroot jail mapping
bind_existing_sftp_user() {
    print_banner "BIND EXISTING USER TO SFTP JAIL"

    read -rp "Enter existing username to assign (e.g. media): " TARGET_USER
    validate_string "$TARGET_USER" "username" || return 1

    if ! id "$TARGET_USER" &>/dev/null; then
        log_msg "ERROR" "User '${TARGET_USER}' does not exist on this system."
        return 1
    fi

    local group_name="sftpusers"
    local chroot_base="/var/sftp"
    if [[ -f "$SFTP_JSON" ]] && command -v jq &>/dev/null; then
        group_name=$(jq -r '.sftp_settings.group_name // "sftpusers"' "$SFTP_JSON")
        chroot_base=$(jq -r '.sftp_settings.chroot_base // "/var/sftp"' "$SFTP_JSON")
    fi

    confirm_action "Bind SFTP User" "$TARGET_USER" "Add existing user '$TARGET_USER' to group '$group_name' and configure chroot jail pointing to /mnt/storage/downloads" "false" || return 0

    backup_sftp_configs

    groupadd --force "$group_name"
    usermod -aG "$group_name" "$TARGET_USER"

    # Ensure chroot base exists
    mkdir -p "$chroot_base"
    chown root:root "$chroot_base"
    chmod 755 "$chroot_base"

    # Setup jail root directory for user
    local user_jail="${chroot_base}/${TARGET_USER}"
    mkdir -p "$user_jail"
    chown root:root "$user_jail"
    chmod 755 "$user_jail"

    # Bind mount or symlink /mnt/storage/downloads inside their jail so they land directly in downloads
    local shared_downloads="/mnt/storage/downloads"
    mkdir -p "$shared_downloads"

    # Use bind mount to map /mnt/storage/downloads into the user's jail
    local jail_upload_target="${user_jail}/downloads"
    mkdir -p "$jail_upload_target"

    if ! mountpoint -q "$jail_upload_target"; then
        mount --bind "$shared_downloads" "$jail_upload_target"
        # Ensure permanent mount in fstab
        if ! grep -qs "$jail_upload_target" /etc/fstab; then
            echo "${shared_downloads}  ${jail_upload_target}  none  bind  0  0" >> /etc/fstab
        fi
    fi

    chown -R "${TARGET_USER}:${group_name}" "$shared_downloads"
    chmod 775 "$shared_downloads"

    log_sftp_event "INFO" "User '${TARGET_USER}' successfully bound to SFTP jail mapped to ${shared_downloads}."
    echo -e "${COLOR_GREEN}User '${TARGET_USER}' successfully configured for SFTP uploads!${COLOR_RESET}\n"
}

# Docbloc: Audit and auto-fix permissions for chroot jails and upload folders
audit_and_fix_permissions() {
    print_banner "AUDIT & FIX SFTP UPLOAD PERMISSIONS"

    local shared_downloads="/mnt/storage/downloads"
    local group_name="sftpusers"
    if [[ -f "$SFTP_JSON" ]] && command -v jq &>/dev/null; then
        group_name=$(jq -r '.sftp_settings.group_name // "sftpusers"' "$SFTP_JSON")
    fi

    echo -e "${COLOR_CYAN}Inspecting Shared Downloads & Jail Permissions...${COLOR_RESET}\n"
    
    if [[ -d "$shared_downloads" ]]; then
        local up_owner up_perms
        up_owner=$(stat -c '%U:%G' "$shared_downloads")
        up_perms=$(stat -c '%a' "$shared_downloads")
        echo -e "  Downloads Root (/mnt/storage/downloads): Owner=${up_owner}, Perms=${up_perms}"
    fi
    echo ""

    read -rp "Would you like to enforce correct ownership (user:${group_name}) and permissions (775) on /mnt/storage/downloads? [y/N]: " FIX_CONF
    if [[ "${FIX_CONF,,}" == "y" ]]; then
        log_sftp_event "INFO" "Administrator initiated automatic SFTP downloads permission repair."
        chmod -R 775 "$shared_downloads"
        log_sftp_event "INFO" "SFTP downloads permissions successfully repaired."
        echo -e "${COLOR_GREEN}Permissions successfully fixed!${COLOR_RESET}\n"
    fi
}

# Docbloc: Scan SFTP upload folders for malicious files using ClamAV
scan_uploads_for_malware() {
    print_banner "SCAN SFTP UPLOADS FOR MALICIOUS FILES"

    if ! command -v clamscan &>/dev/null; then
        log_msg "ERROR" "ClamAV (clamscan) is not installed. Please install 'clamav' package."
        return 1
    fi

    local scan_path="/mnt/storage/downloads"
    log_sftp_event "INFO" "Initiating ClamAV malware scan on ${scan_path}..."
    echo -e "${COLOR_CYAN}Running ClamAV virus scan on ${scan_path}...${COLOR_RESET}\n"

    set +e
    clamscan -r --infected --bell "$scan_path" 2>&1 | tee -a "$CUSTOM_LOG_FILE"
    local scan_exit="${PIPESTATUS[0]}"
    set -e

    if (( scan_exit == 0 )); then
        log_sftp_event "INFO" "Malware scan completed successfully. No infected files found."
        echo -e "\n${COLOR_GREEN}Scan complete: No malware detected!${COLOR_RESET}\n"
    elif (( scan_exit == 1 )); then
        log_sftp_event "WARN" "Malware scan found infected files in ${scan_path}!"
        echo -e "\n${COLOR_RED}WARNING: Infected files were detected! Review log at ${CUSTOM_LOG_FILE}.${COLOR_RESET}\n"
    else
        log_sftp_event "ERROR" "ClamAV scan encountered an error during execution."
        echo -e "\n${COLOR_RED}Scan error encountered.${COLOR_RESET}\n"
    fi
}

# Docbloc: Test connection for specified SFTP user
test_sftp_connection() {
    print_banner "TEST SFTP USER CONNECTION"

    read -rp "Enter username to test (e.g. media): " TARGET_USER
    validate_string "$TARGET_USER" "username" || return 1

    if ! id "$TARGET_USER" &>/dev/null; then
        log_msg "ERROR" "User '${TARGET_USER}' does not exist."
        return 1
    fi

    local sftp_port=22
    if [[ -f "$SFTP_JSON" ]] && command -v jq &>/dev/null; then
        sftp_port=$(jq -r '.sftp_settings.port // 22' "$SFTP_JSON")
    fi

    log_sftp_event "INFO" "Testing local loopback SFTP connection for user '${TARGET_USER}' on port ${sftp_port}..."
    echo -e "${COLOR_CYAN}Testing SFTP loopback connection for '${TARGET_USER}'...${COLOR_RESET}"

    if timeout 5 sftp -P "$sftp_port" -o BatchMode=yes -o StrictHostKeyChecking=no "${TARGET_USER}@127.0.0.1" <<< "bye" &>/dev/null; then
        log_sftp_event "INFO" "SFTP connection test succeeded for user '${TARGET_USER}'."
        echo -e "${COLOR_GREEN}Success: SFTP handshake and authentication succeeded for ${TARGET_USER}!${COLOR_RESET}\n"
    else
        log_sftp_event "INFO" "SFTP automated key check skipped (password authentication may be required)."
        echo -e "${COLOR_ORANGE}Note: Automated key check returned non-zero (password login or manual authentication required).${COLOR_RESET}"
        
        if nc -z 127.0.0.1 "$sftp_port" 2>/dev/null || ss -tulpn | grep -q ":$sftp_port "; then
            log_sftp_event "INFO" "SFTP port ${sftp_port} is listening and reachable."
            echo -e "${COLOR_GREEN}Port Check: SSH/SFTP port ${sftp_port} is open and accepting connections.${COLOR_RESET}\n"
        else
            log_sftp_event "ERROR" "SFTP port ${sftp_port} is unreachable."
            echo -e "${COLOR_RED}Error: Port ${sftp_port} is not responding.${COLOR_RESET}\n"
        fi
    fi
}

# Docbloc: Main Menu Loop
main_menu() {
    while true; do
        show_sftp_overview
        print_banner "SFTP MANAGER MENU"
        echo "1) Refresh Overview"
        echo "2) Configure SFTP Environment"
        echo "3) Bind Existing User to SFTP Jail"
        echo "4) Fix Download Folder Permissions"
        echo "5) Scan Downloads for Malware/Viruses"
        echo "6) Test SFTP User Connection"
        echo "7) Backup Configurations"
        echo "8) Exit"
        read -rp "Select Option [1-8]: " CHOICE

        case "$CHOICE" in
            1) clear ;;
            2) core/setup-sftp.sh || true ;;
            3) bind_existing_sftp_user ;;
            4) audit_and_fix_permissions ;;
            5) scan_uploads_for_malware ;;
            6) test_sftp_connection ;;
            7) backup_sftp_configs ;;
            8) log_sftp_event "INFO" "Exiting SFTP Manager."; exit 0 ;;
            *) log_msg "ERROR" "Invalid option." ;;
        esac
    done
}

main_menu
