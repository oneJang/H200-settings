#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/90-common.sh"

require_command helm
require_command kubectl

NS="$(helm_release_namespace gpu-operator 2>/dev/null || true)"

if [[ -n "${NS}" ]]; then
    log "Uninstalling GPU Operator from namespace: ${NS}"
    helm uninstall gpu-operator -n "${NS}" || true
    safe_delete_namespace "${NS}"
elif namespace_exists gpu-operator; then
    warn "GPU Operator Helm release was not found, but namespace gpu-operator exists. Removing the namespace."
    safe_delete_namespace gpu-operator
else
    log "GPU Operator is not installed"
fi

log "GPU Operator uninstall completed"
