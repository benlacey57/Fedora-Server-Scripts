#!/usr/bin/env bash
# ==============================================================================
# Script: network-manager.sh
# Description: Hostname, IP Assignment, Routing & Network Diagnostic Tool
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_JSON="${ROOT_DIR}/config.json"
NETWORK_JSON="${ROOT_DIR}/config/network.json"
SYSTEM_JSON="${ROOT_DIR}/config/system.json"
BACKUP_DIR="/config/network"

if [[ -f "${ROOT_DIR}/lib.sh" ]]; then
    source "${ROOT_DIR}/lib.sh"
elif [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root
check_dependency "jq"
check_dependency "ip"

# Detect active Network Manager backend
NET_BACKEND="unknown"
if command -v nmcli &>/dev/null; then
    NET_BACKEND="networkmanager"
elif command -v netplan &>/dev/null; then
    NET_BACKEND="netplan"
elif [[ -f /etc/network/interfaces ]]; then
    NET_BACKEND="ifupdown"
fi

# Docbloc: Backup Network configuration files directly to /config/network
backup_network_configs() {
    local timestamp dest
    timestamp=$(date +%Y%m%d_%H%M%S)
    dest="${BACKUP_DIR}/net_backup_${timestamp}"

    mkdir -p "${dest}"
    log_msg "INFO" "Backing up network configurations to ${dest}..."

    [[ -d /etc/netplan ]] && cp -r /etc/netplan "${dest}/" 2>/dev/null || true
    [[ -d /etc/NetworkManager/system-connections ]] && cp -r /etc/NetworkManager/system-connections "${dest}/" 2>/dev/null || true
    [[ -f /etc/sysctl.d/99-ipforward.conf ]] && cp /etc/sysctl.d/99-ipforward.conf "${dest}/" 2>/dev/null || true
    [[ -f /etc/hostname ]] && cp /etc/hostname "${dest}/" 2>/dev/null || true
    [[ -f /etc/resolv.conf ]] && cp /etc/resolv.conf "${dest}/" 2>/dev/null || true
    [[ -f /etc/hosts ]] && cp /etc/hosts "${dest}/" 2>/dev/null || true

    log_msg "INFO" "Network configurations successfully backed up."
}

# Docbloc: Display action confirmation prompt with summary box
confirm_action() {
    local action="$1"
    local target="$2"
    local summary="$3"
    local is_destructive="${4:-false}"

    echo -e "\n${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}                         ACTION CONFIRMATION & SUMMARY                          ${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    printf "%-20s : %s\n" "Requested Action" "${action}"
    printf "%-20s : %s\n" "Target Interface/Host" "${target}"
    printf "%-20s : %s\n" "Summary of Changes" "${summary}"

    if [[ "$is_destructive" == "true" ]]; then
        echo -e "${COLOR_RED}WARNING: THIS MODIFIES SYSTEM NETWORKING AND MAY DISCONNECT ACTIVE SESSIONS!${COLOR_RESET}"
        echo -e "${COLOR_ORANGE}================================================================================${COLOR_RESET}"
        read -rp "Type 'CONFIRM' to execute this action: " CONFIRM_INPUT
        if [[ "$CONFIRM_INPUT" != "CONFIRM" ]]; then
            log_msg "WARN" "Operation canceled by user."
            return 1
        fi
    else
        echo -e "${COLOR_ORANGE}================================================================================${COLOR_RESET}"
        read -rp "Proceed with these changes? [y/N]: " CONFIRM_INPUT
        if [[ "${CONFIRM_INPUT,,}" != "y" ]]; then
            log_msg "WARN" "Operation canceled by user."
            return 1
        fi
    fi
    return 0
}

# Docbloc: Get active network interfaces (excluding loopback)
get_available_interfaces() {
    ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'
}

# Docbloc: Prompt user for interface and validate against active hardware
prompt_valid_interface() {
    local input_iface=""
    local valid_ifaces
    valid_ifaces=$(get_available_interfaces)

    while true; do
        read -rp "Enter Interface Name: " input_iface
        input_iface=$(echo "$input_iface" | tr -d ' ')

        if [[ -z "$input_iface" ]]; then
            log_msg "ERROR" "Interface name cannot be empty."
            continue
        fi

        if echo "$valid_ifaces" | grep -qx "$input_iface"; then
            echo "$input_iface"
            return 0
        else
            log_msg "ERROR" "Invalid interface '${input_iface}'."
            echo -e "${COLOR_ORANGE}Available interfaces on this system:${COLOR_RESET}"
            echo "$valid_ifaces" | sed 's/^/  - /'
        fi
    done
}

# Docbloc: Display system network overview, active IPs, and routing status
show_network_overview() {
    print_banner "NETWORK OVERVIEW & HOSTNAME STATUS (${NET_BACKEND^^})"
    
    local current_host
    current_host=$(hostname)
    echo -e "Current Hostname: ${COLOR_GREEN}${current_host}${COLOR_RESET}\n"

    printf "%-12s %-10s %-18s %-18s %-18s\n" "Interface" "State" "IPv4 Address" "Subnet (CIDR)" "MAC Address"
    echo "----------------------------------------------------------------------------------------------------"

    for iface in $(get_available_interfaces); do
        local state
        state=$(ip -o link show dev "$iface" | awk '{print $9}')
        if [[ "$state" == "UP" ]]; then
            local ip_info mac
            ip_info=$(ip -o -4 addr show dev "$iface" | awk '{print $4}' | head -n 1)
            mac=$(ip -o link show dev "$iface" | awk '{print $(NF-2)}')
            
            local ipv4="Unassigned"
            local cidr="N/A"
            if [[ -n "$ip_info" ]]; then
                ipv4="${ip_info%%/*}"
                cidr="/${ip_info##*/}"
            fi

            printf "${COLOR_GREEN}%-12s %-10s %-18s %-18s %-18s${COLOR_RESET}\n" \
                "$iface" "$state" "$ipv4" "$cidr" "${mac:-N/A}"
        fi
    done

    echo -e "\n----------------------------------------------------------------------------------------------------"
    echo "                             DISCONNECTED / DOWN INTERFACES"
    echo "----------------------------------------------------------------------------------------------------"
    for iface in $(get_available_interfaces); do
        local state
        state=$(ip -o link show dev "$iface" | awk '{print $9}')
        if [[ "$state" != "UP" ]]; then
            local mac
            mac=$(ip -o link show dev "$iface" | awk '{print $(NF-2)}')
            printf "${COLOR_ORANGE}%-12s %-10s %-18s %-18s %-18s${COLOR_RESET}\n" \
                "$iface" "$state" "Disconnected" "N/A" "${mac:-N/A}"
        fi
    done

    echo -e "\n----------------------------------------------------------------------------------------------------"
    echo "                              GATEWAY & IP FORWARDING STATUS"
    echo "----------------------------------------------------------------------------------------------------"
    local default_gw fwd_status
    default_gw=$(ip route show default 2>/dev/null | awk '/default/ {print $3 " via " $5}' | head -n 1)
    
    if [[ $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0) == "1" ]]; then
        fwd_status="${COLOR_GREEN}ENABLED (1)${COLOR_RESET}"
    else
        fwd_status="${COLOR_RED}DISABLED (0)${COLOR_RESET}"
    fi

    echo -e "Default Gateway : ${COLOR_GREEN}${default_gw:-None}${COLOR_RESET}"
    echo -e "IPv4 Forwarding : ${fwd_status}"
    echo ""
}

# Docbloc: Update System Hostname
set_system_hostname() {
    print_banner "SET SYSTEM HOSTNAME"
    local config_host=""

    if [[ -f "$SYSTEM_JSON" ]] && command -v jq &>/dev/null; then
        config_host=$(jq -r '.hostname // ""' "$SYSTEM_JSON")
    elif [[ -f "$NETWORK_JSON" ]] && command -v jq &>/dev/null; then
        config_host=$(jq -r '.hostname // ""' "$NETWORK_JSON")
    elif [[ -f "$CONFIG_JSON" ]] && command -v jq &>/dev/null; then
        config_host=$(jq -r '.network.hostname // ""' "$CONFIG_JSON")
    fi

    log_msg "INFO" "Current Hostname: $(hostname)"
    if [[ -n "$config_host" && "$config_host" != "null" ]]; then
        log_msg "INFO" "Hostname defined in config files: ${config_host}"
    fi

    read -rp "Enter new hostname (press Enter to use '${config_host:-fedora-homelab}'): " NEW_HOST
    NEW_HOST="${NEW_HOST:-${config_host:-fedora-homelab}}"

    validate_string "$NEW_HOST" "hostname" || return 1

    confirm_action "Set Hostname" "$NEW_HOST" "Update system hostname to '$NEW_HOST' via hostnamectl" "false" || return 0

    backup_network_configs

    log_msg "INFO" "Setting hostname to '${NEW_HOST}'..."
    hostnamectl set-hostname "$NEW_HOST"
    log_msg "INFO" "Hostname successfully set to $(hostname)."
}

# Docbloc: Apply Static IP or DHCP configuration
change_ip_address() {
    show_network_overview
    log_msg "INFO" "Select mode for network address configuration:"
    echo "1) Apply Static IP settings from config JSON"
    echo "2) Enter Custom Static IP settings interactively"
    echo "3) Switch Interface to DHCP"
    read -rp "Select Choice [1-3]: " IP_CHOICE

    local IFACE NEW_IP NEW_CIDR NEW_GW

    case "$IP_CHOICE" in
        1)
            if [[ -f "$NETWORK_JSON" ]] && command -v jq &>/dev/null; then
                IFACE=$(jq -r '.interfaces.primary_interface // "eth0"' "$NETWORK_JSON")
                NEW_IP=$(jq -r '.static_ip // "192.168.1.150"' "$NETWORK_JSON")
                NEW_CIDR=$(jq -r '.subnet_cidr // 24' "$NETWORK_JSON")
                NEW_GW=$(jq -r '.gateway // "192.168.1.1"' "$NETWORK_JSON")
            else
                IFACE=$(read_json_config "$CONFIG_JSON" '.network.interface // "eth0"')
                NEW_IP=$(read_json_config "$CONFIG_JSON" '.network.static_ip // "192.168.1.150"')
                NEW_CIDR=$(read_json_config "$CONFIG_JSON" '.network.subnet_cidr // 24')
                NEW_GW=$(read_json_config "$CONFIG_JSON" '.network.gateway // "192.168.1.1"')
            fi

            log_msg "INFO" "Loaded settings -> Interface: ${IFACE}, IP: ${NEW_IP}/${NEW_CIDR}, Gateway: ${NEW_GW}"
            ;;
        2)
            log_msg "INFO" "Select interface to configure:"
            IFACE=$(prompt_valid_interface)
            read -rp "Enter Static IP Address: " NEW_IP
            validate_string "$NEW_IP" "IP Address" || return 1
            read -rp "Enter Subnet CIDR [default 24]: " NEW_CIDR
            NEW_CIDR="${NEW_CIDR:-24}"
            read -rp "Enter Gateway IP: " NEW_GW
            validate_string "$NEW_GW" "Gateway IP" || return 1
            ;;
        3)
            log_msg "INFO" "Select interface to set to DHCP:"
            IFACE=$(prompt_valid_interface)
            
            confirm_action "Switch to DHCP" "$IFACE" "Reconfigure $IFACE to use automatic DHCP address assignment" "true" || return 0

            backup_network_configs

            if [[ "$NET_BACKEND" == "networkmanager" ]]; then
                nmcli con mod "$IFACE" ipv4.method auto
                nmcli con up "$IFACE"
            elif [[ "$NET_BACKEND" == "netplan" ]]; then
                cat <<EOF > "/etc/netplan/99-custom-dhcp.yaml"
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: yes
EOF
                netplan apply
            fi
            log_msg "INFO" "Switched interface ${IFACE} to DHCP."
            return 0
            ;;
        *)
            log_msg "ERROR" "Invalid option selected."
            return 1
            ;;
    esac

    confirm_action "Apply Static IP" "$IFACE" "Configure $IFACE with Static IP ${NEW_IP}/${NEW_CIDR} and Gateway ${NEW_GW}" "true" || return 0

    backup_network_configs

    if [[ "$NET_BACKEND" == "networkmanager" ]]; then
        nmcli con mod "$IFACE" ipv4.addresses "${NEW_IP}/${NEW_CIDR}" ipv4.gateway "$NEW_GW" ipv4.method manual
        nmcli con up "$IFACE"
    elif [[ "$NET_BACKEND" == "netplan" ]]; then
        cat <<EOF > "/etc/netplan/99-custom-static.yaml"
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: no
      addresses: [${NEW_IP}/${NEW_CIDR}]
      routes: [{to: default, via: ${NEW_GW}}]
EOF
        netplan apply
    fi
    log_msg "INFO" "Static IP ${NEW_IP}/${NEW_CIDR} applied to ${IFACE}."
}

# Docbloc: Troubleshoot network connectivity and DNS resolution
troubleshoot_network() {
    print_banner "TROUBLESHOOTING & DIAGNOSTICS"
    
    local gw_ip ping_targets dns_domains
    gw_ip=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n 1)

    if [[ -f "$NETWORK_JSON" ]] && command -v jq &>/dev/null; then
        ping_targets=$(jq -r '.diagnostics.ping_targets[] // empty' "$NETWORK_JSON" 2>/dev/null || echo "")
        dns_domains=$(jq -r '.diagnostics.dns_lookup_domains[] // empty' "$NETWORK_JSON" 2>/dev/null || echo "")
    fi

    [[ -z "$ping_targets" ]] && ping_targets="1.1.1.1 8.8.8.8"
    [[ -z "$dns_domains" ]] && dns_domains="google.com github.com cloudflare.com"

    echo -n "Gateway (${gw_ip:-None}): "
    if [[ -n "$gw_ip" ]] && ping -c 2 -W 2 "$gw_ip" &>/dev/null; then
        echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}[FAIL]${COLOR_RESET}"
    fi

    log_msg "INFO" "Testing ICMP Ping Targets..."
    for target in $ping_targets; do
        echo -n "  Ping target (${target}): "
        if ping -c 2 -W 2 "$target" &>/dev/null; then
            echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}"
        else
            echo -e "${COLOR_RED}[FAIL]${COLOR_RESET}"
        fi
    done

    log_msg "INFO" "Testing DNS Domain Resolution..."
    for domain in $dns_domains; do
        echo -n "  DNS lookup (${domain}): "
        if command -v host &>/dev/null && host "$domain" &>/dev/null; then
            echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}"
        elif command -v getent &>/dev/null && getent ahosts "$domain" &>/dev/null; then
            echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}"
        else
            echo -e "${COLOR_RED}[FAIL]${COLOR_RESET}"
        fi
    done
    
    echo ""
    read -rp "Press Enter to return to main menu..."
}

# Docbloc: Bounce network link (down -> up)
bounce_interface() {
    print_banner "BOUNCE NETWORK INTERFACE"
    log_msg "INFO" "Select interface to bounce (restart link):"
    local IFACE
    IFACE=$(prompt_valid_interface)

    confirm_action "Bounce Interface" "$IFACE" "Bring link $IFACE down and back up" "true" || return 0

    log_msg "INFO" "Bouncing interface ${IFACE}..."
    ip link set "$IFACE" down && sleep 1 && ip link set "$IFACE" up
    log_msg "INFO" "Bounced interface ${IFACE} successfully."
}

# Docbloc: Main Menu Loop
main_menu() {
    while true; do
        show_network_overview
        print_banner "NETWORK MANAGER MENU"
        echo "1) Refresh Overview"
        echo "2) Set System Hostname"
        echo "3) Configure Static IP / DHCP (Persistent)"
        echo "4) Run Troubleshooting & Diagnostics"
        echo "5) Bounce Interface (Restart Link)"
        echo "6) Backup Network Configuration Files"
        echo "7) Exit"
        read -rp "Select Option [1-7]: " CHOICE

        case "$CHOICE" in
            1) clear ;;
            2) set_system_hostname ;;
            3) change_ip_address ;;
            4) troubleshoot_network ;;
            5) bounce_interface ;;
            6) backup_network_configs ;;
            7) log_msg "INFO" "Exiting Network Manager."; exit 0 ;;
            *) log_msg "ERROR" "Invalid selection." ;;
        esac
    done
}

main_menu
