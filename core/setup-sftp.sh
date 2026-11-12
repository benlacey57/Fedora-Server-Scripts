#!/usr/bin/env bash
# ==============================================================================
# Script: setup-sftp.sh
# Description: Provisions OpenSSH chroot jail configuration for SFTP
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

print_banner "SFTP CHROOT JAIL SETUP"

groupadd --force sftp
mkdir -p /var/sftp
chown root:root /var/sftp
chmod 755 /var/sftp

mkdir -p /mnt/storage/media/downloads/
chown media:sftp /mnt/storage/media/downloads/
chmod 755 /mnt/storage/media/downloads/

SSHD_DROPIN="/etc/ssh/sshd_config.d/99-sftp-jails.conf"
cat <<EOF > "$SSHD_DROPIN"
Match Group sftpusers
    ChrootDirectory /var/sftp/%u
    ForceCommand internal-sftp
    X11Forwarding no
    AllowTcpForwarding no
EOF

systemctl restart sshd
log_msg "INFO" "SFTP chroot jail configuration applied."
