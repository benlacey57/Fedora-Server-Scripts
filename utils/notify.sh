#!/usr/bin/env bash
# ==============================================================================
# Script: notify.sh
# Description: Declarative Multi-Channel Notification Dispatcher with Test Loop
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
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

check_dependency "jq"
check_dependency "python3"
check_dependency "curl"

mkdir -p "$(dirname "$CUSTOM_LOG_FILE")"

log_notify_event() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line="[${timestamp}] [${level}] ${msg}"
    echo "$log_line" | tee -a "$CUSTOM_LOG_FILE"
}

# Docbloc: Send SMTP Email Alert
send_smtp_alert() {
    local subject="$1"
    local message="$2"

    if [[ ! -f "$NOTIFICATIONS_JSON" ]]; then
        return 0
    }

    local enabled server port user pass_enc pass_plain from_addr to_addr
    enabled=$(jq -r '.smtp.enabled // false' "$NOTIFICATIONS_JSON")
    [[ "$enabled" == "true" ]] || return 0

    server=$(jq -r '.smtp.server // "smtp.gmail.com"' "$NOTIFICATIONS_JSON")
    port=$(jq -r '.smtp.port // 587' "$NOTIFICATIONS_JSON")
    user=$(jq -r '.smtp.user // ""' "$NOTIFICATIONS_JSON")
    pass_enc=$(jq -r '.smtp.pass_encrypted // ""' "$NOTIFICATIONS_JSON")
    from_addr=$(jq -r '.smtp.from_address // "alerts@homelab.lan"' "$NOTIFICATIONS_JSON")
    to_addr=$(jq -r '.smtp.to_address // ""' "$NOTIFICATIONS_JSON")

    [[ -n "$to_addr" ]] || return 0

    pass_plain=$(decrypt_string "$pass_enc")

    log_notify_event "INFO" "Attempting SMTP email dispatch to ${to_addr} via ${server}:${port}..."

    python3 -c "
import smtplib, sys
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart

try:
    msg = MIMEMultipart()
    msg['From'] = '''$from_addr'''
    msg['To'] = '''$to_addr'''
    msg['Subject'] = '''$subject'''
    msg.attach(MIMEText('''$message''', 'plain'))

    server = smtplib.SMTP('''$server''', int('$port'))
    server.starttls()
    if '''$user''' and '''$pass_plain''':
        server.login('''$user''' , '''$pass_plain''')
    server.send_message(msg)
    server.quit()
except Exception as e:
    print(f'SMTP Dispatch Error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>> "$CUSTOM_LOG_FILE" && log_notify_event "INFO" "SMTP email sent successfully." || log_notify_event "ERROR" "SMTP email dispatch failed."
}

# Docbloc: Send Webhook Alerts (Slack, Discord, Ntfy, Generic)
send_webhook_alerts() {
    local title="$1"
    local message="$2"
    local level="$3"

    [[ -f "$NOTIFICATIONS_JSON" ]] || return 0

    local count
    count=$(jq '.webhooks | length' "$NOTIFICATIONS_JSON" 2>/dev/null || echo 0)

    for ((i=0; i<count; i++)); do
        local name enabled url
        name=$(jq -r ".webhooks[$i].name // \"webhook-$i\"" "$NOTIFICATIONS_JSON")
        enabled=$(jq -r ".webhooks[$i].enabled // false" "$NOTIFICATIONS_JSON")
        url=$(jq -r ".webhooks[$i].url // \"\"" "$NOTIFICATIONS_JSON")

        [[ "$enabled" == "true" && -n "$url" ]] || continue

        log_notify_event "INFO" "Dispatching webhook '${name}'..."

        if [[ "$name" == "slack" ]]; then
            if curl -s -X POST -H 'Content-type: application/json' \
                --data "{\"text\":\"*[${level}] ${title}:* ${message}\"" \
                "$url" >/dev/null 2>&1; then
                log_notify_event "INFO" "Slack webhook delivered successfully."
            else
                log_notify_event "ERROR" "Failed to deliver Slack webhook."
            fi
        elif [[ "$name" == "discord" ]]; then
            if curl -s -X POST -H 'Content-type: application/json' \
                --data "{\"content\":\"**[${level}] ${title}**: ${message}\"" \
                "$url" >/dev/null 2>&1; then
                log_notify_event "INFO" "Discord webhook delivered successfully."
            else
                log_notify_event "ERROR" "Failed to deliver Discord webhook."
            fi
        else
            local priority="default"
            [[ "$level" == "CRITICAL" || "$level" == "ERROR" ]] && priority="urgent"
            if curl -s \
                -H "Title: [${level}] ${title}" \
                -H "Priority: ${priority}" \
                -d "${message}" \
                "$url" >/dev/null 2>&1; then
                log_notify_event "INFO" "Webhook '${name}' delivered successfully."
            else
                log_notify_event "ERROR" "Failed to deliver webhook '${name}'."
            fi
        fi
    done
}

# Master dispatch wrapper function
send_notification() {
    local level="$1"
    local title="$2"
    local message="$3"

    log_notify_event "${level}" "Triggered notification '${title}': ${message}"

    send_smtp_alert "[${level}] ${title}" "$message"
    send_webhook_alerts "$title" "$message" "$level"
}

# Docbloc: Test function that loops over enabled channels and sends a test message
test_notifications() {
    print_banner "TESTING ENABLED NOTIFICATION CHANNELS"
    
    if [[ ! -f "$NOTIFICATIONS_JSON" ]]; then
        log_msg "ERROR" "Configuration file ${NOTIFICATIONS_JSON} not found."
        return 1
    }

    local test_title="Homelab Connectivity Test"
    local test_msg="This is a test notification dispatched from your homelab management utility."
    local active_count=0

    # Check SMTP status
    local smtp_enabled
    smtp_enabled=$(jq -r '.smtp.enabled // false' "$NOTIFICATIONS_JSON")
    if [[ "$smtp_enabled" == "true" ]]; then
        echo -e "  -> Found enabled channel: ${COLOR_GREEN}SMTP Email${COLOR_RESET}"
        ((active_count++))
    fi

    # Check Webhooks status
    if command -v jq &>/dev/null; then
        local count
        count=$(jq '.webhooks | length' "$NOTIFICATIONS_JSON" 2>/dev/null || echo 0)
        for ((i=0; i<count; i++)); do
            local name enabled
            name=$(jq -r ".webhooks[$i].name // \"webhook-$i\"" "$NOTIFICATIONS_JSON")
            enabled=$(jq -r ".webhooks[$i].enabled // false" "$NOTIFICATIONS_JSON")
            if [[ "$enabled" == "true" ]]; then
                echo -e "  -> Found enabled channel: ${COLOR_GREEN}Webhook (${name})${COLOR_RESET}"
                ((active_count++))
            fi
        done
    fi

    if (( active_count == 0 )); then
        echo -e "${COLOR_ORANGE}No notification channels are currently enabled in ${NOTIFICATIONS_JSON}.${COLOR_RESET}"
        return 0
    fi

    echo -e "\nDispatching test messages to all ${active_count} active channel(s)...\n"
    send_notification "INFO" "$test_title" "$test_msg"
    echo -e "${COLOR_GREEN}Test broadcast complete. Check your logs at ${CUSTOM_LOG_FILE}.${COLOR_RESET}\n"
}

# Execution handler
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "${1:-}" == "--test" ]]; then
        test_notifications
    else
        send_notification "INFO" "Homelab Notice" "Notification script executed."
    fi
fi
