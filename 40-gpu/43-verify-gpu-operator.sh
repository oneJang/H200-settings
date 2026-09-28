#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/gpu.env"

require_command kubectl

log "GPU Operator Pods"

kubectl get pods \
    -n "${GPU_OPERATOR_NAMESPACE}" \
    -o wide

log "GPU Operator DaemonSets"

kubectl get daemonset \
    -n "${GPU_OPERATOR_NAMESPACE}"

log "GPU resources on nodes"

kubectl get nodes \
    -o custom-columns=\
NAME:.metadata.name,\
GPU-CAPACITY:.status.capacity.nvidia\\.com/gpu,\
GPU-ALLOCATABLE:.status.allocatable.nvidia\\.com/gpu

log "NVIDIA node labels"

kubectl get nodes \
    --show-labels \
    | grep -o 'nvidia.com/[^,]*' \
    | sort \
    | uniq \
    || true

log "GPU Operator verification completed"
