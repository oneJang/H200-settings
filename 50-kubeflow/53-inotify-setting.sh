#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"

require_root

log "Configuring inotify limits for Kubeflow"

cat > /etc/sysctl.d/99-kubeflow.conf <<'EOF2'
fs.inotify.max_user_instances=2280
fs.inotify.max_user_watches=1255360
EOF2

sysctl --system

log "Verification"

sysctl fs.inotify.max_user_instances
sysctl fs.inotify.max_user_watches

log "Kubeflow host preparation completed"
