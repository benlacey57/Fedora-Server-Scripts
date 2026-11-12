#!/usr/bin/env bash
# ==============================================================================
# Script: notification-manager.sh
# Description: Advanced CLI Manager for Notifications Configuration & Logs
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
NOTIFICATIONS_JSON="${ROOT_DIR}/config/notifications.json"
CUSTOM_LOG_FILE="/var/log/homelab-notifications.log"

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
check_dependency "python3"

mkdir -p "$(dirname "$NOTIFICATIONS_JSON")"
touch "$CUSTOM_LOG_FILE"

init_default_config() {
    if [[ ! -f "$NOTIFICATIONS_JSON" ]]; then
        cat <<EOF > "$NOTIFICATIONS_JSON"
{
  "smtp": {
    "enabled": false,
    "server": "smtp.gmail.com",
    "port": 587,
    "user": "",
    "pass_encrypted": "",
    "from_address": "server-alerts@homelab.lan",
    "to_addresses": []
  },
  "webhooks": []
}
EOF
    }
}

# Docbloc: List all notification channels and statuses
list_channels_overview() {
    print_banner "NOTIFICATION CHANNELS OVERVIEW"
    init_default_config

    echo -e "${COLOR_CYAN}[1] SMTP Email Service${COLOR_RESET}"
    local smtp_enabled smtp_server smtp_user smtp_recips
    smtp_enabled=$(jq -r '.smtp.enabled // false' "$NOTIFICATIONS_JSON")
    smtp_server=$(jq -r '.smtp.server // "Not Set"' "$NOTIFICATIONS_JSON")
    smtp_user=$(jq -r '.smtp.user // "Not Set"' "$NOTIFICATIONS_JSON")
    smtp_recips=$(jq -r '.smtp.to_addresses | join(", ") // "None"' "$NOTIFICATIONS_JSON")

    echo "    Status      : ${smtp_enabled}"
    echo "    Server      : ${smtp_server}"
    echo "    Username    : ${smtp_user}"
    echo "    Recipients  : ${smtp_recips}"
    echo ""

    echo -e "${COLOR_CYAN}[Webhooks & Chat Channels]${COLOR_RESET}"
    local count
    count=$(jq '.webhooks | length' "$NOTIFICATIONS_JSON" 2>/dev/null || echo 0)
    if (( count == 0 )); then
        echo "    No webhook channels configured."
    else
        for ((i=0; i<count; i++)); do
            local name enabled url
            name=$(jq -r ".webhooks[$i].name" "$NOTIFICATIONS_JSON")
            enabled=$(jq -r ".webhooks[$i].enabled" "$NOTIFICATIONS_JSON")
            url=$(jq -r ".webhooks[$i].url" "$NOTIFICATIONS_JSON")
            echo "    [$((i+2))] Provider : ${name}"
            echo "        Enabled : ${enabled}"
            echo "        URL     : ${url}"
        done
    fi
    echo ""
}

# Docbloc: Configure or edit SMTP settings
configure_smtp() {
    print_banner "CONFIGURE / EDIT SMTP EMAIL SETTINGS"
    init_default_config

    local cur_enabled cur_server cur_port cur_user cur_from cur_recips
    cur_enabled=$(jq -r '.smtp.enabled // false' "$NOTIFICATIONS_JSON")
    cur_server=$(jq -r '.smtp.server // "smtp.gmail.com"' "$NOTIFICATIONS_JSON")
    cur_port=$(jq -r '.smtp.port // 587' "$NOTIFICATIONS_JSON")
    cur_user=$(jq -r '.smtp.user // ""' "$NOTIFICATIONS_JSON")
    cur_from=$(jq -r '.smtp.from_address // "server-alerts@homelab.lan"' "$NOTIFICATIONS_JSON")
    cur_recips=$(jq -r '.smtp.to_addresses | join(", ")' "$NOTIFICATIONS_JSON")

    read -rp "Enable SMTP notifications? [y/N] (Current: ${cur_enabled}): " enable_choice
    local enabled="$cur_enabled"
    if [[ "${enable_choice,,}" == "y" ]]; then enabled="true"; elif [[ "${enable_choice,,}" == "n" ]]; then enabled="false"; fi

    read -rp "SMTP Server Host [default: ${cur_server}]: " server
    server="${server:-$cur_server}"

    read -rp "SMTP Server Port [default: ${cur_port}]: " port
    port="${port:-$cur_port}"

    read -rp "SMTP Username/Email [default: ${cur_user}]: " user
    user="${user:-$cur_user}"

    read -rsp "SMTP Password (leave blank to keep existing): " pass
    echo ""

    read -rp "Sender 'From' Address [default: ${cur_from}]: " from_addr
    from_addr="${from_addr:-$cur_from}"

    read -rp "Recipient Emails (comma separated) [default: ${cur_recips}]: " recipients_input
    recipients_input="${recipients_input:-$cur_recips}"

    local pass_enc_arg=""
    if [[ -n "$pass" ]]; then
        pass_enc_arg=$(encrypt_string "$pass")
    fi

    python3 -c "
import json

path = '$NOTIFICATIONS_JSON'
with open(path, 'r') as f:
    data = json.load(f)

data['smtp']['enabled'] = ($enabled == 'true')
data['smtp']['server'] = '$server'
data['smtp']['port'] = int('$port')
data['smtp']['user'] = '$user'
if '$pass_enc_arg':
    data['smtp']['pass_encrypted'] = '$pass_enc_arg'
data['smtp']['from_address'] = '$from_addr'

recips = [r.strip() for r in '$recipients_input'.split(',') if r.strip()]
if recips:
    data['smtp']['to_addresses'] = recips

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
"
    echo -e "${COLOR_GREEN}SMTP settings successfully updated!${COLOR_RESET}\n"
}

# Docbloc: Configure, edit, enable/disable, or delete webhooks
manage_webhooks() {
    print_banner "MANAGE CHAT / WEBHOOK PROVIDERS"
    init_default_config

    echo "1) Add New Webhook Provider"
    echo "2) Toggle Enable/Disable Existing Webhook"
    echo "3) Edit Existing Webhook"
    echo "4) Delete Webhook Provider"
    echo "5) Back to Main Menu"
    read -rp "Select option [1-5]: " choice

    case "$choice" in
        1)
            read -rp "Enter Provider Name (slack, discord, ntfy, custom): " provider_name
            read -rp "Webhook / Service URL: " webhook_url
            read -rp "Enable this channel? [Y/n]: " enable_choice
            local enabled="true"
            [[ "${enable_choice,,}" == "n" ]] && enabled="false"

            python3 -c "
import json
path = '$NOTIFICATIONS_JSON'
with open(path, 'r') as f:
    data = json.load(f)
data['webhooks'] = [w for w in data['webhooks'] if w['name'] != '$provider_name']
data['webhooks'].append({'name': '$provider_name', 'enabled': ($enabled == 'true'), 'url': '$webhook_url'})
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
"
            echo -e "${COLOR_GREEN}Webhook '${provider_name}' added successfully!${COLOR_RESET}\n"
            ;;
        2|3)
            local count
            count=$(jq '.webhooks | length' "$NOTIFICATIONS_JSON")
            if (( count == 0 )); then
                echo -e "${COLOR_ORANGE}No webhooks available to modify.${COLOR_RESET}\n"
                return
            fi
            echo "Select webhook index:"
            for ((i=0; i<count; i++)); do
                local name enabled
                name=$(jq -r ".webhooks[$i].name" "$NOTIFICATIONS_JSON")
                enabled=$(jq -r ".webhooks[$i].enabled" "$NOTIFICATIONS_JSON")
                echo "  [$((i+1))] ${name} (Enabled: ${enabled})"
            done
            read -rp "Select index: " idx
            local target_idx=$((idx-1))

            if (( target_idx >= 0 && target_idx < count )); then
                if [[ "$choice" == "2" ]]; then
                    python3 -c "
import json
path = '$NOTIFICATIONS_JSON'
with open(path, 'r') as f:
    data = json.load(f)
cur = data['webhooks'][$target_idx]['enabled']
data['webhooks'][$target_idx]['enabled'] = not cur
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
"
                    echo -e "${COLOR_GREEN}Webhook status toggled successfully!${COLOR_RESET}\n"
                else
                    read -rp "Enter new URL (leave blank to keep current): " new_url
                    python3 -c "
import json
path = '$NOTIFICATIONS_JSON'
with open(path, 'r') as f:
    data = json.load(f)
if '$new_url':
    data['webhooks'][$target_idx]['url'] = '$new_url'
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
"
                    echo -e "${COLOR_GREEN}Webhook updated successfully!${COLOR_RESET}\n"
                fi
            else
                log_msg "ERROR" "Invalid index selected."
            fi
            ;;
        4)
            local count
            count=$(jq '.webhooks | length' "$NOTIFICATIONS_JSON")
            if (( count == 0 )); then return; fi
            echo "Select webhook to delete:"
            for ((i=0; i<count; i++)); do
                local name
                name=$(jq -r ".webhooks[$i].name" "$NOTIFICATIONS_JSON")
                echo "  [$((i+1))] ${name}"
            done
            read -rp "Select index: " idx
            local target_idx=$((idx-1))
            python3 -c "
import json
path = '$NOTIFICATIONS_JSON'
with open(path, 'r') as f:
    data = json.load(f)
removed = data['webhooks'].pop($target_idx)
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
print(f'Removed {removed[\"name\"]}')
"
            echo -e "${COLOR_GREEN}Webhook deleted successfully!${COLOR_RESET}\n"
            ;;
        *)
            return
            ;;
    esac
}

# Docbloc: View custom notification logs filtered by provider/channel
view_provider_logs() {
    print_banner "VIEW NOTIFICATION LOGS (FILTERED)"

    if [[ ! -f "$CUSTOM_LOG_FILE" ]]; then
        echo -e "${COLOR_ORANGE}No log file found at ${CUSTOM_LOG_FILE}.${COLOR_RESET}\n"
        return
    fi

    echo "Available Filter Options:"
    echo "1) SMTP Email Logs"
    echo "2) Specific Webhook Provider Logs (Slack, Discord, Ntfy, etc.)"
    echo "3) View All Notification Logs"
    read -rp "Select option [1-3]: " log_choice

    case "$log_choice" in
        1)
            echo -e "\n${COLOR_CYAN}--- Filtered Logs: SMTP ---${COLOR_RESET}"
            grep -i "smtp" "$CUSTOM_LOG_FILE" | tail -n 30 || echo "No matching logs found."
            echo ""
            ;;
        2)
            read -rp "Enter provider name to filter (e.g. slack, discord, ntfy): " p_name
            echo -e "\n${COLOR_CYAN}--- Filtered Logs: ${p_name} ---${COLOR_RESET}"
            grep -i "$p_name" "$CUSTOM_LOG_FILE" | tail -n 30 || echo "No matching logs found for '${p_name}'."
            echo ""
            ;;
        3)
            echo -e "\n${COLOR_CYAN}--- Recent Notification Logs (Last 40 Lines) ---${COLOR_RESET}"
            tail -n 40 "$CUSTOM_LOG_FILE"
            echo ""
            ;;
        *)
            echo "Invalid option."
            ;;
    esac
}

test_notifications_menu() {
    if [[ -f "${SCRIPT_DIR}/notify.sh" ]]; then
        "${SCRIPT_DIR}/notify.sh" --test
    else
        log_msg "ERROR" "notify.sh utility not found in ${SCRIPT_DIR}."
    fi
}

# Main Menu Loop
main_menu() {
    while true; do
        list_channels_overview
        print_banner "NOTIFICATION MANAGER MENU"
        echo "1) Configure SMTP Settings"
        echo "2) Manage Webhooks"
        echo "3) Test Notification Channels"
        echo "4) View Logs"
        echo "5) Exit"
        read -rp "Select Option [1-5]: " CHOICE

        case "$CHOICE" in
            1) configure_smtp ;;
            2) manage_webhooks ;;
            3) test_notifications_menu ;;
            4) view_provider_logs ;;
            5) log_msg "INFO" "Exiting Notification Manager."; exit 0 ;;
            *) log_msg "ERROR" "Invalid option." ;;
        esac
    done
}

main_menu
