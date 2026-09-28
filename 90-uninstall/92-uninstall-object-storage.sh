#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/90-common.sh"

require_command kubectl
require_command helm

PURGE_DATA=false
NAMESPACE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge-data)
            PURGE_DATA=true
            shift
            ;;
        --namespace)
            [[ $# -ge 2 ]] || fatal "--namespace requires a value"
            NAMESPACE_OVERRIDE="$2"
            shift 2
            ;;
        *)
            fatal "Unknown option: $1"
            ;;
    esac
done

# Discover namespaces from live cluster state instead of config files.
CANDIDATES=""
if [[ -n "${NAMESPACE_OVERRIDE}" ]]; then
    CANDIDATES="${NAMESPACE_OVERRIDE}"
else
    CANDIDATES="$({
        helm_release_namespace seaweedfs 2>/dev/null || true
        helm_release_namespace minio 2>/dev/null || true
        resource_namespaces deployment minio 2>/dev/null || true
        resource_namespaces service minio 2>/dev/null || true
        resource_namespaces service seaweedfs-s3 2>/dev/null || true
        namespace_exists object-storage && echo object-storage || true
    } | unique_nonempty)"
fi

if [[ -z "${CANDIDATES}" ]]; then
    log "No MinIO/SeaweedFS installation found"
    exit 0
fi

while IFS= read -r ns; do
    [[ -n "${ns}" ]] || continue

    log "Uninstalling object storage from namespace: ${ns}"

    if [[ "${PURGE_DATA}" != "true" ]]; then
        log "Preserving PVCs in ${ns}"
        preserve_namespace_pvcs "${ns}"
    fi

    # Legacy SeaweedFS was installed as a Helm release.
    if helm status seaweedfs -n "${ns}" >/dev/null 2>&1; then
        log "Uninstalling legacy SeaweedFS Helm release"
        helm uninstall seaweedfs -n "${ns}" || true
    fi

    # Support a possible Helm-installed MinIO too, although our current
    # installer uses raw Kubernetes manifests.
    if helm status minio -n "${ns}" >/dev/null 2>&1; then
        log "Uninstalling MinIO Helm release"
        helm uninstall minio -n "${ns}" || true
    fi

    log "Removing MinIO resources created by 62-install-minio.sh"
    kubectl delete job minio-create-buckets -n "${ns}" --ignore-not-found=true || true
    kubectl delete deployment minio -n "${ns}" --ignore-not-found=true || true
    kubectl delete service minio minio-console -n "${ns}" --ignore-not-found=true || true
    kubectl delete secret minio-root-credentials -n "${ns}" --ignore-not-found=true || true

    # Legacy SeaweedFS credential secret from the previous implementation.
    kubectl delete secret seaweedfs-s3-credentials -n "${ns}" --ignore-not-found=true || true

    if [[ "${PURGE_DATA}" == "true" ]]; then
        warn "PURGE DATA enabled for namespace ${ns}."
        kubectl delete pvc --all -n "${ns}" --ignore-not-found=true || true
        safe_delete_namespace "${ns}"
    else
        echo "Data preserved. Namespace/PVCs are left in place: ${ns}"
    fi

done <<< "${CANDIDATES}"

log "Object storage uninstall completed"
