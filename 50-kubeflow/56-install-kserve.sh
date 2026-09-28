#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"

require_command kubectl

KF_DIR="${ROOT_DIR}/third_party/kubeflow-community-distribution"

if [[ ! -d "${KF_DIR}" ]]; then
    fatal "Kubeflow repository not found."
fi

cd "${KF_DIR}"

log "Checking Knative"

if ! kubectl get namespace knative-serving >/dev/null 2>&1; then
    fatal "Knative Serving is not installed. Run 55-install-knative.sh first."
fi

log "Installing KServe"

./tests/kserve_install.sh


# ------------------------------------------------------------
# Kubeflow 26.03.1:
# KServe control plane is installed in kubeflow namespace.
# ------------------------------------------------------------

KSERVE_NAMESPACE="kubeflow"

log "Waiting for KServe deployments"

kubectl rollout status \
    deployment/kserve-controller-manager \
    -n "${KSERVE_NAMESPACE}" \
    --timeout=600s

kubectl rollout status \
    deployment/kserve-localmodel-controller-manager \
    -n "${KSERVE_NAMESPACE}" \
    --timeout=600s

kubectl rollout status \
    deployment/llmisvc-controller-manager \
    -n "${KSERVE_NAMESPACE}" \
    --timeout=600s

kubectl rollout status \
    deployment/kserve-models-web-application \
    -n "${KSERVE_NAMESPACE}" \
    --timeout=600s


log "KServe deployments"

kubectl get deployment \
    -n "${KSERVE_NAMESPACE}" \
    | grep -E 'kserve|llmisvc|localmodel'


log "KServe pods"

kubectl get pods \
    -n "${KSERVE_NAMESPACE}" \
    -o wide \
    | grep -E 'kserve|llmisvc|localmodel'


log "KServe CRDs"

kubectl get crd \
    | grep -E \
    'inferenceservices|servingruntimes|clusterservingruntimes|llminferenceservices' \
    || true


log "KServe services"

kubectl get svc \
    -n "${KSERVE_NAMESPACE}" \
    | grep -E 'kserve|llmisvc|localmodel' \
    || true


log "KServe certificates"

kubectl get certificate \
    -n "${KSERVE_NAMESPACE}" \
    | grep -E 'serving|kserve|llmisvc|localmodel' \
    || true


log "KServe installation completed"
