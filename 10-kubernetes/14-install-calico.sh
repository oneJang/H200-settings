#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/versions.env"

require_value CALICO_VERSION
require_command kubectl

CALICO_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

GENERATED_DIR="${ROOT_DIR}/generated"
CALICO_FILE="${GENERATED_DIR}/calico-${CALICO_VERSION}.yaml"

mkdir -p "${GENERATED_DIR}"

log "Downloading Calico ${CALICO_VERSION}"

curl -fL \
    "${CALICO_URL}" \
    -o "${CALICO_FILE}"

log "Applying Calico"

kubectl apply \
    -f "${CALICO_FILE}"

log "Waiting for Calico"

kubectl rollout status \
    daemonset/calico-node \
    -n kube-system \
    --timeout=300s

kubectl rollout status \
    deployment/calico-kube-controllers \
    -n kube-system \
    --timeout=300s

log "Calico status"

kubectl get pods \
    -n kube-system \
    -o wide
