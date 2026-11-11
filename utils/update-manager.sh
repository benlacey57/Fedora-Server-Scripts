#!/usr/bin/env bash
# ==============================================================================
# Script: update-manager.sh
# Description: DNF System Update Manager, Status Inspector & Log Viewer
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_JSON="${ROOT_DIR}/config.json"
UPDATES_JSON="${ROOT_DIR}/config/updates.json"
CUSTOM_LOG_FILE="/var/log/homelab-updates.log"

if [[ -f "${ROOT_DIR}/lib.sh" ]]; then
    source "${ROOT_DIR}/lib.sh"
elif [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root
check_dependency "dnf"
check_dependency "jq"

mkdir -p "$(dirname "$CUSTOM_LOG_FILE")"

log_update_event() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}" | tee -a "$CUSTOM_LOG_FILE"
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
    printf "%-20s : %s\n" "Target" "${target}"
    printf "%-20s : %s\n" "Summary of Changes" "${summary}"
    
    if [[ "$is_destructive" == "true" ]]; then
        echo -e "${COLOR_RED}WARNING: THIS MODIFIES SYSTEM PACKAGES OR CORE OS COMPONENTS!${COLOR_RESET}"
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

# Docbloc: Display system update overview and pending upgrades
show_updates_overview() {
    print_banner "SYSTEM UPDATES & REPOSITORY STATUS"

    echo -e "${COLOR_CYAN}Checking for available package upgrades...${COLOR_RESET}"
    dnf check-update --quiet || true
    echo ""

    # Check timer status
    local timer_status="inactive"
    if systemctl is-active --quiet dnf-automatic.timer 2>/dev/null; then
        timer_status="active (dnf-automatic)"
    elif systemctl is-active --quiet dnf5-automatic.timer 2>/dev/null; then
        timer_status="active (dnf5-automatic)"
    fi

    echo -e "Automatic Update Timer : ${COLOR_GREEN}${timer_status}${COLOR_RESET}"
    echo -e "Custom Log Destination : ${CUSTOM_LOG_FILE}"
    echo ""
}

# Docbloc: Execute manual system upgrade
run_manual_upgrade() {
    print_banner "EXECUTE SYSTEM UPGRADE"
    
    confirm_action "System Upgrade" "All Repositories" "Run 'dnf upgrade -y' to apply all available system package upgrades" "false" || return 0

    log_update_event "INFO" "Manual system upgrade initiated by administrator."
    dnf upgrade -y 2>&1 | tee -a "$CUSTOM_LOG_FILE"
    log_update_event "INFO" "Manual system upgrade completed."
}

# Docbloc: Configure and enable scheduled automatic updates
configure_automatic_updates() {
    print_banner "CONFIGURE AUTOMATIC UPDATES SCHEDULE"

    if ! rpm -q dnf-automatic &>/dev/null && ! rpm -q dnf5-plugin-automatic &>/dev/null; then
        log_msg "INFO" "Installing DNF automatic package..."
        if dnf install -y dnf5-plugin-automatic 2>/dev/null || dnf install -y dnf-automatic; then
            log_msg "INFO" "Automatic update package installed successfully."
        else
            log_msg "ERROR" "Failed to install dnf-automatic package."
            return 1
        fi
    fi

    confirm_action "Enable Automatic Updates" "Systemd Timer" "Configure background update timer based on config/updates.json" "false" || return 0

    local auto_conf="/etc/dnf/automatic.conf"
    if [[ -f "$auto_conf" ]]; then
        sed -i 's/^apply_updates.*/apply_updates = yes/' "$auto_conf"
    fi

    # Enable systemd timer
    if systemctl list-unit-files | grep -q "dnf5-automatic.timer"; then
        systemctl enable --now dnf5-automatic.timer
    else
        systemctl enable --now dnf-automatic.timer
    fi

    log_update_event "INFO" "Automatic system updates schedule enabled successfully."
}

# Docbloc: View recent custom update logs
view_update_logs() {
    print_banner "RECENT UPDATE LOGS"
    if [[ -f "$CUSTOM_LOG_FILE" ]]; then
        tail -n 50 "$CUSTOM_LOG_FILE"
    else
        echo "No update logs found at ${CUSTOM_LOG_FILE}."
    fi
    echo ""
}

# Docbloc: Main Menu Loop
main_menu() {
    while true; do
        show_updates_overview
        print_banner "UPDATE MANAGER MENU"
        echo "1) Refresh Overview"
        echo "2) Run System Updates"
        echo "3) Configure Automatic Updates"
        echo "4) View Update Logs"
        echo "5) Exit"
        read -rp "Select Option [1-5]: " CHOICE

        case "$CHOICE" in
            1) clear ;;
            2) run_manual_upgrade ;;
            3) configure_automatic_updates ;;
            4) view_update_logs ;;
            5) log_msg "INFO" "Exiting Update Manager."; exit 0 ;;
            *) log_msg "ERROR" "Invalid option." ;;
        esac
    done
}

main_menu
