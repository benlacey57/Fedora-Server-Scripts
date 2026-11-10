#!/usr/bin/env bash
# ==============================================================================
# Script: ssh-manager.sh
# Description: Interactive SSH Key Lifecycle & Backup Management Tool
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_JSON="${SCRIPT_DIR}/config.json"
KEY_BACKUP_DIR="/config/ssh/user_keys_backups"

if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root
check_dependency "ssh-keygen"

# Docbloc: Prompt user creation flow if user does not exist
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

    read -rp "Enter groups (e.g., wheel,docker,sudo): " CUSTOM_GROUPS

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

# Docbloc: Generate new SSH key pair with overwrite and custom filename prompts
generate_ssh_key() {
    print_banner "GENERATE SSH KEY"
    read -rp "Enter username: " TARGET_USER
    validate_string "$TARGET_USER" "username" || return 1

    if ! id "$TARGET_USER" &>/dev/null; then
        create_new_user_prompt "$TARGET_USER" || return 1
    fi

    local target_home
    target_home=$(eval echo "~${TARGET_USER}")
    local ssh_dir="${target_home}/.ssh"
    mkdir -p "$ssh_dir"

    local default_key="${ssh_dir}/id_ed25519"
    local final_key="$default_key"

    if [[ -f "$default_key" ]]; then
        log_msg "WARN" "Key already exists at ${default_key}"
        read -rp "Overwrite existing key? [y/N]: " OVERWRITE_CHOICE
        if [[ "${OVERWRITE_CHOICE,,}" != "y" ]]; then
            read -rp "Enter filename [default: id_ed25519_custom]: " CUSTOM_FILENAME
            CUSTOM_FILENAME="${CUSTOM_FILENAME:-id_ed25519_custom}"

            if [[ "$CUSTOM_FILENAME" =~ ^/ ]]; then
                final_key="$CUSTOM_FILENAME"
            else
                final_key="${ssh_dir}/${CUSTOM_FILENAME}"
            fi
        fi
    fi

    log_msg "INFO" "Generating Ed25519 key at '${final_key}'..."
    ssh-keygen -t ed25519 -N "" -f "$final_key" -C "${TARGET_USER}@$(hostname)"

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
    print_banner "LIST USER KEYS"
    read -rp "Enter username: " TARGET_USER
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
    print_banner "DELETE USER KEYS"
    read -rp "Enter username: " TARGET_USER
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

    case "$DEL_CHOICE" in
        1)
            ls -la "$ssh_dir"
            read -rp "Enter key filename to remove (e.g. id_ed25519): " KEY_NAME
            local target_file="${ssh_dir}/${KEY_NAME}"
            if [[ -f "$target_file" ]]; then
                rm -f "$target_file" "${target_file}.pub"
                log_msg "INFO" "Deleted key '${target_file}' and matching public key."
            else
                log_msg "ERROR" "File '${target_file}' not found."
            fi
            ;;
        2)
            local auth_keys="${ssh_dir}/authorized_keys"
            if [[ -f "$auth_keys" ]]; then
                cat -n "$auth_keys"
                read -rp "Enter line number to remove: " LINE_NUM
                if [[ "$LINE_NUM" =~ ^[0-9]+$ ]]; then
                    sed -i "${LINE_NUM}d" "$auth_keys"
                    log_msg "INFO" "Removed line ${LINE_NUM} from ${auth_keys}."
                fi
            fi
            ;;
        3)
            read -rp "Purge all SSH keys for '${TARGET_USER}'? [y/N]: " PURGE_CONF
            if [[ "${PURGE_CONF,,}" == "y" ]]; then
                rm -rf "$ssh_dir"
                log_msg "INFO" "Purged ${ssh_dir}."
            fi
            ;;
        *) log_msg "ERROR" "Invalid option." ;;
    esac
}

# Docbloc: Backup SSH keys for all system users to /config/ssh/user_keys_backups/
backup_all_keys() {
    print_banner "BACKUP ALL SSH KEYS"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local dest="${KEY_BACKUP_DIR}/keys_backup_${timestamp}"

    mkdir -p "${dest}"

    while IFS=: read -r username _ uid _ _ home shell; do
        if (( uid >= 1000 || uid == 0 )) && [[ -d "${home}/.ssh" ]]; then
            log_msg "INFO" "Backing up keys for '${username}'..."
            mkdir -p "${dest}/${username}"
            cp -r "${home}/.ssh" "${dest}/${username}/" 2>/dev/null || true
        fi
    done < /etc/passwd

    chmod -R 600 "${dest}"
    log_msg "INFO" "All user SSH keys backed up to ${dest}"
}

# Docbloc: Simplified Main Menu Loop
main_menu() {
    while true; do
        print_banner "SSH KEY MANAGER"
        echo "1) Generate Key"
        echo "2) List Keys"
        echo "3) Delete Keys"
        echo "4) Backup Keys"
        echo "5) Exit"
        read -rp "Select Option [1-5]: " CHOICE

        case "$CHOICE" in
            1) generate_ssh_key ;;
            2) list_user_keys ;;
            3) delete_user_keys ;;
            4) backup_all_keys ;;
            5) log_msg "INFO" "Exiting SSH Key Manager."; exit 0 ;;
            *) log_msg "ERROR" "Invalid option." ;;
        esac
    done
}

main_menu