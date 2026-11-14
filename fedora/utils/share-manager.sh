#!/usr/bin/env bash
# ==============================================================================
# Script: share-admin.sh
# Description: Advanced Share Lifecycle Manager (Create, Edit, Delete & User Security)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_JSON="${ROOT_DIR}/config.json"
SHARES_JSON="${ROOT_DIR}/config/shares.json"
BACKUP_DIR="/config/shares"

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

# Docbloc: Backup active network share configuration files
backup_share_configs() {
    local timestamp dest
    timestamp=$(date +%Y%m%d_%H%M%S)
    dest="${BACKUP_DIR}/shares_admin_backup_${timestamp}"

    mkdir -p "${dest}"
    [[ -f /etc/exports ]] && cp /etc/exports "${dest}/exports.bak" 2>/dev/null || true
    [[ -f /etc/samba/smb.conf ]] && cp /etc/samba/smb.conf "${dest}/smb.conf.bak" 2>/dev/null || true
    [[ -f "$SHARES_JSON" ]] && cp "$SHARES_JSON" "${dest}/shares.json.bak" 2>/dev/null || true

    log_msg "INFO" "Share configurations backed up to ${dest}"
}

# Docbloc: Display pre-execution summary and prompt for user confirmation
confirm_action() {
    local action="$1"
    local target="$2"
    local summary="$3"
    local is_destructive="${4:-false}"

    echo -e "\n${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}                         ACTION CONFIRMATION & SUMMARY                          ${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    printf "%-20s : %s\n" "Requested Action" "${action}"
    printf "%-20s : %s\n" "Target Share/Path" "${target}"
    printf "%-20s : %s\n" "Summary of Changes" "${summary}"

    if [[ "$is_destructive" == "true" ]]; then
        echo -e "${COLOR_RED}WARNING: THIS MODIFIES OR REMOVES SHARE SECURITY AND ACCESS PERMISSIONS!${COLOR_RESET}"
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

# Docbloc: Display current shares configured in shares.json
list_managed_shares() {
    print_banner "MANAGED SHARES AUDIT"

    if [[ ! -f "$SHARES_JSON" ]]; then
        log_msg "WARN" "No shares.json found at ${SHARES_JSON}"
        return 0
    }

    echo -e "${COLOR_CYAN}NFS Exports Defined in config/shares.json:${COLOR_RESET}"
    jq -r '.nfs_exports[]? | "  - Path: \(.path) | Subnet: \(.allowed_subnet) | Restricted User: \(.restricted_user // "None")"' "$SHARES_JSON" 2>/dev/null || echo "  None configured."

    echo -e "\n${COLOR_CYAN}Samba Shares Defined in config/shares.json:${COLOR_RESET}"
    jq -r '.samba_shares[]? | "  - Name: \(.name) | Path: \(.path) | Read-Only: \(.read_only) | Valid Users: \(.valid_users // "None")"' "$SHARES_JSON" 2>/dev/null || echo "  None configured."
    echo ""
}

# Docbloc: Create and add a new share interactively
create_new_share() {
    print_banner "CREATE NEW NETWORK SHARE"

    read -rp "Enter local folder path to share (e.g. /mnt/storage/private/docs): " SHARE_PATH
    validate_string "$SHARE_PATH" "share path" || return 1

    mkdir -p "$SHARE_PATH"

    echo "Select Share Protocol:"
    echo "1) NFS (Read-Only or Read/Write)"
    echo "2) Samba (SMB)"
    echo "3) Both NFS & Samba"
    read -rp "Select Option [1-3]: " PROTO_CHOICE

    read -rp "Restrict access to a specific system user? (Leave blank for public/open): " RESTRICT_USER

    backup_share_configs

    # Initialize shares.json if missing
    if [[ ! -f "$SHARES_JSON" ]]; then
        echo '{"nfs_exports":[], "samba_shares":[]}' > "$SHARES_JSON"
    fi

    if [[ "$PROTO_CHOICE" == "1" || "$PROTO_CHOICE" == "3" ]]; then
        read -rp "Enter allowed subnet (e.g. 192.168.0.0/24): " SUB_NET
        SUB_NET="${SUB_NET:-192.168.0.0/24}"
        read -rp "Enter NFS options [default ro,sync,no_subtree_check,all_squash]: " NFS_OPTS
        NFS_OPTS="${NFS_OPTS:-ro,sync,no_subtree_check,all_squash}"

        # Use jq to append to nfs_exports array
        TEMP_JSON=$(jq --arg path "$SHARE_PATH" --arg subnet "$SUB_NET" --arg opts "$NFS_OPTS" --arg user "$RESTRICT_USER" \
            '.nfs_exports += [{"path": $path, "allowed_subnet": $subnet, "options": $opts, "restricted_user": $user}]' "$SHARES_JSON")
        echo "$TEMP_JSON" > "$SHARES_JSON"
        log_msg "INFO" "Added NFS export rule for ${SHARE_PATH}."
    fi

    if [[ "$PROTO_CHOICE" == "2" || "$PROTO_CHOICE" == "3" ]]; then
        read -rp "Enter Samba Share Name (e.g. PrivateDocs): " SMB_NAME
        validate_string "$SMB_NAME" "Samba share name" || return 1
        read -rp "Is this share Read-Only? [y/N]: " IS_RO
        
        local ro_bool="true"
        local guest_bool="true"
        [[ "${IS_RO,,}" == "y" ]] && ro_bool="false"
        [[ -n "$RESTRICT_USER" ]] && guest_bool="false"

        TEMP_JSON=$(jq --arg name "$SMB_NAME" --arg path "$SHARE_PATH" --argjson ro "$ro_bool" --argjson guest "$guest_bool" --arg user "$RESTRICT_USER" \
            '.samba_shares += [{"name": $name, "path": $path, "read_only": $ro, "guest_ok": $guest, "browseable": true, "valid_users": $user}]' "$SHARES_JSON")
        echo "$TEMP_JSON" > "$SHARES_JSON"
        log_msg "INFO" "Added Samba share [${SMB_NAME}]."
    fi

    log_msg "INFO" "New share created and added to configuration successfully."
}

# Docbloc: Delete an existing share from configuration and system exports
delete_share() {
    print_banner "DELETE NETWORK SHARE"
    list_managed_shares

    read -rp "Enter exact local share path or Samba share name to delete: " TARGET_ID
    validate_string "$TARGET_ID" "target identifier" || return 1

    confirm_action "Delete Share" "$TARGET_ID" "Remove share definition from config/shares.json and system exports" "true" || return 0

    backup_share_configs

    # Remove from config/shares.json using jq filtering
    TEMP_JSON=$(jq --arg target "$TARGET_ID" '.nfs_exports = [.nfs_exports[] | select(.path != $target)] | .samba_shares = [.samba_shares[] | select(.name != $target and .path != $target)]' "$SHARES_JSON")
    echo "$TEMP_JSON" > "$SHARES_JSON"

    # Clean /etc/exports and /etc/samba/smb.conf
    sed -i "\|$TARGET_ID|d" /etc/exports 2>/dev/null || true
    exportfs -arv 2>/dev/null || true

    log_msg "INFO" "Share '${TARGET_ID}' deleted successfully."
}

# Docbloc: Apply all definitions from config/shares.json to active system daemons
apply_all_shares() {
    print_banner "APPLY ALL SHARES & USER RESTRICTIONS TO SYSTEM"

    if [[ ! -f "$SHARES_JSON" ]]; then
        log_msg "ERROR" "Configuration file not found at ${SHARES_JSON}"
        return 1
    }

    confirm_action "Apply All Shares" "$SHARES_JSON" "Rebuild /etc/exports and /etc/samba/smb.conf from configuration data" "false" || return 0

    backup_share_configs

    # Reset /etc/exports header
    echo "# /etc/exports: NFS file share exports managed by share-admin.sh" > /etc/exports

    local nfs_count
    nfs_count=$(jq -r '.nfs_exports | length // 0' "$SHARES_JSON")
    for (( i=0; i<nfs_count; i++ )); do
        local p net opts user
        p=$(jq -r ".nfs_exports[$i].path" "$SHARES_JSON")
        net=$(jq -r ".nfs_exports[$i].allowed_subnet // \"192.168.0.0/24\"" "$SHARES_JSON")
        opts=$(jq -r ".nfs_exports[$i].options // \"ro,sync,no_subtree_check,all_squash\"" "$SHARES_JSON")
        
        mkdir -p "$p"
        echo "${p} ${net}(${opts})" >> /etc/exports
    done
    exportfs -arv 2>/dev/null || true

    # Rebuild Samba configuration blocks
    local smb_count
    smb_count=$(jq -r '.samba_shares | length // 0' "$SHARES_JSON")
    for (( i=0; i<smb_count; i++ )); do
        local name p ro guest browse user
        name=$(jq -r ".samba_shares[$i].name" "$SHARES_JSON")
        p=$(jq -r ".samba_shares[$i].path" "$SHARES_JSON")
        ro=$(jq -r ".samba_shares[$i].read_only // true" "$SHARES_JSON")
        guest=$(jq -r ".samba_shares[$i].guest_ok // true" "$SHARES_JSON")
        browse=$(jq -r ".samba_shares[$i].browseable // true" "$SHARES_JSON")
        user=$(jq -r ".samba_shares[$i].valid_users // \"\"" "$SHARES_JSON")

        mkdir -p "$p"
        local ro_str="yes"; [[ "$ro" == "false" ]] && ro_str="no"
        local guest_str="yes"; [[ "$guest" == "false" ]] && guest_str="no"
        local browse_str="yes"; [[ "$browse" == "false" ]] && browse_str="no"

        cat <<EOF >> /etc/samba/smb.conf

[${name}]
   path = ${p}
   read only = ${ro_str}
   guest ok = ${guest_str}
   browseable = ${browse_str}
EOF
        if [[ -n "$user" && "$user" != "null" ]]; then
            echo "   valid users = ${user}" >> /etc/samba/smb.conf
        fi
    done

    if systemctl is-active --quiet smb 2>/dev/null; then
        systemctl restart smb
    elif systemctl is-active --quiet smbd 2>/dev/null; then
        systemctl restart smbd
    fi

    log_msg "INFO" "All shares, user restrictions, and service daemons synchronized."
}

# Docbloc: Main Menu Loop
main_menu() {
    while true; do
        list_managed_shares
        print_banner "ADVANCED SHARE MANAGER MENU"
        echo "1) Refresh Audit Overview"
        echo "2) Create New Share"
        echo "3) Delete Share"
        echo "4) Apply Configuration"
        echo "5) Backup Configuration"
        echo "6) Exit"
        read -rp "Select Option [1-6]: " CHOICE

        case "$CHOICE" in
            1) clear ;;
            2) create_new_share ;;
            3) delete_share ;;
            4) apply_all_shares ;;
            5) backup_share_configs ;;
            6) log_msg "INFO" "Exiting Share Admin."; exit 0 ;;
            *) log_msg "ERROR" "Invalid option." ;;
        esac
    done
}

main_menu
