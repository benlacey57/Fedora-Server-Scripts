#!/usr/bin/env bash
# ==============================================================================
# Script: network-manager.sh
# Description: Hostname, IP Assignment, Routing & Network Diagnostic Tool
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_JSON="${SCRIPT_DIR}/config.json"
BACKUP_DIR="/config/network"

if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
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
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local dest="${BACKUP_DIR}/net_backup_${timestamp}"

    mkdir -p "${dest}"
    [[ -d /etc/netplan ]] && cp -r /etc/netplan "${dest}/" 2>/dev/null || true
    [[ -d /etc/NetworkManager/system-connections ]] && cp -r /etc/NetworkManager/system-connections "${dest}/" 2>/dev/null || true
    [[ -f /etc/sysctl.d/99-ipforward.conf ]] && cp /etc/sysctl.d/99-ipforward.conf "${dest}/" 2>/dev/null || true
    [[ -f /etc/hostname ]] && cp /etc/hostname "${dest}/" 2>/dev/null || true

    log_msg "INFO" "Network configurations backed up to ${dest}"
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
    local config_host
    config_host=$(read_json_config "$CONFIG_JSON" '.network.hostname // ""')

    log_msg "INFO" "Current Hostname: $(hostname)"
    if [[ -n "$config_host" && "$config_host" != "null" ]]; then
        log_msg "INFO" "Hostname defined in config.json: ${config_host}"
    fi

    read -rp "Enter new hostname (press Enter to use '${config_host:-fedora-homelab}'): " NEW_HOST
    NEW_HOST="${NEW_HOST:-${config_host:-fedora-homelab}}"

    validate_string "$NEW_HOST" "hostname" || return 1
    backup_network_configs

    log_msg "INFO" "Setting hostname to '${NEW_HOST}'..."
    hostnamectl set-hostname "$NEW_HOST"
    log_msg "INFO" "Hostname successfully set to $(hostname)."
}

# Docbloc: Apply Static IP or DHCP configuration
change_ip_address() {
    show_network_overview
    log_msg "INFO" "Select mode for network address configuration:"
    echo "1) Apply Static IP settings from config.json"
    echo "2) Enter Custom Static IP settings interactively"
    echo "3) Switch Interface to DHCP"
    read -rp "Select Choice [1-3]: " IP_CHOICE

    local IFACE NEW_IP NEW_CIDR NEW_GW

    case "$IP_CHOICE" in
        1)
            IFACE=$(read_json_config "$CONFIG_JSON" '.network.interface // "eth0"')
            NEW_IP=$(read_json_config "$CONFIG_JSON" '.network.static_ip // "192.168.1.150"')
            NEW_CIDR=$(read_json_config "$CONFIG_JSON" '.network.subnet_cidr // 24')
            NEW_GW=$(read_json_config "$CONFIG_JSON" '.network.gateway // "192.168.1.1"')

            log_msg "INFO" "Loaded from config.json -> Interface: ${IFACE}, IP: ${NEW_IP}/${NEW_CIDR}, Gateway: ${NEW_GW}"
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

# Docbloc: Troubleshoot network connectivity
troubleshoot_network() {
    print_banner "TROUBLESHOOTING & DIAGNOSTICS"
    local gw_ip
    gw_ip=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n 1)

    echo -n "Gateway (${gw_ip:-None}): "
    ping -c 2 -W 2 "${gw_ip:-127.0.0.1}" &>/dev/null && echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}" || echo -e "${COLOR_RED}[FAIL]${COLOR_RESET}"

    echo -n "Internet Connectivity (1.1.1.1): "
    ping -c 2 -W 2 1.1.1.1 &>/dev/null && echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}" || echo -e "${COLOR_RED}[FAIL]${COLOR_RESET}"

    echo -n "DNS Resolution (google.com): "
    host google.com &>/dev/null && echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}" || echo -e "${COLOR_RED}[FAIL]${COLOR_RESET}"
    
    echo ""
    read -rp "Press Enter to return to main menu..."
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
            5) 
                log_msg "INFO" "Select Interface to bounce:"
                local IFACE
                IFACE=$(prompt_valid_interface)
                ip link set "$IFACE" down && sleep 1 && ip link set "$IFACE" up
                log_msg "INFO" "Bounced interface ${IFACE}."
                ;;
            6) backup_network_configs ;;
            7) log_msg "INFO" "Exiting Network Manager."; exit 0 ;;
            *) log_msg "ERROR" "Invalid selection." ;;
        esac
    done
}

main_menu