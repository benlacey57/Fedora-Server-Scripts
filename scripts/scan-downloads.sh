#!/usr/bin/env bash
# ==============================================================================
# Script: scan-downloads.sh
# Description: Incremental ClamAV Scan for Newly Added Download Files
# ==============================================================================

set -euo pipefail

TARGET_DIR="/mnt/storage/downloads"
CUSTOM_LOG_FILE="/var/log/homelab-virus-scan.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "[${TIMESTAMP}] [ERROR] Target directory ${TARGET_DIR} does not exist." >> "$CUSTOM_LOG_FILE"
    exit 1
fi

echo "[${TIMESTAMP}] [INFO] Starting incremental ClamAV scan for files modified in the last 2 hours..." >> "$CUSTOM_LOG_FILE"

# Find files modified in the last 2 hours and pass them to clamscan
find "$TARGET_DIR" -type f -mmin -120 -print0 | xargs -0 -r clamscan --infected >> "$CUSTOM_LOG_FILE" 2>&1 || true

echo "[${TIMESTAMP}] [INFO] Incremental scan completed." >> "$CUSTOM_LOG_FILE"
