#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PURGE_ARG=""
INCLUDE_K8S=false

for arg in "$@"; do
    case "${arg}" in
        --purge-data)
            PURGE_ARG="--purge-data"
            ;;
        --include-kubernetes)
            INCLUDE_K8S=true
            ;;
        *)
            echo "Unknown option: ${arg}" >&2
            exit 1
            ;;
    esac
done

FAILURES=()

run_step() {
    local label="$1"
    shift

    echo
    echo "===== ${label} ====="

    if ! "$@"; then
        FAILURES+=("${label}")
    fi
}

# Dependency-aware order:
#
#   MLflow  -> MinIO / Kubeflow-Istio
#   KFP     -> MinIO / Kubeflow
#
# Remove consumers before their dependencies.

if [[ -n "${PURGE_ARG}" ]]; then
    run_step "MLflow" \
        "${ROOT_DIR}/80-mlflow/89-uninstall-mlflow.sh" \
        "${PURGE_ARG}"
else
    run_step "MLflow" \
        "${ROOT_DIR}/80-mlflow/89-uninstall-mlflow.sh"
fi

run_step "Pipelines" \
    "${SCRIPT_DIR}/91-uninstall-pipelines.sh"

if [[ -n "${PURGE_ARG}" ]]; then
    run_step "Object Storage" \
        "${SCRIPT_DIR}/92-uninstall-object-storage.sh" \
        "${PURGE_ARG}"

    run_step "Kubeflow" \
        "${SCRIPT_DIR}/93-uninstall-kubeflow.sh" \
        "${PURGE_ARG}"

    run_step "Harbor" \
        "${SCRIPT_DIR}/95-uninstall-harbor.sh" \
        "${PURGE_ARG}"
else
    run_step "Object Storage" \
        "${SCRIPT_DIR}/92-uninstall-object-storage.sh"

    run_step "Kubeflow" \
        "${SCRIPT_DIR}/93-uninstall-kubeflow.sh"

    run_step "Harbor" \
        "${SCRIPT_DIR}/95-uninstall-harbor.sh"
fi

run_step "GPU Operator" \
    "${SCRIPT_DIR}/94-uninstall-gpu-operator.sh"

run_step "Local Path Provisioner" \
    "${SCRIPT_DIR}/96-uninstall-local-path.sh"

if [[ "${INCLUDE_K8S}" == "true" ]]; then
    echo
    echo "Kubernetes reset was requested, but it remains intentionally explicit."
    echo "Run: sudo ${SCRIPT_DIR}/98-reset-kubernetes.sh --yes-really-reset"
fi

if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo
    echo "Uninstall completed with failures:" >&2
    printf '  - %s\n' "${FAILURES[@]}" >&2
    exit 1
fi

echo
echo "Uninstall sequence completed successfully."
