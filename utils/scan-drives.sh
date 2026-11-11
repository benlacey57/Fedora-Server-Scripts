#!/usr/bin/env bash
# ==============================================================================
# Script: scan-drives.sh
# Description: Antivirus & Malware Scanner for External Drives and Mounts
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/log/security_scans"
QUARANTINE_DIR="/var/quarantine/external"

if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root
check_dependency "clamscan"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="${LOG_DIR}/external_drives_scan_${TIMESTAMP}.log"
mkdir -p "$LOG_DIR" "$QUARANTINE_DIR"

print_banner "EXTERNAL DRIVES & STORAGE MOUNTS SCAN"

# Auto-detect mounted external storage targets
SCAN_TARGETS=()
for mount_point in /mnt/* /media/* /media/*/*; do
    if [[ -d "$mount_point" ]] && mountpoint -q "$mount_point"; then
        SCAN_TARGETS+=("$mount_point")
    fi
done

if (( ${#SCAN_TARGETS[@]} == 0 )); then
    log_msg "WARN" "No active external drive mounts detected in /mnt or /media."
    echo -e "${COLOR_ORANGE}Specify custom mount target manually:${COLOR_RESET}"
    read -rp "Enter directory path to scan (or press Enter to exit): " CUSTOM_TARGET
    if [[ -n "$CUSTOM_TARGET" && -d "$CUSTOM_TARGET" ]]; then
        SCAN_TARGETS+=("$CUSTOM_TARGET")
    else
        log_msg "INFO" "Exiting scanner."
        exit 0
    fi
fi

log_msg "INFO" "Discovered scan targets:"
for target in "${SCAN_TARGETS[@]}"; do
    echo "  - ${target}"
done

{
    echo "================================================================================="
    echo "                EXTERNAL STORAGE SECURITY SCAN REPORT                            "
    echo "                Timestamp: $(date)                                               "
    echo "================================================================================="
    echo ""

    for target in "${SCAN_TARGETS[@]}"; do
        echo "---------------------------------------------------------------------------------"
        echo " Scanning Target: ${target}"
        echo "---------------------------------------------------------------------------------"

        # 1. ClamAV External Mount Scan
        echo "--- ClamAV Virus Scan ---"
        clamscan -r -i \
            --move="$QUARANTINE_DIR" \
            "$target" 2>&1 || true
        echo ""

        # 2. Maldet Scan on External Mount
        if command -v maldet &>/dev/null; then
            echo "--- Maldet Malware Scan ---"
            maldet -a "$target" 2>&1 || true
            echo ""
        fi
    done

    echo "================================================================================="
    echo "                END OF EXTERNAL STORAGE SECURITY REPORT                          "
    echo "================================================================================="
} 2>&1 | tee >(sed -u -r 's/\x1B\[[0-9;]*[mK]//g' > "$REPORT_FILE")

log_msg "INFO" "External drive security scan finished."
echo -e "${COLOR_GREEN}Report saved to:${COLOR_RESET} ${REPORT_FILE}"
echo -e "${COLOR_ORANGE}Quarantine folder:${COLOR_RESET} ${QUARANTINE_DIR}\n"