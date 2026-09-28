#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/versions.env"
source "${ROOT_DIR}/config/object-storage.env"
source "${ROOT_DIR}/config/registry.env"

require_value IMAGE_DISTRIBUTION_MODE
require_value MINIO_VERSION
require_value MINIO_IMAGE_NAME
require_command sudo
require_command buildah

LOCAL_IMAGE_REF="localhost/${MINIO_IMAGE_NAME}:${MINIO_VERSION}"

sudo buildah images --format '{{.Name}}:{{.Tag}}' | grep -Fx "${LOCAL_IMAGE_REF}" >/dev/null \
    || fatal "Local Buildah image not found. Run 60-build-minio-image.sh first."

registry_authority() {
    local authority="${REGISTRY_HOST}"
    if [[ -n "${REGISTRY_PORT:-}" ]]; then
        authority="${authority}:${REGISTRY_PORT}"
    fi
    printf '%s' "${authority}"
}

registry_image_ref() {
    local authority prefix
    authority="$(registry_authority)"
    prefix="${REGISTRY_REPOSITORY_PREFIX#/}"
    prefix="${prefix%/}"
    if [[ -n "${prefix}" ]]; then
        printf '%s/%s/%s:%s' "${authority}" "${prefix}" "${MINIO_IMAGE_NAME}" "${MINIO_VERSION}"
    else
        printf '%s/%s:%s' "${authority}" "${MINIO_IMAGE_NAME}" "${MINIO_VERSION}"
    fi
}

case "${IMAGE_DISTRIBUTION_MODE}" in
    local)
        require_command kubectl
        require_command ctr

        READY_NODES="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /^Ready/ && $2 !~ /SchedulingDisabled/ {count++} END {print count+0}')"
        [[ "${READY_NODES}" -eq 1 ]] \
            || fatal "local image mode requires exactly one Ready schedulable node; found ${READY_NODES}. Use registry mode for multi-node clusters."

        NODE_NAME="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
        HOST_SHORT="$(hostname -s)"
        HOST_FULL="$(hostname)"
        if [[ "${NODE_NAME}" != "${HOST_SHORT}" && "${NODE_NAME}" != "${HOST_FULL}" ]]; then
            fatal "local mode must run on the Kubernetes node itself. Node=${NODE_NAME}, host=${HOST_FULL}"
        fi

        TEMP_DIR="$(sudo mktemp -d /var/tmp/h200-minio-publish.XXXXXX)"
        ARCHIVE="${TEMP_DIR}/minio-image.tar"
        cleanup_local_publish() { sudo rm -rf "${TEMP_DIR}" || true; }
        trap cleanup_local_publish EXIT

        log "Publishing image to local Kubernetes containerd"
        sudo buildah push \
            "${LOCAL_IMAGE_REF}" \
            "docker-archive:${ARCHIVE}:${LOCAL_IMAGE_REF}"

        sudo test -s "${ARCHIVE}" || fatal "Image archive was not created: ${ARCHIVE}"
        sudo ctr -n k8s.io images import "${ARCHIVE}"
        sudo ctr -n k8s.io images list | grep -F "${LOCAL_IMAGE_REF}" >/dev/null \
            || fatal "Image was not imported into containerd k8s.io namespace."

        echo "Distribution mode : local"
        echo "Deployment image  : ${LOCAL_IMAGE_REF}"
        ;;

    registry)
        require_value REGISTRY_HOST
        require_value REGISTRY_TLS_VERIFY
        require_value REGISTRY_AUTH_REQUIRED

        case "${REGISTRY_TLS_VERIFY}" in true|false) ;; *) fatal "REGISTRY_TLS_VERIFY must be true or false." ;; esac
        case "${REGISTRY_AUTH_REQUIRED}" in true|false) ;; *) fatal "REGISTRY_AUTH_REQUIRED must be true or false." ;; esac

        AUTHORITY="$(registry_authority)"
        TARGET_IMAGE="$(registry_image_ref)"

        if [[ "${REGISTRY_AUTH_REQUIRED}" == "true" ]]; then
            USERNAME="${REGISTRY_USERNAME:-}"
            if [[ -z "${USERNAME}" ]]; then
                read -rp "Registry username: " USERNAME
            fi
            read -rsp "Registry password/token: " REGISTRY_PASSWORD
            echo
            [[ -n "${USERNAME}" && -n "${REGISTRY_PASSWORD}" ]] \
                || fatal "Registry credentials cannot be empty."

            log "Logging in to OCI registry"
            sudo buildah login \
                --tls-verify="${REGISTRY_TLS_VERIFY}" \
                --username "${USERNAME}" \
                --password "${REGISTRY_PASSWORD}" \
                "${AUTHORITY}"
            unset REGISTRY_PASSWORD
        fi

        log "Publishing image to OCI registry"
        sudo buildah tag "${LOCAL_IMAGE_REF}" "${TARGET_IMAGE}"
        sudo buildah push \
            --tls-verify="${REGISTRY_TLS_VERIFY}" \
            "${TARGET_IMAGE}" \
            "docker://${TARGET_IMAGE}"

        echo "Distribution mode : registry"
        echo "Deployment image  : ${TARGET_IMAGE}"
        ;;

    *)
        fatal "IMAGE_DISTRIBUTION_MODE must be local or registry."
        ;;
esac

log "MinIO image publish completed"
