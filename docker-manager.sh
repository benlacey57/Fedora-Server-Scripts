#!/usr/bin/env bash
# ==============================================================================
# Script: docker-manager.sh
# Description: Docker Stack Lifecycle, Container Audit & Embedded Firewall Sync
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_JSON="${SCRIPT_DIR}/config.json"
BACKUP_DIR="/config/docker"

if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root
check_dependency "docker"

DOCKER_BASE="/var/local/server-configs/docker"
if [[ ! -d "$DOCKER_BASE" && -d "$HOME/docker" ]]; then
    DOCKER_BASE="$HOME/docker"
fi

# Docbloc: Trigger external firewall sync routine
sync_firewall_rules() {
    log_msg "INFO" "Triggering Firewall Port Synchronization..."
    if [[ -f "${SCRIPT_DIR}/firewall-manager.sh" ]]; then
        bash "${SCRIPT_DIR}/firewall-manager.sh"
    else
        log_msg "ERROR" "firewall-manager.sh missing in ${SCRIPT_DIR}."
    fi
}

# Docbloc: Backup Docker Compose configurations and appdata states to /config/docker
backup_docker_data() {
    local timestamp dest
    timestamp=$(date +%Y%m%d_%H%M%S)
    dest="${BACKUP_DIR}/docker_backup_${timestamp}"

    mkdir -p "${dest}"
    log_msg "INFO" "Backing up Docker configurations and compose stacks to ${dest}..."

    if [[ -d "$DOCKER_BASE" ]]; then
        cp -r "$DOCKER_BASE" "${dest}/compose_stacks"
    fi

    log_msg "INFO" "Docker backup completed at ${dest}."
}

# Docbloc: Display running containers, states, ports, and health checks
show_docker_overview() {
    print_banner "DOCKER CONTAINER OVERVIEW"

    if ! systemctl is-active --quiet docker; then
        log_msg "ERROR" "Docker daemon service is NOT running!"
        return 1
    fi

    echo -e "${COLOR_CYAN}Running Containers & Exposed Ports:${COLOR_RESET}"
    printf "%-22s %-20s %-15s %-30s\n" "Container Name" "Image" "Status" "Ports"
    echo "----------------------------------------------------------------------------------------------------"

    docker ps --format "{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" | while IFS=$'\t' read -r name img status ports; do
        printf "${COLOR_GREEN}%-22s${COLOR_RESET} %-20s %-15s %-30s\n" \
            "${name:0:21}" "${img:0:19}" "${status:0:14}" "${ports:0:29}"
    done

    echo -e "\n----------------------------------------------------------------------------------------------------"
    echo "                                  STOPPED / OFFLINE CONTAINERS"
    echo "----------------------------------------------------------------------------------------------------"
    docker ps -a --filter "status=exited" --format "{{.Names}}\t{{.Image}}\t{{.Status}}" | while IFS=$'\t' read -r name img status; do
        printf "${COLOR_RED}%-22s${COLOR_RESET} %-20s %-15s\n" "${name:0:21}" "${img:0:19}" "${status:0:14}"
    done
    echo ""
}

# Docbloc: Control Docker Stacks using Makefile or Docker Compose
manage_stacks() {
    print_banner "MANAGE DOCKER COMPOSE STACKS"
    log_msg "INFO" "Base compose directory: ${DOCKER_BASE}"

    if [[ -f "${DOCKER_BASE}/Makefile" ]]; then
        echo "1) Deploy All Stacks (make all)"
        echo "2) Stop All Stacks (make down)"
        echo "3) Check Stacks Status (make status)"
        read -rp "Select option [1-3]: " MAKE_OPT

        case "$MAKE_OPT" in
            1) make -C "$DOCKER_BASE" all && sync_firewall_rules ;;
            2) make -C "$DOCKER_BASE" down ;;
            3) make -C "$DOCKER_BASE" status ;;
            *) log_msg "ERROR" "Invalid option." ;;
        esac
    else
        echo "1) Start all compose stacks"
        echo "2) Stop all compose stacks"
        read -rp "Select option [1-2]: " COMP_OPT

        case "$COMP_OPT" in
            1)
                find "$DOCKER_BASE" -name "docker-compose.yml" -exec docker compose -f {} up -d \;
                sync_firewall_rules
                ;;
            2)
                find "$DOCKER_BASE" -name "docker-compose.yml" -exec docker compose -f {} down \;
                ;;
            *) log_msg "ERROR" "Invalid option." ;;
        esac
    fi
}

# Docbloc: Main Menu Loop
main_menu() {
    while true; do
        show_docker_overview
        print_banner "DOCKER MANAGER MENU"
        echo "1) Refresh Container Overview"
        echo "2) Manage Stacks (Start / Stop / Deploy)"
        echo "3) Sync Docker Ports with Firewall"
        echo "4) View Container Logs"
        echo "5) Prune Unused Docker Images & Cache"
        echo "6) Backup Docker Configurations"
        echo "7) Exit"
        read -rp "Select Option [1-7]: " CHOICE

        case "$CHOICE" in
            1) clear ;;
            2) manage_stacks ;;
            3) sync_firewall_rules ;;
            4)
                read -rp "Enter Container Name to view logs: " C_NAME
                docker logs --tail 100 -f "$C_NAME" || true
                ;;
            5)
                log_msg "INFO" "Pruning dangling images and build cache..."
                docker system prune -f
                ;;
            6) backup_docker_data ;;
            7) log_msg "INFO" "Exiting Docker Manager."; exit 0 ;;
            *) log_msg "ERROR" "Invalid selection." ;;
        esac
    done
}

main_menu