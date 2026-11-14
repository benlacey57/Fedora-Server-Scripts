#!/usr/bin/env bash
# ==============================================================================
# Script: package-manager.sh
# Description: System Package Verification, Pip Module Manager & Audit Suite
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_JSON="${SCRIPT_DIR}/../config.json"
BACKUP_DIR="/config/packages"

if [[ -f "${SCRIPT_DIR}/../lib.sh" ]]; then
    source "${SCRIPT_DIR}/../lib.sh"
elif [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root
check_dependency "jq"

# --- OS Detection ---
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
else
    log_msg "ERROR" "Cannot detect operating system via /etc/os-release."
    exit 1
fi

# Docbloc: Backup active package lists to /config/packages
backup_package_state() {
    local timestamp dest
    timestamp=$(date +%Y%m%d_%H%M%S)
    dest="${BACKUP_DIR}/packages_backup_${timestamp}"

    mkdir -p "${dest}"
    log_msg "INFO" "Backing up installed package lists to ${dest}..."

    if [[ "$OS_ID" == "fedora" || "$OS_LIKE" =~ "fedora" || "$OS_LIKE" =~ "rhel" ]]; then
        dnf list installed > "${dest}/dnf_installed_packages.txt" 2>/dev/null || true
    elif [[ "$OS_ID" == "ubuntu" || "$OS_LIKE" =~ "ubuntu" || "$OS_LIKE" =~ "debian" ]]; then
        dpkg --get-selections > "${dest}/dpkg_installed_packages.txt" 2>/dev/null || true
    fi

    if command -v pip3 &>/dev/null; then
        pip3 list > "${dest}/pip3_installed_packages.txt" 2>/dev/null || true
    fi

    log_msg "INFO" "Package state successfully backed up."
}

# Docbloc: Action confirmation prompt with change summary and destructive warnings
confirm_action() {
    local action="$1"
    local target="$2"
    local summary="$3"
    local is_destructive="${4:-false}"

    echo -e "\n${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}                         ACTION CONFIRMATION & SUMMARY                          ${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    printf "%-20s : %s\n" "Requested Action" "${action}"
    printf "%-20s : %s\n" "Target Package(s)" "${target}"
    printf "%-20s : %s\n" "Summary of Changes" "${summary}"

    if [[ "$is_destructive" == "true" ]]; then
        echo -e "${COLOR_RED}WARNING: THIS MODIFIES INSTALLED SYSTEM PACKAGES OR PYTHON MODULES!${COLOR_RESET}"
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

# Docbloc: Audit system packages against definitions in config.json
audit_system_packages() {
    print_banner "SYSTEM PACKAGE AUDIT (${OS_ID^^})"

    if [[ ! -f "$CONFIG_JSON" ]]; then
        log_msg "ERROR" "Configuration file ${CONFIG_JSON} not found."
        return 1
    fi

    log_msg "INFO" "Auditing configured packages from ${CONFIG_JSON}..."
    local pkgs
    pkgs=$(read_json_config "$CONFIG_JSON" '.packages[]' 2>/dev/null || echo "")

    if [[ -z "$pkgs" ]]; then
        log_msg "WARN" "No package definitions found under '.packages' in config.json."
        return 0
    fi

    printf "%-25s %-15s %-20s\n" "Package Name" "Status" "Binary Check"
    echo "--------------------------------------------------------------------------------"

    local missing_pkgs=()
    for pkg in $pkgs; do
        local installed="No" bin_status="N/A"

        if [[ "$OS_ID" == "fedora" || "$OS_LIKE" =~ "fedora" || "$OS_LIKE" =~ "rhel" ]]; then
            rpm -q "$pkg" &>/dev/null && installed="Yes"
        elif [[ "$OS_ID" == "ubuntu" || "$OS_LIKE" =~ "ubuntu" || "$OS_LIKE" =~ "debian" ]]; then
            dpkg -s "$pkg" &>/dev/null && installed="Yes"
        fi

        if command -v "$pkg" &>/dev/null; then
            bin_status="Executable"
        fi

        if [[ "$installed" == "Yes" ]]; then
            printf "${COLOR_GREEN}%-25s %-15s %-20s${COLOR_RESET}\n" "$pkg" "Installed" "$bin_status"
        else
            printf "${COLOR_RED}%-25s %-15s %-20s${COLOR_RESET}\n" "$pkg" "Missing" "$bin_status"
            missing_pkgs+=("$pkg")
        fi
    done
    echo ""

    if (( ${#missing_pkgs[@]} > 0 )); then
        log_msg "WARN" "Missing configured packages: ${missing_pkgs[*]}"
    else
        log_msg "INFO" "All packages in config.json are installed."
    fi
}

# Docbloc: Install missing system packages listed in config.json
install_missing_packages() {
    print_banner "INSTALL CONFIGURED SYSTEM PACKAGES"

    local pkgs
    pkgs=$(read_json_config "$CONFIG_JSON" '.packages[]' 2>/dev/null || echo "")

    if [[ -z "$pkgs" ]]; then
        log_msg "WARN" "No packages defined in config.json."
        return 0
    fi

    local to_install=()
    for pkg in $pkgs; do
        if [[ "$OS_ID" == "fedora" || "$OS_LIKE" =~ "fedora" ]]; then
            rpm -q "$pkg" &>/dev/null || to_install+=("$pkg")
        elif [[ "$OS_ID" == "ubuntu" || "$OS_LIKE" =~ "ubuntu" ]]; then
            dpkg -s "$pkg" &>/dev/null || to_install+=("$pkg")
        fi
    done

    if (( ${#to_install[@]} == 0 )); then
        log_msg "INFO" "All system packages are already installed."
        return 0
    fi

    confirm_action "Install System Packages" "${to_install[*]}" "Install missing system packages via default package manager" "false" || return 0

    backup_package_state

    log_msg "INFO" "Installing packages: ${to_install[*]}..."
    if [[ "$OS_ID" == "fedora" || "$OS_LIKE" =~ "fedora" ]]; then
        dnf install -y "${to_install[@]}"
    elif [[ "$OS_ID" == "ubuntu" || "$OS_LIKE" =~ "ubuntu" ]]; then
        apt-get update -qq && apt-get install -y "${to_install[@]}"
    fi

    log_msg "INFO" "Package installation completed."
}

# Docbloc: Audit and install configured Python PIP packages
manage_pip_packages() {
    print_banner "PYTHON PIP PACKAGES MANAGEMENT"

    if ! command -v pip3 &>/dev/null; then
        log_msg "ERROR" "pip3 is not installed on this system."
        return 1
    fi

    local pip_pkgs
    pip_pkgs=$(read_json_config "$CONFIG_JSON" '.pip_packages[]' 2>/dev/null || echo "")

    if [[ -z "$pip_pkgs" ]]; then
        log_msg "WARN" "No pip packages defined under '.pip_packages' in config.json."
        return 0
    fi

    printf "%-25s %-15s\n" "Pip Module" "Status"
    echo "----------------------------------------"

    local missing_pip=()
    for mod in $pip_pkgs; do
        if python3 -c "import $mod" &>/dev/null; then
            printf "${COLOR_GREEN}%-25s %-15s${COLOR_RESET}\n" "$mod" "Installed"
        else
            printf "${COLOR_RED}%-25s %-15s${COLOR_RESET}\n" "$mod" "Missing"
            missing_pip+=("$mod")
        fi
    done
    echo ""

    if (( ${#missing_pip[@]} > 0 )); then
        log_msg "WARN" "Missing Python modules: ${missing_pip[*]}"
        confirm_action "Install Pip Packages" "${missing_pip[*]}" "Install missing Python packages via pip3" "false" || return 0

        backup_package_state
        log_msg "INFO" "Installing missing pip packages..."
        pip3 install "${missing_pip[@]}"
        log_msg "INFO" "Pip packages installed."
    else
        log_msg "INFO" "All configured Python modules are installed."
    fi
}

# Docbloc: Run full system package upgrade
upgrade_system_packages() {
    print_banner "UPGRADE ALL SYSTEM PACKAGES"

    confirm_action "System Package Upgrade" "All Packages" "Run full upgrade of all installed system packages" "true" || return 0

    backup_package_state

    log_msg "INFO" "Starting system upgrade..."
    if [[ "$OS_ID" == "fedora" || "$OS_LIKE" =~ "fedora" ]]; then
        dnf upgrade -y --refresh
    elif [[ "$OS_ID" == "ubuntu" || "$OS_LIKE" =~ "ubuntu" ]]; then
        apt-get update -qq && apt-get dist-upgrade -y
    fi

    log_msg "INFO" "System upgrade complete."
}

# Docbloc: Main Menu Loop
main_menu() {
    while true; do
        print_banner "PACKAGE MANAGER MENU"
        echo "1) Audit System Packages against config.json"
        echo "2) Install Missing Configured Packages"
        echo "3) Manage Python Pip Packages"
        echo "4) Run Full System Package Upgrade"
        echo "5) Backup Active Package Lists"
        echo "6) Exit"
        read -rp "Select Option [1-6]: " CHOICE

        case "$CHOICE" in
            1) audit_system_packages ;;
            2) install_missing_packages ;;
            3) manage_pip_packages ;;
            4) upgrade_system_packages ;;
            5) backup_package_state ;;
            6) log_msg "INFO" "Exiting Package Manager."; exit 0 ;;
            *) log_msg "ERROR" "Invalid choice." ;;
        esac
    done
}

main_menu
