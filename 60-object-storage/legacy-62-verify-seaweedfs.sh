#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/object-storage.env"

require_command kubectl

log "SeaweedFS pods"

kubectl get pods \
    -n "${SEAWEEDFS_NAMESPACE}" \
    -o wide


log "SeaweedFS services"

kubectl get svc \
    -n "${SEAWEEDFS_NAMESPACE}"


log "SeaweedFS PVCs"

kubectl get pvc \
    -n "${SEAWEEDFS_NAMESPACE}"


log "SeaweedFS endpoints"

kubectl get endpoints \
    -n "${SEAWEEDFS_NAMESPACE}"


log "Checking S3 service"

kubectl get svc \
    -n "${SEAWEEDFS_NAMESPACE}" \
    | grep -i s3 \
    || fatal "SeaweedFS S3 service not found."


log "Pods not Running / Completed"

NON_READY="$(
    kubectl get pods \
        -n "${SEAWEEDFS_NAMESPACE}" \
        --no-headers \
        | awk '
            $4 != "Running" &&
            $4 != "Completed" {
                print
            }
        '
)"

if [[ -n "${NON_READY}" ]]; then

    warn "Some SeaweedFS pods are not ready"

    echo "${NON_READY}"

else

    echo "All SeaweedFS pods are Running or Completed."

fi


log "SeaweedFS verification completed"
