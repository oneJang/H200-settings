#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/versions.env"
source "${ROOT_DIR}/config/gpu.env"

require_command kubectl
require_command helm

require_value GPU_OPERATOR_VERSION
require_value GPU_OPERATOR_NAMESPACE

if [[ "${GPU_OPERATOR_INSTALL}" != "true" ]]; then
    warn "GPU_OPERATOR_INSTALL=false"
    warn "Skipping actual GPU Operator installation."
    warn "Run 41-render-gpu-operator.sh for validation."
    exit 0
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
    warn "nvidia-smi is not currently available on the host."
    warn "This can be normal if GPU Operator will install the driver."
fi

VALUES_FILE="${ROOT_DIR}/generated/gpu-operator-values.yaml"

if [[ ! -f "${VALUES_FILE}" ]]; then
    fatal "GPU Operator values file not found. Run 41-render-gpu-operator.sh first."
fi

log "Adding NVIDIA Helm repository"

helm repo add nvidia \
    https://helm.ngc.nvidia.com/nvidia \
    --force-update

helm repo update

log "Installing GPU Operator ${GPU_OPERATOR_VERSION}"

helm upgrade --install gpu-operator \
    nvidia/gpu-operator \
    --namespace "${GPU_OPERATOR_NAMESPACE}" \
    --create-namespace \
    --version "v${GPU_OPERATOR_VERSION}" \
    --values "${VALUES_FILE}" \
    --wait \
    --timeout 20m

log "GPU Operator installation completed"

kubectl get pods \
    -n "${GPU_OPERATOR_NAMESPACE}" \
    -o wide
