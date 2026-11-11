#!/usr/bin/env bash
# ==============================================================================
# Script: docker-manager.sh
# Description: Docker Stack, Container Inspection, Log Audit & Lifecycle Manager
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_JSON="${SCRIPT_DIR}/../config.json"
BACKUP_DIR="/config/docker"
COMPOSE_FILE_PATH="docker-compose.yml"

if [[ -f "${SCRIPT_DIR}/../lib.sh" ]]; then
    source "${SCRIPT_DIR}/../lib.sh"
elif [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root
check_dependency "docker"

confirm_action() {
    local action="$1"
    local target="$2"
    local summary="$3"
    local is_destructive="${4:-false}"

    echo -e "\n${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}                         ACTION CONFIRMATION & SUMMARY                          ${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    printf "%-20s : %s\n" "Requested Action" "${action}"
    printf "%-20s : %s\n" "Target Container/Stack" "${target}"
    printf "%-20s : %s\n" "Summary of Changes" "${summary}"
    
    if [[ "$is_destructive" == "true" ]]; then
        echo -e "${COLOR_RED}WARNING: THIS IS A DESTRUCTIVE CONTAINER OPERATION! DATA OR RUNTIME STATE MAY BE ALTERED.${COLOR_RESET}"
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

backup_docker_configs() {
    local timestamp dest
    timestamp=$(date +%Y%m%d_%H%M%S)
    dest="${BACKUP_DIR}/docker_backup_${timestamp}"

    mkdir -p "${dest}"
    if [[ -f "$COMPOSE_FILE_PATH" ]]; then
        cp "$COMPOSE_FILE_PATH" "${dest}/docker-compose.yml.bak"
        log_msg "INFO" "Docker Compose file backed up to ${dest}"
    fi
}

list_containers() {
    print_banner "DOCKER CONTAINER OVERVIEW"
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}"
    echo ""
}

show_error_containers() {
    print_banner "UNHEALTHY OR EXITED CONTAINERS"
    docker ps -a --filter "status=exited" --filter "status=dead" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
    echo ""
}

view_container_logs() {
    print_banner "CONTAINER LOG AUDIT"
    list_containers
    read -rp "Enter container name to inspect logs: " C_NAME
    validate_string "$C_NAME" "container name" || return 1

    log_msg "INFO" "Displaying last 50 log lines for ${C_NAME}..."
    docker logs --tail 50 -f "$C_NAME"
}

stop_container() {
    print_banner "STOP DOCKER CONTAINER"
    list_containers
    read -rp "Enter container name to stop: " C_NAME
    validate_string "$C_NAME" "container name" || return 1

    confirm_action "Stop Container" "$C_NAME" "Gracefully stop execution of container $C_NAME" "false" || return 0

    log_msg "INFO" "Stopping container ${C_NAME}..."
    docker stop "$C_NAME"
    log_msg "INFO" "Container ${C_NAME} stopped."
}

restart_container() {
    print_banner "RESTART DOCKER CONTAINER"
    list_containers
    read -rp "Enter container name to restart: " C_NAME
    validate_string "$C_NAME" "container name" || return 1

    confirm_action "Restart Container" "$C_NAME" "Restart container runtime process for $C_NAME" "false" || return 0

    log_msg "INFO" "Restarting container ${C_NAME}..."
    docker restart "$C_NAME"
    log_msg "INFO" "Container ${C_NAME} restarted."
}

rebuild_container() {
    print_banner "REBUILD / UPDATE CONTAINER"
    list_containers
    read -rp "Enter container/service name to rebuild: " C_NAME
    validate_string "$C_NAME" "container name" || return 1

    confirm_action "Rebuild Container" "$C_NAME" "Pull latest image and recreate container instance for $C_NAME" "true" || return 0

    backup_docker_configs

    if [[ -f "$COMPOSE_FILE_PATH" ]]; then
        log_msg "INFO" "Pulling latest image and recreating service via Docker Compose..."
        docker compose pull "$C_NAME" || docker-compose pull "$C_NAME"
        docker compose up -d --force-recreate "$C_NAME" || docker-compose up -d --force-recreate "$C_NAME"
    else
        log_msg "WARN" "No docker-compose.yml found. Recreating container via standard image pull..."
        local image_name
        image_name=$(docker inspect --format='{{.Config.Image}}' "$C_NAME")
        docker pull "$image_name"
        docker stop "$C_NAME"
        docker rm "$C_NAME"
        log_msg "INFO" "Container ${C_NAME} removed. Please restart using your deployment setup."
    fi
    log_msg "INFO" "Rebuild operation completed for ${C_NAME}."
}

prune_system() {
    print_banner "PRUNE DOCKER SYSTEM & CACHE"
    confirm_action "Docker System Prune" "System-wide Docker Engine" "Remove unused containers, networks, dangling images, and build cache" "true" || return 0

    log_msg "INFO" "Pruning system resources..."
    docker system prune -f --volumes
    log_msg "INFO" "Docker system prune complete."
}

main_menu() {
    while true; do
        print_banner "DOCKER MANAGER MENU"
        echo "1) List All Containers (Status & Ports)"
        echo "2) Show Unhealthy / Exited Containers"
        echo "3) View Container Logs"
        echo "4) Stop Container"
        echo "5) Restart Container"
        echo "6) Rebuild / Update Container"
        echo "7) Prune Unused Docker System Resources"
        echo "8) Exit"
        read -rp "Select Option [1-8]: " CHOICE

        case "$CHOICE" in
            1) list_containers ;;
            2) show_error_containers ;;
            3) view_container_logs ;;
            4) stop_container ;;
            5) restart_container ;;
            6) rebuild_container ;;
            7) prune_system ;;
            8) log_msg "INFO" "Exiting Docker Manager."; exit 0 ;;
            *) log_msg "ERROR" "Invalid choice." ;;
        esac
    done
}

main_menu
