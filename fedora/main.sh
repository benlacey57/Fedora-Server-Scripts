#!/usr/bin/env bash
# ==============================================================================
# Script: main-menu.sh
# Description: Central Interactive Admin Launcher for System & Media Stack
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root

main_menu() {
    while true; do
        print_banner "MEDIA SERVER SYSTEM ADMINISTRATION"
        echo "1) Network & Diagnostics Manager"
        echo "2) SSH & Security Manager"
        echo "3) User Account & Password Manager"
        echo "4) UFW Firewall Manager"
        echo "5) Disk, LUKS & Storage Manager"
        echo "6) Docker Stack & Container Manager"
        echo "7) Run System OS Antivirus & Malware Scan"
        echo "8) Run External Drive Security Scan"
        echo "9) Run Full Fedora System Hardening Setup"
        echo "10) Exit"
        read -rp "Select Management Option [1-10]: " CHOICE

        case "$CHOICE" in
            1) "${SCRIPT_DIR}/utils/network-manager.sh" ;;
            2) "${SCRIPT_DIR}/utils/ssh-manager.sh" ;;
            3) "${SCRIPT_DIR}/utils/user-manager.sh" ;;
            4) "${SCRIPT_DIR}/utils/firewall-manager.sh" ;;
            5) "${SCRIPT_DIR}/utils/disk-manager.sh" ;;
            6) "${SCRIPT_DIR}/utils/docker-manager.sh" ;;
            7) "${SCRIPT_DIR}/utils/scan-system.sh" ;;
            8) "${SCRIPT_DIR}/utils/scan-drives.sh" ;;
            9) "${SCRIPT_DIR}/core/setup-fedora.sh" ;;
            10) log_msg "INFO" "Exiting Admin Console."; exit 0 ;;
            *) log_msg "ERROR" "Invalid choice." ;;
        esac
    done
}

main_menu
