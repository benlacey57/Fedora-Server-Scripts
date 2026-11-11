#!/usr/bin/env bash
# ==============================================================================
# Script: setup-security.sh
# Description: Installs ClamAV (On-Access), Maldet, Rkhunter & Chkrootkit with Cron
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_JSON="${SCRIPT_DIR}/config.json"
BACKUP_DIR="/config/security"

if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root

# --- OS Detection ---
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
else
    log_msg "ERROR" "Cannot detect operating system via /etc/os-release."
    exit 1
fi

print_banner "ANTIVIRUS & MALWARE PROTECTION SETUP (${OS_ID^^})"

# 1. Install ClamAV, rkhunter, chkrootkit
log_msg "INFO" "Installing security scanner packages..."
if [[ "$OS_ID" == "ubuntu" || "$OS_LIKE" =~ "ubuntu" || "$OS_LIKE" =~ "debian" ]]; then
    apt-get update -qq
    apt-get install -y -qq clamav clamav-daemon clamdscan maldet rkhunter chkrootkit freshclam cron
elif [[ "$OS_ID" == "fedora" || "$OS_LIKE" =~ "fedora" || "$OS_LIKE" =~ "rhel" ]]; then
    dnf install -y clamav clamav-update clamd rkhunter chkrootkit cronie
else
    log_msg "ERROR" "Unsupported Linux distribution '${OS_ID}'."
    exit 1
fi

# 2. Configure ClamAV On-Access Scanner (clamonacc)
log_msg "INFO" "Configuring ClamAV On-Access Scanner..."
mkdir -p /var/log/clamav /var/quarantine
chmod 750 /var/quarantine

# Update freshclam virus definitions
log_msg "INFO" "Updating ClamAV virus signatures (freshclam)..."
freshclam --quiet || log_msg "WARN" "Freshclam update deferred or running in background."

# Configure clamd.conf for On-Access scanning
CLAMD_CONF="/etc/clamd.d/scan.conf"
[[ -f /etc/clamav/clamd.conf ]] && CLAMD_CONF="/etc/clamav/clamd.conf"

if [[ -f "$CLAMD_CONF" ]]; then
    sed -i 's/^Example/#Example/' "$CLAMD_CONF" 2>/dev/null || true
    
    # Enable On-Access Scanning directives
    grep -q "^OnAccessScanPath" "$CLAMD_CONF" || cat <<EOF >> "$CLAMD_CONF"

# Managed On-Access Scanner Settings
OnAccessMaxFileSize 100M
OnAccessIncludePath /home
OnAccessIncludePath /mnt/storage/downloads
OnAccessPrevention yes
OnAccessExtraScanning yes
EOF
    log_msg "INFO" "Applied On-Access scan parameters to ${CLAMD_CONF}"
fi

# Enable ClamAV Freshclam Daemon
systemctl enable --now clamav-freshclam 2>/dev/null || systemctl enable --now clamd@scan 2>/dev/null || true

# 3. Install & Configure Maldet (Linux Malware Detect)
if ! command -v maldet &>/dev/null; then
    log_msg "INFO" "Downloading and installing latest Maldet release..."
    TMP_MALDET=$(mktemp -d)
    curl -sSL https://www.rfxn.com/downloads/maldetect-current.tar.gz | tar -xz -C "$TMP_MALDET" --strip-components=1
    bash "${TMP_MALDET}/install.sh" >/dev/null
    rm -rf "$TMP_MALDET"
    log_msg "INFO" "Maldet installed successfully."
fi

# Update Maldet Signatures
log_msg "INFO" "Updating Maldet malware signatures..."
maldet -u >/dev/null 2>&1 || true

# 4. Initialize rkhunter database
log_msg "INFO" "Updating Rkhunter baseline database..."
rkhunter --propupd >/dev/null 2>&1 || true

# 5. Setup Automated Cron Jobs
setup_cron_jobs() {
    print_banner "AUTOMATED SCAN SCHEDULE (CRON SETUP)"
    echo "Configure recurring background security scans?"
    echo "1) Install Weekly System & Monthly External Drive Cron Jobs"
    echo "2) Skip Cron Configuration"
    read -rp "Select Choice [1-2]: " CRON_CHOICE

    if [[ "$CRON_CHOICE" == "1" ]]; then
        local cron_file="/etc/cron.d/homelab-security-scans"
        
        cat <<EOF > "$cron_file"
# Automated Homelab Antivirus & Rootkit Scans
# Min Hour Day Month DayOfWeek User Command
0 2 * * 0 root /usr/local/bin/scan-system --quiet >/dev/null 2>&1
0 4 1 * * root /usr/local/bin/scan-drives --quiet >/dev/null 2>&1
EOF
        chmod 644 "$cron_file"
        systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true
        log_msg "INFO" "Cron tasks configured in ${cron_file}:"
        echo "  - Weekly System Scan: Every Sunday at 02:00 AM"
        echo "  - Monthly External Drive Scan: 1st of every month at 04:00 AM"
    else
        log_msg "INFO" "Skipped Cron task creation."
    fi
}

setup_cron_jobs

print_banner "SECURITY SETUP COMPLETE"
log_msg "INFO" "ClamAV, Maldet, Rkhunter, and Chkrootkit are ready for use."