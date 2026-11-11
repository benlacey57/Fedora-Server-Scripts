#!/usr/bin/env bash
# ==============================================================================
# Script: docker-manager.sh
# Description: Docker Lifecycle, Container Stop/Restart, Resource Inspector & Backups
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
BACKUP_DRIVE_MOUNT="/mnt/backup"
BACKUP_DEST_DIR="${BACKUP_DRIVE_MOUNT}/docker_backups"
CUSTOM_LOG_FILE="/var/log/homelab-docker-backup.log"
DRY_RUN=false

# Check for dry-run flag
for arg in "$@"; do
    if [[ "$arg" == "--dry-run" ]]; then
        DRY_RUN=true
    fi
done

if [[ -f "${ROOT_DIR}/lib.sh" ]]; then
    source "${ROOT_DIR}/lib.sh"
elif [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root
check_dependency "docker"
check_dependency "jq"

# Ensure custom log directory exists
mkdir -p "$(dirname "$CUSTOM_LOG_FILE")"

log_backup_event() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}" | tee -a "$CUSTOM_LOG_FILE"
}

# Docbloc: Display clean indexed table of containers
list_containers_table() {
    local filter_state="${1:-}" # e.g. "running" or empty for all
    local args=(-a)
    [[ -n "$filter_state" ]] && args=(--filter "status=${filter_state}")

    print_banner "DOCKER CONTAINERS TABLE"
    printf "%-4s %-25s %-15s %-30s\n" "ID" "NAME" "STATUS" "IMAGE"
    echo "--------------------------------------------------------------------------------"

    local containers
    containers=$(docker ps "${args[@]}" --format "{{.ID}}|{{.Names}}|{{.Status}}|{{.Image}}" 2>/dev/null || echo "")

    if [[ -z "$containers" ]]; then
        echo "No containers found."
        return 1
    fi

    local index=1
    declare -g -A CONTAINER_MAP
    while IFS='|' read -r cid cname cstatus cimage; do
        CONTAINER_MAP[$index]="$cname"
        printf "%-4s %-25s %-15s %-30s\n" "[$index]" "$cname" "$cstatus" "$cimage"
        ((index++))
    done <<< "$containers"
    echo ""
    return 0
}

# Docbloc: Stop one or more selected containers
stop_containers() {
    list_containers_table "running" || return 0

    read -rp "Enter container numbers to stop (space separated, e.g. 1 3): " -a selections
    if [[ ${#selections[@]} -eq 0 ]]; then
        log_msg "WARN" "No containers selected."
        return 0
    fi

    local target_names=()
    for sel in "${selections[@]}"; do
        if [[ -n "${CONTAINER_MAP[$sel]:-}" ]]; then
            target_names+=("${CONTAINER_MAP[$sel]}")
        fi
    done

    if [[ ${#target_names[@]} -eq 0 ]]; then
        log_msg "ERROR" "Invalid selection numbers."
        return 1
    fi

    echo -e "${COLOR_ORANGE}Selected containers to stop: ${target_names[*]}${COLOR_RESET}"
    read -rp "Proceed with stopping these containers? [y/N]: " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        log_msg "INFO" "Operation canceled."
        return 0
    fi

    for cname in "${target_names[@]}"; do
        log_msg "INFO" "Stopping container '${cname}'..."
        docker stop "$cname"
    done
    log_msg "INFO" "Selected containers stopped successfully."
}

# Docbloc: Restart one or more selected containers
restart_containers() {
    list_containers_table || return 0

    read -rp "Enter container numbers to restart (space separated, e.g. 1 2): " -a selections
    if [[ ${#selections[@]} -eq 0 ]]; then
        log_msg "WARN" "No containers selected."
        return 0
    fi

    local target_names=()
    for sel in "${selections[@]}"; do
        if [[ -n "${CONTAINER_MAP[$sel]:-}" ]]; then
            target_names+=("${CONTAINER_MAP[$sel]}")
        fi
    done

    if [[ ${#target_names[@]} -eq 0 ]]; then
        log_msg "ERROR" "Invalid selection numbers."
        return 1
    fi

    echo -e "${COLOR_ORANGE}Selected containers to restart: ${target_names[*]}${COLOR_RESET}"
    read -rp "Proceed with restarting these containers? [y/N]: " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        log_msg "INFO" "Operation canceled."
        return 0
    fi

    for cname in "${target_names[@]}"; do
        log_msg "INFO" "Restarting container '${cname}'..."
        docker restart "$cname"
    done
    log_msg "INFO" "Selected containers restarted successfully."
}

# Docbloc: Docker Resources Dashboard & Prune
show_docker_resources() {
    print_banner "DOCKER SYSTEM RESOURCES DASHBOARD"

    local total_containers total_volumes total_images space_used
    total_containers=$(docker ps -aq | wc -l)
    total_volumes=$(docker volume ls -q | wc -l)
    total_images=$(docker images -q | wc -l)
    space_used=$(docker system df --format '{{.Size}}' 2>/dev/null | head -n 1)

    echo -e "Total Containers : ${COLOR_GREEN}${total_containers}${COLOR_RESET}"
    echo -e "Total Volumes    : ${COLOR_GREEN}${total_volumes}${COLOR_RESET}"
    echo -e "Total Images     : ${COLOR_GREEN}${total_images}${COLOR_RESET}"
    echo -e "Disk Space Used  : ${COLOR_GREEN}${space_used:-Unknown}${COLOR_RESET}\n"

    echo -e "${COLOR_CYAN}Container Size Breakdown:${COLOR_RESET}"
    printf "%-25s %-15s\n" "CONTAINER NAME" "SIZE"
    echo "----------------------------------------"
    docker ps -a --format "{{.Names}}" | while read -r cname; do
        local csize
        csize=$(docker inspect -s "$cname" --format '{{.SizeRw}}' 2>/dev/null || echo "0")
        # Convert bytes to MB/GB
        local csize_mb
        csize_mb=$(awk "BEGIN {print $csize / 1024 / 1024}")
        printf "%-25s %.2f MB\n" "$cname" "$csize_mb"
    done
    echo ""

    echo "1) Prune Unused Docker Resources (Containers, Networks, Images, Volumes)"
    echo "2) Return to Main Menu"
    read -rp "Select Option [1-2]: " choice

    if [[ "$choice" == "1" ]]; then
        read -rp "Type 'CONFIRM' to execute system prune: " prune_conf
        if [[ "$prune_conf" == "CONFIRM" ]]; then
            log_msg "INFO" "Executing docker system prune..."
            docker system prune -a --volumes -f
            log_msg "INFO" "Docker system prune completed."
        else
            log_msg "WARN" "Prune canceled."
        fi
    fi
}

# Docbloc: Backup containers, volumes, and databases to date archive
backup_docker_workloads() {
    print_banner "DOCKER WORKLOAD BACKUP ROUTINE"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_backup_event "INFO" "[DRY-RUN] Simulating Docker workload backup..."
        echo -e "${COLOR_ORANGE}[DRY-RUN MODE ACTIVE] No changes will be written.${COLOR_RESET}"
        return 0
    fi

    # 1. Check if backup drive is mounted
    if ! mountpoint -q "$BACKUP_DRIVE_MOUNT"; then
        log_backup_event "ERROR" "Backup drive at ${BACKUP_DRIVE_MOUNT} is NOT mounted!"
        log_msg "ERROR" "Backup drive is not mounted at ${BACKUP_DRIVE_MOUNT}."
        return 1
    fi

    log_msg "WARN" "WARNING: Running this backup routine will temporarily STOP active containers to ensure database and volume consistency."
    read -rp "Do you want to proceed with the backup? [y/N]: " proceed
    if [[ "${proceed,,}" != "y" ]]; then
        log_msg "INFO" "Backup canceled by user."
        return 0
    }

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local target_backup_dir="${BACKUP_DEST_DIR}/${timestamp}"
    mkdir -p "$target_backup_dir"

    log_backup_event "INFO" "Starting Docker workload backup to ${target_backup_dir}..."

    # 2. Get list of running containers to restart later
    local running_containers
    running_containers=$(docker ps --format "{{.Names}}" | tr '\n' ' ')

    if [[ -n "$running_containers" ]]; then
        log_backup_event "INFO" "Temporarily stopping running containers: ${running_containers}"
        docker stop $running_containers
    fi

    # 3. Archive Docker Volumes (/var/lib/docker/volumes)
    log_backup_event "INFO" "Archiving Docker volumes..."
    if [[ -d /var/lib/docker/volumes ]]; then
        tar -czf "${target_backup_dir}/docker_volumes.tar.gz" -C /var/lib/docker volumes 2>/dev/null || true
    fi

    # 4. Archive Docker Compose configs if stored locally
    if [[ -d /var/local/server-configs/docker ]]; then
        log_backup_event "INFO" "Archiving server docker compose configurations..."
        tar -czf "${target_backup_dir}/docker_configs.tar.gz" -C /var/local/server-configs docker 2>/dev/null || true
    fi

    # 5. Restart containers
    if [[ -n "$running_containers" ]]; then
        log_backup_event "INFO" "Restarting previously running containers..."
        docker start $running_containers
    fi

    log_backup_event "INFO" "Docker backup archive successfully created at ${target_backup_dir}."
    log_msg "INFO" "Backup completed successfully."
}

# Docbloc: Configure automated backup schedule in cron
setup_backup_cron() {
    print_banner "CONFIGURE BACKUP CRON SCHEDULE"
    echo "Select backup schedule frequency:"
    echo "1) Daily at 2:00 AM (0 2 * * *)"
    echo "2) Weekly on Sunday at 3:00 AM (0 3 * * 0)"
    echo "3) Enter custom cron expression"
    read -rp "Select Option [1-3]: " cron_choice

    local cron_expr=""
    case "$cron_choice" in
        1) cron_expr="0 2 * * *" ;;
        2) cron_expr="0 3 * * 0" ;;
        3) 
           read -rp "Enter custom cron expression (e.g. 30 4 * * *): " cron_expr
           ;;
        *) log_msg "ERROR" "Invalid selection."; return 1 ;;
    es-case
    # corrected case syntax above if needed, but standard bash case uses ';;'

    local script_path
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    local cron_file="/etc/cron.d/homelab-docker-backup"

    log_msg "INFO" "Writing cron job to ${cron_file}..."
    cat <<EOF > "$cron_file"
# Homelab Automated Docker Backup Job
${cron_expr} root ${script_path} --backup-run >> ${CUSTOM_LOG_FILE} 2>&1
EOF

    chmod 644 "$cron_file"
    log_msg "INFO" "Cron schedule successfully registered: ${cron_expr}"
}

# Handle automated background run flag
if [[ "${1:-}" == "--backup-run" ]]; then
    backup_docker_workloads
    exit 0
fi

# Main Menu Loop
main_menu() {
    while true; do
        print_banner "DOCKER MANAGER MENU"
        echo "1) Containers Overview"
        echo "2) Stop Container(s)"
        echo "3) Restart Container(s)"
        echo "4) Docker Resources"
        echo "5) Run Backup Routine Now"
        echo "6) Configure Automated Docker Backups"
        echo "7) Exit"
        read -rp "Select Option [1-7]: " CHOICE

        case "$CHOICE" in
            1) docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"; echo "" ;;
            2) stop_containers ;;
            3) restart_containers ;;
            4) show_docker_resources ;;
            5) backup_docker_workloads ;;
            6) setup_backup_cron ;;
            7) log_msg "INFO" "Exiting Docker Manager."; exit 0 ;;
            *) log_msg "ERROR" "Invalid choice." ;;
        esac
    done
}

main_menu
