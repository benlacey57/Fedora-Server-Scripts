#!/usr/bin/env bash
# ==============================================================================
# Script: firewall-manager.sh
# Description: Modular Firewall Audit & Docker Exposed Port Sync Tool
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_JSON="${SCRIPT_DIR}/config.json"
BACKUP_DIR="/config/firewall"

if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root

# Detect active firewall backend
FW_BACKEND="none"
if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
    FW_BACKEND="firewalld"
elif command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    FW_BACKEND="ufw"
fi

# Docbloc: Backup active firewall rules to /config/firewall
backup_firewall_rules() {
    local timestamp dest
    timestamp=$(date +%Y%m%d_%H%M%S)
    dest="${BACKUP_DIR}/firewall_backup_${timestamp}"

    mkdir -p "${dest}"
    log_msg "INFO" "Backing up active firewall rules to ${dest}..."

    if [[ "$FW_BACKEND" == "firewalld" ]]; then
        firewall-cmd --runtime-to-permanent 2>/dev/null || true
        cp -r /etc/firewalld/ "${dest}/" 2>/dev/null || true
        firewall-cmd --list-all > "${dest}/firewalld_active_rules.txt"
    elif [[ "$FW_BACKEND" == "ufw" ]]; then
        cp -r /etc/ufw/ "${dest}/" 2>/dev/null || true
        ufw status verbose > "${dest}/ufw_active_rules.txt"
    else
        iptables-save > "${dest}/iptables_dump.txt" 2>/dev/null || true
    fi

    log_msg "INFO" "Firewall rules successfully backed up."
}

# Docbloc: Display active firewall status and exposed listening ports
show_firewall_overview() {
    print_banner "FIREWALL OVERVIEW & LISTENING PORTS (${FW_BACKEND^^})"

    if [[ "$FW_BACKEND" == "firewalld" ]]; then
        echo -e "${COLOR_CYAN}Active FirewallD Default Zone Rules:${COLOR_RESET}"
        firewall-cmd --list-all | sed 's/^/  /'
    elif [[ "$FW_BACKEND" == "ufw" ]]; then
        echo -e "${COLOR_CYAN}Active UFW Status:${COLOR_RESET}"
        ufw status verbose | sed 's/^/  /'
    else
        log_msg "WARN" "No active high-level firewall (FirewallD or UFW) detected."
    fi

    echo -e "\n${COLOR_CYAN}Active Host Listening Ports (TCP/UDP):${COLOR_RESET}"
    if command -v ss &>/dev/null; then
        ss -tulpn | grep LISTEN | sed 's/^/  /'
    fi
    echo ""
}

# Docbloc: Synchronize open firewall ports directly from Docker Compose files
sync_docker_firewall_ports() {
    print_banner "SYNC DOCKER COMPOSE PORTS TO FIREWALL"

    local compose_base
    compose_base=$(read_json_config "$CONFIG_JSON" '.system.docker_compose_dir // "/var/local/server-configs/docker"')

    if [[ ! -d "$compose_base" && -d "$HOME/docker" ]]; then
        compose_base="$HOME/docker"
    fi

    if [[ ! -d "$compose_base" ]]; then
        log_msg "ERROR" "Docker Compose directory '${compose_base}' does not exist."
        return 1
    fi

    backup_firewall_rules
    log_msg "INFO" "Scanning Compose files in '${compose_base}' for exposed ports..."

    # Extract exposed host ports using python or regex
    local ports_found
    ports_found=$(python3 - <<EOF 