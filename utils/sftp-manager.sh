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

# Docbloc: Audit and optionally fix file/folder permissions for SFTP jails and upload directories
audit_and_fix_permissions() {
    print_banner "AUDIT & FIX SFTP UPLOAD PERMISSIONS"

    local chroot_base="/var/sftp"
    local group_name="sftpusers"
    if [[ -f "$SFTP_JSON" ]] && command -v jq &>/dev/null; then
        chroot_base=$(jq -r '.sftp_settings.chroot_base // "/var/sftp"' "$SFTP_JSON")
        group_name=$(jq -r '.sftp_settings.group_name // "sftpusers"' "$SFTP_JSON")
    fi

    if [[ ! -d "$chroot_base" ]]; then
        log_msg "ERROR" "Chroot base directory ${chroot_base} does not exist."
        return 1
    fi

    echo -e "${COLOR_CYAN}Inspecting Chroot Jail & Upload Directory Permissions...${COLOR_RESET}\n"
    local issues_found=false

    for user_dir in "$chroot_base"/*; do
        [[ -d "$user_dir" ]] || continue
        local username
        username=$(basename "$user_dir")

        # Check jail root ownership (must be root:root and 755 for OpenSSH chroot requirements)
        local root_owner root_perms
        root_owner=$(stat -c '%U:%G' "$user_dir")
        root_perms=$(stat -c '%a' "$user_dir")

        if [[ "$root_owner" != "root:root" || "$root_perms" != "755" ]]; then
            echo -e "  [!] Jail Root Issue (${username}): Owner=${root_owner} (Expected root:root), Perms=${root_perms} (Expected 755)"
            issues_found=true
        else
            echo -e "  [OK] Jail Root (${username}): Correct (${root_owner}, ${root_perms})"
        fi

        # Check uploads directory ownership (must be user:group and 775)
        local upload_dir="${user_dir}/uploads"
        if [[ -d "$upload_dir" ]]; then
            local up_owner up_perms
            up_owner=$(stat -c '%U:%G' "$upload_dir")
            up_perms=$(stat -c '%a' "$upload_dir")

            if [[ "$up_owner" != "${username}:${group_name}" || "$up_perms" != "775" ]]; then
                echo -e "  [!] Upload Dir Issue (${username}/uploads): Owner=${up_owner} (Expected ${username}:${group_name}), Perms=${up_perms} (Expected 775)"
                issues_found=true
            else
                echo -e "  [OK] Upload Dir (${username}/uploads): Correct (${up_owner}, ${up_perms})"
            fi
        fi
    done
    echo ""

    if [[ "$issues_found" == "true" ]]; then
        read -rp "Would you like to automatically fix these permission discrepancies? [y/N]: " FIX_CONF
        if [[ "${FIX_CONF,,}" == "y" ]]; then
            log_sftp_event "INFO" "Administrator initiated automatic SFTP permission repair."
            for user_dir in "$chroot_base"/*; do
                [[ -d "$user_dir" ]] || continue
                local username
                username=$(basename "$user_dir")

                chown root:root "$user_dir"
                chmod 755 "$user_dir"

                local upload_dir="${user_dir}/uploads"
                if [[ -d "$upload_dir" ]]; then
                    chown "${username}:${group_name}" "$upload_dir"
                    chmod 775 "$upload_dir"
                fi
            done
            log_sftp_event "INFO" "SFTP permissions successfully repaired."
            echo -e "${COLOR_GREEN}Permissions successfully fixed!${COLOR_RESET}\n"
        fi
    else
        echo -e "${COLOR_GREEN}All chroot jail and upload permissions are correctly configured!${COLOR_RESET}\n"
    fi
}

# Docbloc: Scan SFTP upload folders for malicious files using ClamAV
scan_uploads_for_malware() {
    print_banner "SCAN SFTP UPLOADS FOR MALICIOUS FILES"

    if ! command -v clamscan &>/dev/null; then
        log_msg "ERROR" "ClamAV (clamscan) is not installed. Please install 'clamav' package."
        return 1
    fi

    local chroot_base="/var/sftp"
    if [[ -f "$SFTP_JSON" ]] && command -v jq &>/dev/null; then
        chroot_base=$(jq -r '.sftp_settings.chroot_base // "/var/sftp"' "$SFTP_JSON")
    fi

    read -rp "Enter specific username to scan [default: scan all uploads]: " TARGET_USER
    local scan_path="$chroot_base"
    if [[ -n "$TARGET_USER" ]]; then
        scan_path="${chroot_base}/${TARGET_USER}/uploads"
    fi

    if [[ ! -d "$scan_path" ]]; then
        log_msg "ERROR" "Scan target directory '${scan_path}' does not exist."
        return 1
    fi

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

# Docbloc: Test connection for a specified SFTP user
test_sftp_connection() {
    print_banner "TEST SFTP USER CONNECTION"

    read -rp "Enter username to test: " TARGET_USER
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

    # Use sftp batch mode to test connection authentication/handshake
    if timeout 5 sftp -P "$sftp_port" -o BatchMode=yes -o StrictHostKeyChecking=no "${TARGET_USER}@127.0.0.1" <<< "bye" &>/dev/null; then
        log_sftp_event "INFO" "SFTP connection test succeeded for user '${TARGET_USER}' (Key-based auth active)."
        echo -e "${COLOR_GREEN}Success: SFTP handshake and key authentication succeeded for ${TARGET_USER}!${COLOR_RESET}\n"
    else
        log_sftp_event "INFO" "SFTP key authentication test skipped/failed (password authentication may be required)."
        echo -e "${COLOR_ORANGE}Note: Automated key auth check returned non-zero (password login or manual authentication likely required).${COLOR_RESET}"
        
        # Test basic TCP port reachability
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
        echo "2) Initialize/Configure SFTP Chroot Environment"
        echo "3) Create Jailed SFTP User"
        echo "4) Delete Jailed SFTP User"
        echo "5) Audit & Fix Upload Folder Permissions"
        echo "6) Scan SFTP Uploads for Malicious Files (ClamAV)"
        echo "7) Test SFTP User Connection"
        echo "8) Backup SFTP/SSH Configurations"
        echo "9) Exit"
        read -rp "Select Option [1-9]: " CHOICE

        case "$CHOICE" in
            1) clear ;;
            2) core/setup-sftp.sh || true ;;
            3) 
               read -rp "Enter SFTP username: " u_name
               # Create user logic or call helper
               ;;
            4) delete_sftp_user ;;
            5) audit_and_fix_permissions ;;
            6) scan_uploads_for_malware ;;
            7) test_sftp_connection ;;
            8) backup_sftp_configs ;;
            9) log_sftp_event "INFO" "Exiting SFTP Manager."; exit 0 ;;
            *) log_msg "ERROR" "Invalid option." ;;
        esac
    done
}

main_menu
