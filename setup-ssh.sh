#!/usr/bin/env bash
# ==============================================================================
# Script: setup-ssh.sh
# Description: Hardening, Port Binding & Firewall Config for SSH Daemon
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_JSON="${SCRIPT_DIR}/config.json"
BACKUP_DIR="/config/ssh"

if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root
check_dependency "sshd"

# --- OS Detection ---
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
else
    log_msg "ERROR" "Cannot detect operating system via /etc/os-release."
    exit 1
fi

DISTRO=""
if [[ "$OS_ID" == "ubuntu" || "$OS_LIKE" =~ "ubuntu" || "$OS_LIKE" =~ "debian" ]]; then
    DISTRO="ubuntu"
elif [[ "$OS_ID" == "fedora" || "$OS_LIKE" =~ "fedora" || "$OS_LIKE" =~ "rhel" ]]; then
    DISTRO="fedora"
else
    log_msg "ERROR" "Unsupported distribution '${OS_ID}'."
    exit 1
fi

# Docbloc: Backup SSH configuration files to /config/ssh
backup_ssh_configs() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local dest="${BACKUP_DIR}/ssh_backup_${timestamp}"

    mkdir -p "${dest}"
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        cp -r /etc/ssh/sshd_config.d "${dest}/" 2>/dev/null || true
    fi
    if [[ -f /etc/ssh/sshd_config ]]; then
        cp /etc/ssh/sshd_config "${dest}/" 2>/dev/null || true
    fi

    log_msg "INFO" "SSH server configuration backed up to ${dest}"
}

# Docbloc: Apply SSH port, authentication rules, and firewall adjustments
configure_sshd() {
    print_banner "SSH SERVER SETUP & HARDENING (${DISTRO^^})"

    local current_port default_port target_port
    current_port=$(sshd -T 2>/dev/null | grep -i "^port " | awk '{print $2}' | head -n 1 || echo "22")
    default_port=$(read_json_config "$CONFIG_JSON" '.network.default_ssh_port // 22')

    log_msg "INFO" "Current active port: ${current_port}"
    read -rp "Enter target SSH Port [default ${default_port}]: " target_port
    target_port="${target_port:-$default_port}"
    validate_port "$target_port" || return 1

    read -rp "Allow Password Authentication? [Y/n]: " ALLOW_PASS
    ALLOW_PASS="${ALLOW_PASS:-Y}"
    local pass_setting="yes"
    [[ "${ALLOW_PASS,,}" == "n" ]] && pass_setting="no"

    backup_ssh_configs

    mkdir -p /etc/ssh/sshd_config.d
    local custom_conf="/etc/ssh/sshd_config.d/99-hardened-sshd.conf"

    cat <<EOF > "${custom_conf}"
# Managed by setup-ssh.sh
Port ${target_port}
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication ${pass_setting}
KbdInteractiveAuthentication yes
MaxAuthTries 5
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowTcpForwarding yes
EOF
    chmod 600 "${custom_conf}"
    log_msg "INFO" "Applied drop-in configuration to ${custom_conf}"

    log_msg "INFO" "Configuring firewall rules and security context..."
    if [[ "$DISTRO" == "ubuntu" ]]; then
        if command -v ufw &>/dev/null; then
            log_msg "INFO" "Adding UFW rule for port ${target_port}/tcp..."
            ufw allow "${target_port}/tcp" comment 'SSH Custom Port'
            log_msg "INFO" "Reloading UFW firewall..."
            ufw reload
        else
            log_msg "WARN" "UFW is not installed. Skipping UFW firewall update."
        fi
    elif [[ "$DISTRO" == "fedora" ]]; then
        if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
            if ! command -v semanage &>/dev/null; then
                log_msg "INFO" "Installing SELinux management tools..."
                dnf install -y policycoreutils-python-utils
            fi
            if (( target_port != 22 )); then
                log_msg "INFO" "Adding SELinux context rule for SSH port ${target_port}/tcp..."
                semanage port -a -t ssh_port_t -p tcp "${target_port}" 2>/dev/null || \
                semanage port -m -t ssh_port_t -p tcp "${target_port}"
            fi
        fi

        if command -v firewall-cmd &>/dev/null; then
            if (( target_port != 22 )); then
                log_msg "INFO" "Adding permanent FirewallD rule for port ${target_port}/tcp..."
                firewall-cmd --permanent --add-port="${target_port}/tcp"
            else
                log_msg "INFO" "Ensuring standard SSH service is allowed in FirewallD..."
                firewall-cmd --permanent --add-service=ssh
            fi
            log_msg "INFO" "Reloading FirewallD rules..."
            firewall-cmd --reload
        else
            log_msg "WARN" "FirewallD is not running/installed. Skipping FirewallD update."
        fi
    fi

    log_msg "INFO" "Testing SSH configuration syntax..."
    sshd -t

    local service_name="sshd"
    if [[ "$DISTRO" == "ubuntu" ]] && systemctl list-unit-files | grep -q "^ssh.service"; then
        service_name="ssh"
    fi

    systemctl restart "${service_name}"
    log_msg "INFO" "SSH Service (${service_name}) successfully restarted on port ${target_port}."
}

configure_sshd