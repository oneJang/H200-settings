#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/90-common.sh"

require_command helm
require_command kubectl

PURGE_DATA=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge-data) PURGE_DATA=true; shift ;;
        *) fatal "Unknown option: $1" ;;
    esac
done

NS="$(helm_release_namespace harbor 2>/dev/null || true)"

if [[ -z "${NS}" ]]; then
    NS="$(resource_namespaces deployment harbor-core 2>/dev/null | head -n1 || true)"
fi

if [[ -z "${NS}" ]]; then
    log "Harbor installation not found"
    exit 0
fi

log "Uninstalling Harbor from namespace: ${NS}"

if [[ "${PURGE_DATA}" != "true" ]]; then
    log "Preserving Harbor PVCs"
    preserve_namespace_pvcs "${NS}"
fi

if helm status harbor -n "${NS}" >/dev/null 2>&1; then
    helm uninstall harbor -n "${NS}" || true
else
    warn "Harbor Helm release not found; deleting common Harbor workloads by app.kubernetes.io/instance=harbor."
    kubectl delete all,configmap,secret,serviceaccount,role,rolebinding \
        -n "${NS}" -l app.kubernetes.io/instance=harbor \
        --ignore-not-found=true --wait=false 2>/dev/null || true
fi

# Secret name used by our installer; harmless if a different one was used.
kubectl delete secret harbor-admin-password -n "${NS}" --ignore-not-found=true 2>/dev/null || true

if [[ "${PURGE_DATA}" == "true" ]]; then
    warn "PURGE DATA enabled: deleting Harbor PVCs and namespace."
    kubectl delete pvc --all -n "${NS}" --ignore-not-found=true || true
    safe_delete_namespace "${NS}"
else
    echo "Harbor data preserved. Namespace/PVCs remain: ${NS}"
fi

log "Harbor uninstall completed"
