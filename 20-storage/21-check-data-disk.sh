#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/cluster.env"

log "Block devices"
lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS

log "Filesystems"
df -hT

log "Configured data directory"
echo "${DATA_DIR}"

if mountpoint -q "${DATA_DIR}" 2>/dev/null; then
    echo "${DATA_DIR} is a dedicated mount point."
else
    warn "${DATA_DIR} is not a dedicated mount point."
    warn "This is acceptable for the test VM, but the real H200 should use dedicated storage."
fi
