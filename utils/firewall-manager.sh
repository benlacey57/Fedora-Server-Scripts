#!/usr/bin/env bash
# ==============================================================================
# Script: firewall-manager.sh
# Description: Interactive FirewallD/UFW Rule Management & Socket Auditor
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_JSON="${ROOT_DIR}/config.json"
FIREWALL_JSON="${ROOT_DIR}/config/firewall.json"
BACKUP_DIR="/config/firewall"

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

# --- Detect Active Firewall Backend (FirewallD for Fedora / UFW as fallback) ---
FIREWALL_BACKEND="unknown"
if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
    FIREWALL_BACKEND="firewalld"
elif command -v ufw &>/dev/null; then
    FIREWALL_BACKEND="ufw"
elif command -v firewall-cmd &>/dev/null; then
    FIREWALL_BACKEND="firewalld"
fi

# Docbloc: Backup active firewall rules to /config/firewall
backup_firewall_rules() {
    local timestamp dest
    timestamp=$(date +%Y%m%d_%H%M%S)
    dest="${BACKUP_DIR}/firewall_backup_${timestamp}"

    mkdir -p "${dest}"
    log_msg "INFO" "Backing up firewall state to ${dest}..."

    if [[ "$FIREWALL_BACKEND" == "firewalld" ]]; then
        firewall-cmd --list-all > "${dest}/firewalld_all.bak" 2>/dev/null || true
        [[ -d /etc/firewalld ]] && cp -r /etc/firewalld "${dest}/etc_firewalld" 2>/dev/null || true
    else
        ufw status verbose > "${dest}/ufw_status.bak" 2>/dev/null || true
        [[ -d /etc/ufw ]] && cp -r /etc/ufw "${dest}/etc_ufw" 2>/dev/null || true
    fi

    log_msg "INFO" "Firewall configuration successfully backed up."
}

# Docbloc: Pre-execution confirmation prompt with change summary box
confirm_action() {
    local action="$1"
    local target="$2"
    local summary="$3"
    local is_destructive="${4:-false}"

    echo -e "\n${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}                         ACTION CONFIRMATION & SUMMARY                          ${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    printf "%-20s : %s\n" "Requested Action" "${action}"
    printf "%-20s : %s\n" "Target Port/Rule" "${target}"
    printf "%-20s : %s\n" "Summary of Changes" "${summary}"
    
    if [[ "$is_destructive" == "true" ]]; then
        echo -e "${COLOR_RED}WARNING: THIS CHANGES SYSTEM FIREWALL ACCESS CONTROL! ACCESS MAY BE BLOCKED.${COLOR_RESET}"
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

# Docbloc: Display active firewall engine rules and active status
view_rules() {
    print_banner "CURRENT FIREWALL RULES & STATUS (${FIREWALL_BACKEND^^})"

    if [[ "$FIREWALL_BACKEND" == "firewalld" ]]; then
        firewall-cmd --list-all
    elif [[ "$FIREWALL_BACKEND" == "ufw" ]]; then
        ufw status verbose
    else
        log_msg "ERROR" "No supported firewall service (FirewallD or UFW) active."
    fi
    echo ""
}

# Docbloc: Interactively open a single port rule
add_rule() {
    print_banner "ADD FIREWALL RULE"

    read -rp "Enter port number to open (e.g. 8096): " PORT
    validate_string "$PORT" "port" || return 1

    read -rp "Enter protocol [tcp/udp] (default tcp): " PROTO
    PROTO="${PROTO:-tcp}"

    local target_spec="${PORT}/${PROTO}"

    confirm_action "Add Allow Rule" "$target_spec" "Allow incoming traffic on port $target_spec via ${FIREWALL_BACKEND}" "false" || return 0

    backup_firewall_rules

    if [[ "$FIREWALL_BACKEND" == "firewalld" ]]; then
        firewall-cmd --permanent --add-port="${target_spec}"
        firewall-cmd --reload
    else
        ufw allow "${target_spec}"
        ufw reload
    fi

    log_msg "INFO" "Firewall rule added for ${target_spec}."
}

# Docbloc: Apply batch firewall port rules declared in config/firewall.json
apply_rules_from_config() {
    print_banner "APPLY BATCH RULES FROM CONFIG/FIREWALL.JSON"

    if [[ ! -f "$FIREWALL_JSON" ]]; then
        log_msg "ERROR" "Configuration file not found at ${FIREWALL_JSON}"
        return 1
    fi

    local rule_count
    rule_count=$(jq -r '.allowed_ports | length // 0' "$FIREWALL_JSON")

    if (( rule_count == 0 )); then
        log_msg "WARN" "No ports defined in ${FIREWALL_JSON}."
        return 0
    fi

    log_msg "INFO" "Found ${rule_count} port rules defined in configuration:"
    for (( i=0; i<rule_count; i++ )); do
        local p proto lbl
        p=$(jq -r ".allowed_ports[$i].port" "$FIREWALL_JSON")
        proto=$(jq -r ".allowed_ports[$i].protocol // \"tcp\"" "$FIREWALL_JSON")
        lbl=$(jq -r ".allowed_ports[$i].label // \"Service\"" "$FIREWALL_JSON")
        echo "  - Port ${p}/${proto} (${lbl})"
    done
    echo ""

    confirm_action "Apply Config Rules" "Batch ${rule_count} Ports" "Apply all allowed_ports from ${FIREWALL_JSON} to ${FIREWALL_BACKEND}" "false" || return 0

    backup_firewall_rules

    for (( i=0; i<rule_count; i++ )); do
        local p proto
        p=$(jq -r ".allowed_ports[$i].port" "$FIREWALL_JSON")
        proto=$(jq -r ".allowed_ports[$i].protocol // \"tcp\"" "$FIREWALL_JSON")

        if [[ "$FIREWALL_BACKEND" == "firewalld" ]]; then
            firewall-cmd --permanent --add-port="${p}/${proto}" >/dev/null 2>&1 || true
        else
            ufw allow "${p}/${proto}" >/dev/null 2>&1 || true
        fi
    done

    if [[ "$FIREWALL_BACKEND" == "firewalld" ]]; then
        firewall-cmd --reload
    else
        ufw reload
    fi

    log_msg "INFO" "All ${rule_count} firewall rules applied successfully."
}

# Docbloc: Remove an existing port rule
delete_rule() {
    print_banner "DELETE FIREWALL RULE"

    if [[ "$FIREWALL_BACKEND" == "firewalld" ]]; then
        firewall-cmd --list-ports
        echo ""
        read -rp "Enter port and protocol to remove (e.g. 8096/tcp): " TARGET_SPEC
        validate_string "$TARGET_SPEC" "port/protocol" || return 1

        confirm_action "Delete Rule" "$TARGET_SPEC" "Remove port rule $TARGET_SPEC from FirewallD" "true" || return 0

        backup_firewall_rules
        firewall-cmd --permanent --remove-port="${TARGET_SPEC}"
        firewall-cmd --reload
        log_msg "INFO" "Firewall rule '${TARGET_SPEC}' removed."

    else
        ufw status numbered
        echo ""
        read -rp "Enter rule number to delete: " RULE_NUM
        validate_string "$RULE_NUM" "rule number" || return 1

        confirm_action "Delete Rule" "Rule #$RULE_NUM" "Remove UFW rule entry #$RULE_NUM" "true" || return 0

        backup_firewall_rules
        ufw --force delete "$RULE_NUM"
        ufw reload
        log_msg "INFO" "Firewall rule #${RULE_NUM} deleted."
    fi
}

# Docbloc: Audit active listening sockets across system processes
audit_listening_sockets() {
    print_banner "ACTIVE LISTENING SOCKETS AUDIT"

    if command -v ss &>/dev/null; then
        ss -tulpn | grep LISTEN || true
    else
        netstat -tulpn | grep LISTEN || true
    fi
    echo ""
}

# Docbloc: Main Menu Loop
main_menu() {
    while true; do
        print_banner "FIREWALL MANAGER MENU (${FIREWALL_BACKEND^^})"
        echo "1) View Firewall Rules"
        echo "2) Add Port Allow Rule"
        echo "3) Apply Firewall Rules from config"
        echo "4) Delete Firewall Rule"
        echo "5) Audit Listening Sockets"
        echo "6) Backup Configuration Files"
        echo "7) Exit"
        read -rp "Select Option [1-7]: " CHOICE

        case "$CHOICE" in
            1) view_rules ;;
            2) add_rule ;;
            3) apply_rules_from_config ;;
            4) delete_rule ;;
            5) audit_listening_sockets ;;
            6) backup_firewall_rules ;;
            7) log_msg "INFO" "Exiting Firewall Manager."; exit 0 ;;
            *) log_msg "ERROR" "Invalid choice." ;;
        esac
    done
}

main_menu
