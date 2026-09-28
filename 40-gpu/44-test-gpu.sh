#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"

require_command kubectl

log "Creating GPU test Pod"

kubectl delete pod gpu-test \
    --ignore-not-found=true

cat <<'EOF2' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
spec:
  restartPolicy: Never

  containers:
    - name: cuda
      image: nvidia/cuda:13.0.1-base-ubuntu24.04

      command:
        - bash
        - -c
        - |
          nvidia-smi
          sleep 5

      resources:
        limits:
          nvidia.com/gpu: 1
EOF2

log "Waiting for GPU Pod"

kubectl wait \
    --for=condition=Ready \
    pod/gpu-test \
    --timeout=300s

kubectl logs gpu-test

kubectl delete pod gpu-test

log "GPU test completed"
