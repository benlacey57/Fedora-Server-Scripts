#!/usr/bin/env bash
# ==============================================================================
# Script: scans/scan-downloads.sh
# Description: Incremental ClamAV Scan for Newly Added Download Files
# ==============================================================================

set -euo pipefail

TARGET_DIR="/mnt/storage/downloads"
LOG_FILE="/var/log/security_scans/downloads_incremental.log"
QUARANTINE_DIR="/var/quarantine/downloads"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

mkdir -p "$(dirname "$LOG_FILE")" "$QUARANTINE_DIR"

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "[${TIMESTAMP}] [ERROR] Target directory ${TARGET_DIR} does not exist." >> "$LOG_FILE"
    exit 1
fi

echo "[${TIMESTAMP}] [INFO] Starting incremental ClamAV scan for files modified in the last 120 minutes..." >> "$LOG_FILE"

# Find files modified in the last 120 minutes and pass them to clamscan efficiently
find "$TARGET_DIR" -type f -mmin -120 -print0 | xargs -0 -r clamscan --infected --move="$QUARANTINE_DIR" >> "$LOG_FILE" 2>&1 || true

echo "[${TIMESTAMP}] [INFO] Incremental downloads scan completed." >> "$LOG_FILE"
