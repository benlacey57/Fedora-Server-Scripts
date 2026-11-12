#!/usr/bin/env bash
# ==============================================================================
# Script: setup-samba.sh
# Description: Installs and provisions Samba file shares
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${ROOT_DIR}/lib.sh" ]]; then
    source "${ROOT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root

print_banner "SAMBA FILE SHARING SETUP"

dnf install -y samba samba-client

mkdir -p /mnt/storage/
chmod -R 775 /mnt/storage

# Backup original smb.conf
[[ -f /etc/samba/smb.conf ]] && cp /etc/samba/smb.conf /root/config/samba/smb.conf

cat <<EOF > /etc/samba/smb.conf
[global]
    workgroup = WORKGROUP
    server string = Homelab Samba Server
    security = user
    map to guest = Bad User
    dns proxy = no

[media]
    path = /mnt/storage/media
    browsable = yes
    writable = no
    guest ok = no
    valid users = media @sftp

[downloads]
    path = /mnt/storage/downloads
    browsable = yes
    writable = yes
    guest ok = no
    valid users = media @sftp
EOF

[games]
    path = /mnt/storage/games
    browsable = yes
    writable = yes
    guest ok = no
    valid users = media @sftp
EOF

[isos]
    path = /mnt/storage/isos
    browsable = yes
    writable = yes
    guest ok = yes
EOF

[backups]
    path = /mnt/backup/
    browsable = yes
    writable = yes
    guest ok = no
    valid users = media @sftp
EOF


systemctl enable --now smb nmb
firewall-cmd --permanent --add-service=samba
firewall-cmd --reload

log_msg "INFO" "Samba service configured and started successfully."
