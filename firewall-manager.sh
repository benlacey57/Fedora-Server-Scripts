#!/usr/bin/env bash
# ==============================================================================
# Script: firewall-manager.sh
# Description: Interactive UFW Firewall Rule Management & Socket Auditor
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_JSON="${SCRIPT_DIR}/../config.json"
BACKUP_DIR="/config/firewall"

if [[ -f "${SCRIPT_DIR}/../lib.sh" ]]; then
    source "${SCRIPT_DIR}/../lib.sh"
elif [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root
check_dependency "ufw"

backup_firewall_rules() {
    local timestamp dest
    timestamp=$(date +%Y%m%d_%H%M%S)
    dest="${BACKUP_DIR}/firewall_backup_${timestamp}"

    mkdir -p "${dest}"
    ufw status verbose > "${dest}/ufw_status.bak"
    [[ -d /etc/ufw ]] && cp -r /etc/ufw "${dest}/etc_ufw_dir" 2>/dev/null || true

    log_msg "INFO" "Firewall configuration backed up to ${dest}"
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

view_rules() {
    print_banner "CURRENT FIREWALL RULES & STATUS"
    ufw status verbose
    echo ""
}

add_rule() {
    print_banner "ADD FIREWALL RULE"
    read -rp "Enter port number to open (e.g. 8096): " PORT
    validate_string "$PORT" "port" || return 1

    read -rp "Enter protocol [tcp/udp] (leave blank for both): " PROTO

    local target_spec="$PORT"
    [[ -n "$PROTO" ]] && target_spec="${PORT}/${PROTO}"

    confirm_action "Add Allow Rule" "$target_spec" "Allow incoming traffic on port $target_spec" "false" || return 0

    backup_firewall_rules
    if [[ -n "$PROTO" ]]; then
        ufw allow "$PORT/$PROTO"
    else
        ufw allow "$PORT"
    fi
    ufw reload
    log_msg "INFO" "Firewall rule added for ${target_spec}."
}

delete_rule() {
    print_banner "DELETE FIREWALL RULE"
    ufw status numbered
    echo ""
    read -rp "Enter rule number to delete: " RULE_NUM
    validate_string "$RULE_NUM" "rule number" || return 1

    confirm_action "Delete Rule" "Rule #$RULE_NUM" "Remove UFW rule entry #$RULE_NUM" "true" || return 0

    backup_firewall_rules
    ufw --force delete "$RULE_NUM"
    ufw reload
    log_msg "INFO" "Firewall rule #${RULE_NUM} deleted."
}

audit_listening_sockets() {
    print_banner "ACTIVE LISTENING SOCKETS AUDIT"
    if command -v ss &>/dev/null; then
        ss -tulpn | grep LISTEN || true
    else
        netstat -tulpn | grep LISTEN || true
    fi
    echo ""
}

main_menu() {
    while true; do
        print_banner "FIREWALL MANAGER MENU"
        echo "1) View Firewall Rules & Status"
        echo "2) Add Port Allow Rule"
        echo "3) Delete Firewall Rule by Number"
        echo "4) Audit Active Listening Sockets"
        echo "5) Backup Firewall Rules"
        echo "6) Exit"
        read -rp "Select Option [1-6]: " CHOICE

        case "$CHOICE" in
            1) view_rules ;;
            2) add_rule ;;
            3) delete_rule ;;
            4) audit_listening_sockets ;;
            5) backup_firewall_rules ;;
            6) log_msg "INFO" "Exiting Firewall Manager."; exit 0 ;;
            *) log_msg "ERROR" "Invalid choice." ;;
        esac
    done
}

main_menu
