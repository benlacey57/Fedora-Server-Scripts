#!/usr/bin/env bash
# ==============================================================================
# File: lib.sh
# Description: Unified Core Shared Library for System Setup & Maintenance
# ==============================================================================

set -euo pipefail

# --- Color Definitions ---
export COLOR_RED='\033[0;31m'
export COLOR_ORANGE='\033[0;33m'
export COLOR_GREEN='\033[0;32m'
export COLOR_CYAN='\033[0;36m'
export COLOR_BLUE='\033[0;34m'
export COLOR_RESET='\033[0m'

# --- Log Settings ---
export LOG_FILE="/var/log/homelab_setup.log"

# Docbloc: Display standardized header banner
# Arguments: $1 = Title text
print_banner() {
    local title="$1"
    echo -e "${COLOR_CYAN}================================================================================${COLOR_RESET}"
    echo -e "${COLOR_CYAN}  ${title}${COLOR_RESET}"
    echo -e "${COLOR_CYAN}================================================================================${COLOR_RESET}"
}

# Docbloc: Log messages with ANSI color output to console and clean output to file
# Arguments: $1 = Level (INFO|WARN|ERROR), $2 = Message
log_msg() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    case "$level" in
        "INFO")  echo -e "${COLOR_GREEN}[+] ${msg}${COLOR_RESET}" ;;
        "WARN")  echo -e "${COLOR_ORANGE}[!] ${msg}${COLOR_RESET}" ;;
        "ERROR") echo -e "${COLOR_RED}[ERROR] ${msg}${COLOR_RESET}" >&2 ;;
    esac

    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
}

# Docbloc: Enforce root/sudo privilege check
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_msg "ERROR" "This script must be executed as root (e.g. using sudo)."
        exit 1
    fi
}

# Docbloc: Check if a dependency binary is installed
# Arguments: $1 = Binary name
check_dependency() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        log_msg "ERROR" "Required dependency '$cmd' is missing."
        return 1
    fi
}

# Docbloc: Input Validation - Validate String alphanumeric with underscores/hyphens
# Arguments: $1 = Value, $2 = Field Name
validate_string() {
    local val="$1"
    local field="$2"
    if ! [[ "$val" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_msg "ERROR" "Invalid ${field}: Must contain only letters, numbers, hyphens, or underscores."
        return 1
    fi
    return 0
}

# Docbloc: Input Validation - Validate numeric Port range
# Arguments: $1 = Port
validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_msg "ERROR" "Invalid port '${port}': Must be an integer between 1 and 65535."
        return 1
    fi
    return 0
}

# Docbloc: Read JSON property via jq
# Arguments: $1 = JSON file path, $2 = jq filter string
read_json_config() {
    local json_file="$1"
    local query="$2"
    if [[ ! -f "$json_file" ]]; then
        log_msg "ERROR" "Configuration file not found: ${json_file}"
        return 1
    fi
    jq -r "$query" "$json_file"
}

# Docbloc: Normalize storage sizes (MB/GB) into Docker daemon format (e.g. 100m, 1g)
format_docker_log_size() {
    local raw_input="$1"
    local default_value="${2:-50m}"

    # Remove whitespace and convert to lowercase
    local clean_input
    clean_input=$(echo "$raw_input" | tr -d ' ' | tr '[:upper:]' '[:lower:]')

    if [[ "$clean_input" =~ ^([0-9]+)(gb|g)$ ]]; then
        echo "${BASH_REMATCH[1]}g"
    elif [[ "$clean_input" =~ ^([0-9]+)(mb|m)$ ]]; then
        echo "${BASH_REMATCH[1]}m"
    elif [[ "$clean_input" =~ ^[0-9]+$ ]]; then
        # Default numeric-only entries to MB
        echo "${clean_input}m"
    else
        log_msg "WARN" "Invalid log size format '${raw_input}'. Defaulting to ${default_value}."
        echo "$default_value"
    fi
}
