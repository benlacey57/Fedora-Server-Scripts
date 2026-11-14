#!/usr/bin/env bash
# ==============================================================================
# Script: scan-system.sh
# Description: Performs ClamAV, Maldet, Rkhunter & Chkrootkit scans on Primary OS
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/log/security_scans"
QUARANTINE_DIR="/var/quarantine"

if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root
check_dependency "clamscan"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="${LOG_DIR}/system_scan_${TIMESTAMP}.log"
mkdir -p "$LOG_DIR" "$QUARANTINE_DIR"

print_banner "PRIMARY OS DRIVE SECURITY SCAN"
log_msg "INFO" "Scan execution started. Logging results to ${REPORT_FILE}"

{
    echo "================================================================================="
    echo "                   FULL SYSTEM SECURITY AUDIT REPORT                             "
    echo "                   Timestamp: $(date)                                            "
    echo "================================================================================="
    echo ""

    # 1. ClamAV Primary OS File Scan
    echo "--- [1/4] ClamAV Virus Scan (Root & Home Filesystems) ---"
    clamscan -r -i \
        --exclude-dir="^/sys" \
        --exclude-dir="^/proc" \
        --exclude-dir="^/dev" \
        --exclude-dir="^/run" \
        --exclude-dir="^/mnt" \
        --exclude-dir="^/media" \
        --move="$QUARANTINE_DIR" \
        / /home 2>&1 || true
    echo ""

    # 2. Maldet Malware Scan
    echo "--- [2/4] Linux Malware Detect (Maldet Scan) ---"
    if command -v maldet &>/dev/null; then
        maldet -a /home /var/www /etc 2>&1 || true
    else
        echo "Maldet not installed. Skipping."
    fi
    echo ""

    # 3. Rkhunter Rootkit Audit
    echo "--- [3/4] Rootkit Hunter (rkhunter Audit) ---"
    if command -v rkhunter &>/dev/null; then
        rkhunter --check --sk --no-colors 2>&1 || true
    else
        echo "rkhunter not installed. Skipping."
    fi
    echo ""

    # 4. Chkrootkit Verification
    echo "--- [4/4] Chkrootkit System Inspection ---"
    if command -v chkrootkit &>/dev/null; then
        chkrootkit -q 2>&1 || true
    else
        echo "chkrootkit not installed. Skipping."
    fi
    echo ""

    echo "================================================================================="
    echo "                      END OF SYSTEM SECURITY AUDIT REPORT                        "
    echo "================================================================================="
} 2>&1 | tee >(sed -u -r 's/\x1B\[[0-9;]*[mK]//g' > "$REPORT_FILE")

log_msg "INFO" "Full system security scan finished."
echo -e "${COLOR_GREEN}Report saved to:${COLOR_RESET} ${REPORT_FILE}"
echo -e "${COLOR_ORANGE}Quarantine folder:${COLOR_RESET} ${QUARANTINE_DIR}\n"