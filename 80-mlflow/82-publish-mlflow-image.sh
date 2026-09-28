#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/versions.env"
source "${ROOT_DIR}/config/mlflow.env"
source "${ROOT_DIR}/config/registry.env"

require_command sudo
require_command buildah
require_value MLFLOW_VERSION
require_value MLFLOW_IMAGE_NAME
require_value IMAGE_DISTRIBUTION_MODE

LOCAL_IMAGE="localhost/${MLFLOW_IMAGE_NAME}:${MLFLOW_VERSION}"

if ! sudo buildah images --format '{{.Name}}:{{.Tag}}' | grep -Fxq "${LOCAL_IMAGE}"; then
    fatal "MLflow image not found: ${LOCAL_IMAGE}. Run 81-prepare-mlflow.sh first."
fi

registry_authority() {
    local authority="${REGISTRY_HOST}"
    [[ -n "${REGISTRY_PORT:-}" ]] && authority="${authority}:${REGISTRY_PORT}"
    printf '%s' "${authority}"
}

registry_image_ref() {
    local authority prefix
    authority="$(registry_authority)"
    prefix="${REGISTRY_REPOSITORY_PREFIX#/}"
    prefix="${prefix%/}"
    if [[ -n "${prefix}" ]]; then
        printf '%s/%s/%s:%s' "${authority}" "${prefix}" "${MLFLOW_IMAGE_NAME}" "${MLFLOW_VERSION}"
    else
        printf '%s/%s:%s' "${authority}" "${MLFLOW_IMAGE_NAME}" "${MLFLOW_VERSION}"
    fi
}

case "${IMAGE_DISTRIBUTION_MODE}" in
local)
    require_command kubectl
    require_command ctr

    READY_NODES="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /^Ready/ && $2 !~ /SchedulingDisabled/ {c++} END {print c+0}')"
    [[ "${READY_NODES}" -eq 1 ]] || fatal "local mode requires exactly one Ready schedulable node; found ${READY_NODES}."

    NODE_NAME="$(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name | head -n1)"
    HOST_SHORT="$(hostname -s)"
    HOST_FULL="$(hostname)"
    if [[ "${NODE_NAME}" != "${HOST_SHORT}" && "${NODE_NAME}" != "${HOST_FULL}" ]]; then
        fatal "local mode must run on the Kubernetes node. node=${NODE_NAME}, host=${HOST_FULL}"
    fi

    TEMP_DIR="$(sudo mktemp -d /var/tmp/h200-mlflow-publish.XXXXXX)"
    ARCHIVE="${TEMP_DIR}/mlflow-image.tar"
    trap 'sudo rm -rf "${TEMP_DIR}" || true' EXIT

    log "Exporting MLflow image"
    sudo buildah push "${LOCAL_IMAGE}" "docker-archive:${ARCHIVE}:${LOCAL_IMAGE}"
    sudo test -s "${ARCHIVE}" || fatal "MLflow image archive was not created."

    if sudo ctr -n k8s.io images list -q | grep -Fxq "${LOCAL_IMAGE}"; then
        sudo ctr -n k8s.io images remove "${LOCAL_IMAGE}" >/dev/null
    fi

    log "Importing MLflow image into containerd k8s.io namespace"
    sudo ctr -n k8s.io images import "${ARCHIVE}"
    sudo ctr -n k8s.io images list -q | grep -Fxq "${LOCAL_IMAGE}" \
        || fatal "Image import verification failed: ${LOCAL_IMAGE}"
    ;;

registry)
    require_value REGISTRY_HOST
    require_value REGISTRY_TLS_VERIFY
    require_value REGISTRY_AUTH_REQUIRED

    AUTHORITY="$(registry_authority)"
    TARGET_IMAGE="$(registry_image_ref)"

    if [[ "${REGISTRY_AUTH_REQUIRED}" == "true" ]]; then
        USERNAME="${REGISTRY_USERNAME:-}"
        [[ -n "${USERNAME}" ]] || read -rp "Registry username: " USERNAME
        read -rsp "Registry password/token: " REGISTRY_PASSWORD
        echo
        [[ -n "${USERNAME}" && -n "${REGISTRY_PASSWORD}" ]] || fatal "Registry credentials cannot be empty."
        sudo buildah login \
            --tls-verify="${REGISTRY_TLS_VERIFY}" \
            --username "${USERNAME}" \
            --password "${REGISTRY_PASSWORD}" \
            "${AUTHORITY}"
        unset REGISTRY_PASSWORD
    fi

    sudo buildah tag "${LOCAL_IMAGE}" "${TARGET_IMAGE}"
    sudo buildah push \
        --tls-verify="${REGISTRY_TLS_VERIFY}" \
        "${TARGET_IMAGE}" \
        "docker://${TARGET_IMAGE}"

    echo "Published: ${TARGET_IMAGE}"
    ;;

*)
    fatal "IMAGE_DISTRIBUTION_MODE must be local or registry."
    ;;
esac

log "MLflow image publish completed"
