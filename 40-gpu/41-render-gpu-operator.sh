#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/versions.env"
source "${ROOT_DIR}/config/gpu.env"

require_command helm
require_value GPU_OPERATOR_VERSION

VALUES_FILE="${ROOT_DIR}/generated/gpu-operator-values.yaml"
RENDER_FILE="${ROOT_DIR}/generated/gpu-operator-rendered.yaml"

mkdir -p "${ROOT_DIR}/generated"

log "Adding NVIDIA Helm repository"

helm repo add nvidia \
    https://helm.ngc.nvidia.com/nvidia \
    --force-update

helm repo update

log "Checking GPU Operator chart"

helm show chart \
    nvidia/gpu-operator \
    --version "v${GPU_OPERATOR_VERSION}"

log "Generating values"

cat > "${VALUES_FILE}" <<EOF2
driver:
  enabled: ${GPU_DRIVER_ENABLED}

toolkit:
  enabled: ${GPU_TOOLKIT_ENABLED}

mig:
  strategy: ${GPU_MIG_STRATEGY}

dcgmExporter:
  enabled: ${GPU_DCGM_EXPORTER_ENABLED}
EOF2

log "Rendering GPU Operator"

helm template gpu-operator \
    nvidia/gpu-operator \
    --namespace "${GPU_OPERATOR_NAMESPACE}" \
    --version "v${GPU_OPERATOR_VERSION}" \
    --values "${VALUES_FILE}" \
    > "${RENDER_FILE}"

log "Rendered resources"

grep '^kind:' "${RENDER_FILE}" \
    | sort \
    | uniq -c

log "GPU Operator render completed"

echo "Values   : ${VALUES_FILE}"
echo "Manifest : ${RENDER_FILE}"
