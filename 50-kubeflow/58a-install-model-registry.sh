#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/kubeflow.env"

require_command kubectl
require_command kustomize
require_value KUBEFLOW_PROFILE

KF_DIR="${ROOT_DIR}/third_party/kubeflow-community-distribution"
HUB_DIR="${KF_DIR}/applications/hub"
MODEL_REGISTRY_OVERLAY="${HUB_DIR}/overlays/model-registry"

[[ -d "${HUB_DIR}" ]] \
    || fatal "Kubeflow Hub manifests not found: ${HUB_DIR}"

[[ -f "${MODEL_REGISTRY_OVERLAY}/kustomization.yaml" ]] \
    || fatal "Model Registry overlay not found: ${MODEL_REGISTRY_OVERLAY}"

if ! kubectl get namespace "${KUBEFLOW_PROFILE}" >/dev/null 2>&1; then
    fatal "Kubeflow profile namespace not found: ${KUBEFLOW_PROFILE}. Run 57-create-kubeflow-profile.sh first."
fi

# Kubeflow 26.03.1's Model Registry overlay is shipped with
# kubeflow-user-example-com embedded in namespace/FQDN patches.
# Keep third_party immutable and render from a temporary copy so that
# KUBEFLOW_PROFILE remains configurable for the real H200 environment.
TMP_DIR="$(mktemp -d /tmp/h200-model-registry.XXXXXX)"
TMP_HUB="${TMP_DIR}/hub"
RENDERED="${TMP_DIR}/model-registry.yaml"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

log "Preparing Kubeflow Model Registry manifests"

cp -a "${HUB_DIR}" "${TMP_HUB}"

sed -i \
    "s/kubeflow-user-example-com/${KUBEFLOW_PROFILE}/g" \
    "${TMP_HUB}/overlays/model-registry/kustomization.yaml"

log "Rendering Kubeflow Model Registry"

kustomize build \
    "${TMP_HUB}/overlays/model-registry" \
    > "${RENDERED}"

[[ -s "${RENDERED}" ]] \
    || fatal "Rendered Model Registry manifest is empty."

log "Validating Model Registry manifests"

kubectl apply \
    --dry-run=server \
    -f "${RENDERED}" \
    >/dev/null

log "Installing Kubeflow Model Registry"

kubectl apply -f "${RENDERED}"

log "Waiting for Model Registry database"

kubectl rollout status \
    deployment/model-registry-db \
    -n "${KUBEFLOW_PROFILE}" \
    --timeout=5m

log "Waiting for Model Registry server"

kubectl rollout status \
    deployment/model-registry-deployment \
    -n "${KUBEFLOW_PROFILE}" \
    --timeout=5m

log "Waiting for Model Registry UI"

kubectl rollout status \
    deployment/model-registry-ui \
    -n "${KUBEFLOW_PROFILE}" \
    --timeout=5m

log "Model Registry resources"

kubectl get deployment,pod,svc,pvc \
    -n "${KUBEFLOW_PROFILE}" \
    -o wide \
    | grep -E 'NAME|model-registry|metadata-postgres' \
    || true

log "Kubeflow Model Registry installation completed"
