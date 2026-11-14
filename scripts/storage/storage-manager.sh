#!/usr/bin/env bash
# ==============================================================================
# Script: storage-manager.sh
# Description: Storage Pool, LUKS Decryption, SMART Health & Mount Management
# ==============================================================================
set -euo pipefail

BACKUP_DIR="/config/storage"
mkdir -p "$BACKUP_DIR"

print_banner() {
    echo "=================================================================="
    echo "  $1"
    echo "=================================================================="
}

# Docbloc: Backup active storage configuration files
backup_storage_configs() {
    local timestamp dest
    timestamp=$(date +%Y%m%d_%H%M%S)
    dest="${BACKUP_DIR}/storage_backup_${timestamp}"

    mkdir -p "${dest}"
    echo "[+] Backing up fstab and crypttab to ${dest}..."
    [[ -f /etc/fstab ]] && cp /etc/fstab "${dest}/fstab.bak" 2>/dev/null || true
    [[ -f /etc/crypttab ]] && cp /etc/crypttab "${dest}/crypttab.bak" 2>/dev/null || true
}

# Docbloc: Display disk usage and block devices
show_storage_overview() {
    print_banner "STORAGE POOL & DRIVE OVERVIEW"
    df -h --output=target,fstype,size,used,avail,pcent | column -t
    echo ""
    lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT
    echo ""
}

# Docbloc: Check SMART health across physical drive block devices
check_smart_health() {
    print_banner "SMART DRIVE HEALTH DIAGNOSTICS"
    if ! command -v smartctl &>/dev/null; then
        echo "[!] smartmontools is not installed. Installing..."
        sudo dnf install -y smartmontools || sudo apt-get install -y smartmontools
    fi

    for dev in $(lsblk -dno NAME | grep -E '^sd|^nvme'); do
        local dev_path="/dev/${dev}"
        local health
        health=$(smartctl -H "$dev_path" 2>/dev/null | grep -E "test result|SMART Health Status" || echo "SMART status unavailable")
        echo -e "${dev_path} : ${health}"
    done
    echo ""
    read -rp "Press Enter to return to menu..."
}

# Docbloc: Mount or Unmount local arrays
manage_mounts() {
    print_banner "MANAGE DISK MOUNTS"
    echo "1) Mount Primary Storage (/mnt/storage)"
    echo "2) Unmount Primary Storage (/mnt/storage)"
    echo "3) Test / Remount All (mount -a)"
    read -rp "Select Option [1-3]: " M_CHOICE

    case "$M_CHOICE" in
        1)
            sudo mkdir -p /mnt/storage
            sudo mount /mnt/storage 2>/dev/null || sudo mount -a
            echo "[+] /mnt/storage mount processed."
            ;;
        2)
            sudo umount /mnt/storage
            echo "[+] /mnt/storage unmounted."
            ;;
        3)
            backup_storage_configs
            sudo mount -a
            echo "[+] All system mounts reloaded via /etc/fstab."
            ;;
        *) echo "Invalid choice." ;;
    esac
}

# Docbloc: Main Menu Loop
main_menu() {
    while true; do
        show_storage_overview
        print_banner "STORAGE MANAGER MENU"
        echo "1) Refresh Overview"
        echo "2) Check SMART Drive Health"
        echo "3) Manage Mounts & fstab Reload"
        echo "4) Exit"
        read -rp "Select Option [1-4]: " CHOICE

        case "$CHOICE" in
            1) clear ;;
            2) check_smart_health ;;
            3) manage_mounts ;;
            4) exit 0 ;;
            *) echo "Invalid selection." ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_menu
fi
