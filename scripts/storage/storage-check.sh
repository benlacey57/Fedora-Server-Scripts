#!/usr/bin/env bash
# ==============================================================================
# Script: storage-check.sh
# Description: Audits disk usage capacities, filesystem use %, and block topology
# ==============================================================================
set -euo pipefail

print_banner() {
    echo "=================================================================="
    echo "  $1"
    echo "=================================================================="
}

print_banner "STORAGE POOL & DISK USAGE"
df -h --output=target,fstype,size,used,avail,pcent | column -t

echo ""
print_banner "BLOCK DEVICES & PARTITION TOPOLOGY"
lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT
