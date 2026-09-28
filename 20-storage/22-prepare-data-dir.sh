#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/cluster.env"

require_root

log "Creating data directories"

mkdir -p \
    "${LOCAL_PATH_DIR}" \
    "${HARBOR_DATA_DIR}" \
    "${OBJECT_STORAGE_DATA_DIR}" \
    "${DATASET_DIR}" \
    "${MODEL_DIR}" \
    "${CHECKPOINT_DIR}"

chmod 755 "${DATA_DIR}"

log "Directory structure"
find "${DATA_DIR}" -maxdepth 1 -mindepth 1 -type d -print

log "Disk usage"
df -hT "${DATA_DIR}"
