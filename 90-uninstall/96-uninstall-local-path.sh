#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/90-common.sh"

require_command helm
require_command kubectl

NS="$(helm_release_namespace local-path-provisioner 2>/dev/null || true)"
[[ -n "${NS}" ]] || NS="local-path-storage"

# Warn before removing the provisioner if PVs still reference its SC.
PV_COUNT="$(kubectl get pv -o jsonpath='{range .items[?(@.spec.storageClassName=="local-path")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk 'NF' | wc -l | tr -d ' ')"
if [[ "${PV_COUNT}" != "0" ]]; then
    warn "${PV_COUNT} PV(s) still use StorageClass local-path. PV/data are not deleted by this script."
fi

if helm status local-path-provisioner -n "${NS}" >/dev/null 2>&1; then
    helm uninstall local-path-provisioner -n "${NS}" || true
fi

safe_delete_namespace "${NS}"
kubectl delete storageclass local-path --ignore-not-found=true || true

log "Local Path Provisioner uninstall completed"
