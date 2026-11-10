#!/usr/bin/env bash
# ==============================================================================
# Script: disk-manager.sh
# Description: Disk Operations, Partitioning, LUKS Encryption & Fstab Suite
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_JSON="${SCRIPT_DIR}/config.json"
BACKUP_DIR="/config/storage"
KEY_BACKUP_DIR="/config/storage/keys"

if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
    source "${SCRIPT_DIR}/lib.sh"
else
    echo "ERROR: Shared library lib.sh missing!" >&2
    exit 1
fi

check_root
check_dependency "lsblk"
check_dependency "findmnt"
check_dependency "cryptsetup"

# Docbloc: Backup active /etc/fstab and crypttab to /config/storage
backup_storage_configs() {
    local timestamp dest
    timestamp=$(date +%Y%m%d_%H%M%S)
    dest="${BACKUP_DIR}/storage_backup_${timestamp}"

    mkdir -p "${dest}"
    [[ -f /etc/fstab ]] && cp /etc/fstab "${dest}/fstab.bak"
    [[ -f /etc/crypttab ]] && cp /etc/crypttab "${dest}/crypttab.bak" 2>/dev/null || true

    log_msg "INFO" "Storage configurations (fstab/crypttab) backed up to ${dest}"
}

# Docbloc: Display summary box with warnings and prompt for user confirmation
# Arguments: $1 = Action Name, $2 = Target Device, $3 = Change Summary, $4 = Is Destructive (true/false)
confirm_action() {
    local action="$1"
    local target="$2"
    local summary="$3"
    local is_destructive="${4:-false}"

    echo -e "\n${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}                         ACTION CONFIRMATION & SUMMARY                          ${COLOR_RESET}"
    echo -e "${COLOR_ORANGE}================================================================================${COLOR_RESET}"
    printf "%-20s : %s\n" "Requested Action" "${action}"
    printf "%-20s : %s\n" "Target Device/Path" "${target}"
    printf "%-20s : %s\n" "Summary of Changes" "${summary}"
    
    if [[ "$is_destructive" == "true" ]]; then
        echo -e "${COLOR_RED}WARNING: THIS IS A DESTRUCTIVE OPERATION! DATA ON ${target} MAY BE PERMANENTLY ERASED.${COLOR_RESET}"
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

# Docbloc: Display clean overview of physical block devices, LUKS mappings, and partitions
show_disk_overview() {
    print_banner "SYSTEM DISK & PARTITION OVERVIEW"

    printf "%-14s %-20s %-10s %-8s %-10s %-22s\n" "Device" "Model/Label" "Size" "Type" "FS Type" "Mount Point"
    echo "----------------------------------------------------------------------------------------------------"

    local json_data
    json_data=$(lsblk -J -o NAME,MODEL,LABEL,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null || echo "")

    if [[ -n "$json_data" ]]; then
        python3 - <<EOF
import json, sys

data = json.loads('''${json_data}''')
devices = data.get('blockdevices', [])

def print_dev(dev, indent=""):
    name = "/dev/" + dev.get('name', '')
    model = dev.get('model') or dev.get('label') or "N/A"
    size = dev.get('size', 'N/A')
    dtype = dev.get('type', 'N/A')
    fstype = dev.get('fstype') or "N/A"
    mp = dev.get('mountpoint') or "Unmounted"
    
    print(f"{indent}{name:<14} {model[:19]:<20} {size:<10} {dtype:<8} {fstype:<10} {mp:<22}")
    
    for child in dev.get('children', []):
        print_dev(child, indent="  ├─ ")

for d in devices:
    print_dev(d)
EOF
    else
        lsblk -o NAME,MODEL,SIZE,TYPE,FSTYPE,MOUNTPOINT
    fi
    echo ""
}

# Docbloc: Mount partition to specified destination
mount_disk() {
    print_banner "MOUNT DISK / PARTITION"
    show_disk_overview

    read -rp "Enter partition device path (e.g. /dev/sdb1 or /dev/mapper/storage): " PART_DEV
    validate_string "$PART_DEV" "partition device" || return 1

    if [[ ! -b "$PART_DEV" ]]; then
        log_msg "ERROR" "Device '${PART_DEV}' does not exist."
        return 1
    fi

    read -rp "Enter target mount directory (e.g. /mnt/storage): " TARGET_DIR
    validate_string "$TARGET_DIR" "mount point" || return 1

    confirm_action "Mount Device" "$PART_DEV" "Mount device $PART_DEV to filesystem location $TARGET_DIR" "false" || return 0

    mkdir -p "$TARGET_DIR"
    log_msg "INFO" "Mounting ${PART_DEV} to ${TARGET_DIR}..."
    mount "$PART_DEV" "$TARGET_DIR"
    log_msg "INFO" "Successfully mounted ${PART_DEV} to ${TARGET_DIR}."
}

# Docbloc: Unmount partition or filesystem
unmount_disk() {
    print_banner "UNMOUNT DISK / PARTITION"
    show_disk_overview

    read -rp "Enter partition device path or mount point to unmount: " TARGET
    validate_string "$TARGET" "target" || return 1

    confirm_action "Unmount Device" "$TARGET" "Detach active filesystem mount at $TARGET" "false" || return 0

    log_msg "INFO" "Unmounting ${TARGET}..."
    umount "$TARGET"
    log_msg "INFO" "Successfully unmounted ${TARGET}."
}

# Docbloc: Partition disk interactively using fdisk
partition_disk() {
    print_banner "PARTITION DISK"
    show_disk_overview

    read -rp "Enter physical disk device to partition (e.g. /dev/sdb): " DISK_DEV
    validate_string "$DISK_DEV" "disk device" || return 1

    if [[ ! -b "$DISK_DEV" ]]; then
        log_msg "ERROR" "Device '${DISK_DEV}' is not a valid block device."
        return 1
    fi

    confirm_action "Partition Drive" "$DISK_DEV" "Launch fdisk tool to create/modify partition table layout on $DISK_DEV" "true" || return 0

    backup_storage_configs
    fdisk "$DISK_DEV"
    partprobe "$DISK_DEV" || true
    log_msg "INFO" "Partition table updated on ${DISK_DEV}."
}

# Docbloc: Format partition and change filesystem (ext4, btrfs, xfs, vfat)
format_disk() {
    print_banner "FORMAT DISK / CHANGE FILESYSTEM"
    show_disk_overview

    read -rp "Enter partition device path to format (e.g. /dev/sdb1): " PART_DEV
    validate_string "$PART_DEV" "partition device" || return 1

    if [[ ! -b "$PART_DEV" ]]; then
        log_msg "ERROR" "Device '${PART_DEV}' does not exist."
        return 1
    fi

    echo "Select Filesystem Type:"
    echo "1) ext4"
    echo "2) btrfs"
    echo "3) xfs"
    echo "4) vfat (FAT32)"
    read -rp "Select Choice [1-4]: " FS_CHOICE

    local fs_cmd="" fs_type=""
    case "$FS_CHOICE" in
        1) fs_cmd="mkfs.ext4 -F"; fs_type="ext4" ;;
        2) fs_cmd="mkfs.btrfs -f"; fs_type="btrfs" ;;
        3) fs_cmd="mkfs.xfs -f"; fs_type="xfs" ;;
        4) fs_cmd="mkfs.vfat -F 32"; fs_type="vfat (FAT32)" ;;
        *) log_msg "ERROR" "Invalid filesystem selection."; return 1 ;;
    esac

    confirm_action "Format Filesystem" "$PART_DEV" "Format partition $PART_DEV with new $fs_type filesystem" "true" || return 0

    backup_storage_configs
    log_msg "INFO" "Formatting ${PART_DEV} with ${fs_type}..."
    $fs_cmd "$PART_DEV"
    log_msg "INFO" "Format complete on ${PART_DEV}."
}

# Docbloc: Encrypt entire physical drive (Full Disk Encryption)
encrypt_full_disk() {
    print_banner "FULL DISK ENCRYPTION (LUKS)"
    show_disk_overview

    read -rp "Enter raw disk device path to encrypt (e.g. /dev/sdb or /dev/nvme1n1): " DISK_DEV
    validate_string "$DISK_DEV" "disk device" || return 1

    if [[ ! -b "$DISK_DEV" ]]; then
        log_msg "ERROR" "Device '${DISK_DEV}' does not exist or is not a block device."
        return 1
    fi

    confirm_action "Full Disk LUKS Encryption" "$DISK_DEV" "Wipe partition table and format entire raw drive $DISK_DEV as LUKS2 encrypted volume" "true" || return 0

    backup_storage_configs
    log_msg "INFO" "Initializing LUKS container on full disk ${DISK_DEV}..."
    cryptsetup luksFormat --type luks2 "$DISK_DEV"
    log_msg "INFO" "Full disk ${DISK_DEV} successfully encrypted."
}

# Docbloc: Encrypt partition device (Partition Encryption)
encrypt_partition() {
    print_banner "LUKS ENCRYPT PARTITION"
    show_disk_overview

    read -rp "Enter partition device path to encrypt (e.g. /dev/sdb1): " PART_DEV
    validate_string "$PART_DEV" "partition device" || return 1

    if [[ ! -b "$PART_DEV" ]]; then
        log_msg "ERROR" "Device '${PART_DEV}' does not exist."
        return 1
    fi

    confirm_action "Partition LUKS Encryption" "$PART_DEV" "Overwrites partition header on $PART_DEV with a LUKS container" "true" || return 0

    backup_storage_configs
    log_msg "INFO" "Initializing LUKS container on ${PART_DEV}..."
    cryptsetup luksFormat "$PART_DEV"
    log_msg "INFO" "LUKS container formatted on ${PART_DEV}."
}

# Docbloc: Change passphrase for an existing LUKS container
change_luks_password() {
    print_banner "CHANGE LUKS ENCRYPTED DRIVE PASSWORD"
    show_disk_overview

    read -rp "Enter LUKS encrypted device path (e.g. /dev/sdb1 or /dev/sdb): " TARGET_DEV
    validate_string "$TARGET_DEV" "LUKS device" || return 1

    if ! cryptsetup isLuks "$TARGET_DEV" &>/dev/null; then
        log_msg "ERROR" "Device '${TARGET_DEV}' is not a valid LUKS container."
        return 1
    fi

    confirm_action "Change LUKS Passphrase" "$TARGET_DEV" "Update decryption passphrase keyslot on $TARGET_DEV" "false" || return 0

    log_msg "INFO" "Prompting for LUKS key modification on ${TARGET_DEV}..."
    if cryptsetup luksChangeKey "$TARGET_DEV"; then
        log_msg "INFO" "LUKS passphrase successfully updated for ${TARGET_DEV}."
    else
        log_msg "ERROR" "Failed to update LUKS passphrase."
    fi
}

# Docbloc: Decrypt and open LUKS device mapping
decrypt_disk() {
    print_banner "LUKS DECRYPT & OPEN DISK"
    show_disk_overview

    read -rp "Enter encrypted partition path (e.g. /dev/sdb1): " PART_DEV
    read -rp "Enter target mapped name (e.g. storage_encrypted): " MAP_NAME
    validate_string "$PART_DEV" "partition device" || return 1
    validate_string "$MAP_NAME" "mapped name" || return 1

    confirm_action "Decrypt / Open LUKS Container" "$PART_DEV" "Unlock encrypted drive $PART_DEV and map to /dev/mapper/$MAP_NAME" "false" || return 0

    log_msg "INFO" "Opening LUKS container ${PART_DEV} as /dev/mapper/${MAP_NAME}..."
    cryptsetup luksOpen "$PART_DEV" "$MAP_NAME"
    log_msg "INFO" "Device unlocked successfully at /dev/mapper/${MAP_NAME}."
}

# Docbloc: Backup LUKS headers and keyfiles to /config/storage/keys/
backup_storage_keys() {
    print_banner "BACKUP LUKS HEADERS & KEY FILES"
    local timestamp dest
    timestamp=$(date +%Y%m%d_%H%M%S)
    dest="${KEY_BACKUP_DIR}/keys_backup_${timestamp}"

    confirm_action "Backup LUKS Keys & Headers" "System LUKS Volumes" "Backup LUKS binary headers to $dest" "false" || return 0

    mkdir -p "${dest}"
    chmod 700 "${dest}"

    log_msg "INFO" "Scanning system for active LUKS volumes..."
    local luks_devs
    luks_devs=$(lsblk -pno NAME,FSTYPE | awk '$2=="crypto_LUKS" {print $1}')

    if [[ -z "$luks_devs" ]]; then
        log_msg "WARN" "No active LUKS devices found on this system."
    else
        for dev in $luks_devs; do
            local clean_name
            clean_name=$(echo "$dev" | tr '/' '_')
            local header_bak="${dest}/luks_header${clean_name}.img"
            
            log_msg "INFO" "Backing up LUKS header for ${dev}..."
            cryptsetup luksHeaderBackup "$dev" --header-backup-file "$header_bak"
        done
    fi

    if [[ -d /etc/luks ]]; then
        log_msg "INFO" "Backing up keyfiles in /etc/luks..."
        cp -r /etc/luks "${dest}/etc_luks_keys"
    fi

    chmod -R 600 "${dest}"/* 2>/dev/null || true
    log_msg "INFO" "All LUKS storage headers and keyfiles backed up to ${dest}"
}

# Docbloc: Audit space usage on mounted filesystems
check_disk_usage() {
    print_banner "DISK SPACE & USAGE AUDIT"
    df -h -x tmpfs -x devtmpfs -x squashfs
    echo ""
}

# Docbloc: Run SMART Health Checks on raw disks
check_smart_health() {
    print_banner "SMART DRIVE HEALTH AUDIT"
    if ! command -v smartctl &>/dev/null; then
        log_msg "WARN" "smartctl tool missing. Install smartmontools package."
        return 1
    fi

    local drives
    drives=$(lsblk -dno NAME,TYPE | awk '$2=="disk" {print $1}')

    for dev in $drives; do
        local health
        health=$(smartctl -H "/dev/${dev}" 2>/dev/null | grep -E "test result|SMART Health Status" || echo "SMART status unavailable")
        echo -e "${COLOR_GREEN}/dev/${dev}${COLOR_RESET}: ${health}"
    done
    echo ""
}

# Docbloc: Add partition UUID entry to /etc/fstab for automatic mounting
add_to_fstab() {
    print_banner "ADD ENTRY TO FSTAB"
    show_disk_overview

    read -rp "Enter partition device path (e.g. /dev/sdb1): " PART_DEV
    validate_string "$PART_DEV" "partition device" || return 1

    if [[ ! -b "$PART_DEV" ]]; then
        log_msg "ERROR" "Device '${PART_DEV}' does not exist."
        return 1
    fi

    local uuid fstype
    uuid=$(blkid -s UUID -o value "$PART_DEV" || echo "")
    fstype=$(blkid -s TYPE -o value "$PART_DEV" || echo "")

    if [[ -z "$uuid" ]]; then
        log_msg "ERROR" "Could not determine UUID for ${PART_DEV}. Ensure drive is formatted."
        return 1
    fi

    read -rp "Enter mount point directory (e.g. /mnt/storage): " MOUNT_POINT
    validate_string "$MOUNT_POINT" "mount point" || return 1
    mkdir -p "$MOUNT_POINT"

    read -rp "Enter mount options [default: defaults,noatime]: " MOUNT_OPTS
    MOUNT_OPTS="${MOUNT_OPTS:-defaults,noatime}"

    local fstab_entry="UUID=${uuid}  ${MOUNT_POINT}  ${fstype:-ext4}  ${MOUNT_OPTS}  0  2"

    if grep -qs "$uuid" /etc/fstab; then
        log_msg "WARN" "UUID ${uuid} is already present in /etc/fstab."
        return 0
    fi

    confirm_action "Add fstab Entry" "/etc/fstab" "Append entry: '$fstab_entry'" "false" || return 0

    backup_storage_configs
    echo "$fstab_entry" >> /etc/fstab
    log_msg "INFO" "Added entry to /etc/fstab:"
    echo "  ${fstab_entry}"
    
    log_msg "INFO" "Testing /etc/fstab entries with mount -a..."
    mount -a
}

# Docbloc: Main Menu Loop
main_menu() {
    while true; do
        show_disk_overview
        print_banner "DISK MANAGER MENU"
        echo "1) Refresh Disk Overview"
        echo "2) Mount Disk / Partition"
        echo "3) Unmount Disk / Partition"
        echo "4) Partition Disk (fdisk)"
        echo "5) Format Disk / Change Filesystem"
        echo "6) Encrypt Full Disk (LUKS)"
        echo "7) Encrypt Partition (LUKS)"
        echo "8) Change Encrypted Drive Password"
        echo "9) Decrypt Disk"
        echo "10) Backup LUKS Storage Keys & Headers"
        echo "11) Disk Space Usage Audit (df -h)"
        echo "12) Run SMART Health Checks"
        echo "13) Add Partition Entry to /etc/fstab"
        echo "14) Backup Storage Configurations (fstab/crypttab)"
        echo "15) Exit"
        read -rp "Select Option [1-15]: " CHOICE

        case "$CHOICE" in
            1) clear ;;
            2) mount_disk ;;
            3) unmount_disk ;;
            4) partition_disk ;;
            5) format_disk ;;
            6) encrypt_full_disk ;;
            7) encrypt_partition ;;
            8) change_luks_password ;;
            9) decrypt_disk ;;
            10) backup_storage_keys ;;
            11) check_disk_usage ;;
            12) check_smart_health ;;
            13) add_to_fstab ;;
            14) backup_storage_configs ;;
            15) log_msg "INFO" "Exiting Disk Manager."; exit 0 ;;
            *) log_msg "ERROR" "Invalid option." ;;
        esac
    done
}

main_menu