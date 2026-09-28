#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/kubeflow.env"

require_command kubectl
require_value KUBEFLOW_PROFILE


# ============================================================
# Helper
# ============================================================

check_namespace() {
    local namespace="$1"

    echo
    echo "============================================================"
    echo "[NAMESPACE] ${namespace}"
    echo "============================================================"

    if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
        kubectl get pods \
            -n "${namespace}" \
            -o wide
    else
        warn "Namespace not found: ${namespace}"
    fi
}


# ============================================================
# Cluster
# ============================================================

log "Cluster nodes"

kubectl get nodes -o wide


# ============================================================
# Namespaces
# ============================================================

log "Kubeflow related namespaces"

kubectl get namespace \
    | grep -E \
    'kubeflow|cert-manager|istio|oauth2|auth|knative' \
    || true


# ============================================================
# Core components
# ============================================================

check_namespace cert-manager
check_namespace istio-system
check_namespace oauth2-proxy
check_namespace auth
check_namespace knative-serving
check_namespace kubeflow


# ============================================================
# User Profile
# ============================================================

log "Kubeflow Profile"

kubectl get profiles


log "Profile namespace"

if kubectl get namespace "${KUBEFLOW_PROFILE}" >/dev/null 2>&1; then

    kubectl get namespace \
        "${KUBEFLOW_PROFILE}" \
        --show-labels

    echo

    kubectl get pods \
        -n "${KUBEFLOW_PROFILE}" \
        -o wide

else

    warn "Profile namespace not found: ${KUBEFLOW_PROFILE}"

fi


# ============================================================
# KServe
# Kubeflow 26.03.1에서는 kubeflow namespace에 설치됨
# ============================================================

log "KServe deployments"

kubectl get deployment \
    -n kubeflow \
    | grep -E \
    'kserve|llmisvc|localmodel' \
    || true


log "KServe pods"

kubectl get pods \
    -n kubeflow \
    -o wide \
    | grep -E \
    'kserve|llmisvc|localmodel' \
    || true


log "KServe services"

kubectl get svc \
    -n kubeflow \
    | grep -E \
    'kserve|llmisvc|localmodel' \
    || true


log "KServe CRDs"

kubectl get crd \
    | grep -E \
    'inferenceservices|servingruntimes|clusterservingruntimes|llminferenceservices' \
    || true


# ============================================================
# Knative
# ============================================================

log "Knative Serving"

kubectl get deployment \
    -n knative-serving \
    || true


# ============================================================
# Notebooks
# ============================================================

log "Notebook components"

kubectl get deployment \
    -n kubeflow \
    | grep -Ei \
    'notebook|jupyter|tensorboard|volumes|pvc-viewer' \
    || true


log "Notebook API resources"

kubectl api-resources \
    | grep -Ei \
    'notebook' \
    || true


# ============================================================
# Katib
# ============================================================

log "Katib components"

kubectl get deployment \
    -n kubeflow \
    | grep -Ei \
    'katib' \
    || true


log "Katib API resources"

kubectl api-resources \
    | grep -Ei \
    'experiment|suggestion|trial' \
    || true


log "Katib profile label"

kubectl get namespace \
    "${KUBEFLOW_PROFILE}" \
    --show-labels \
    | grep \
    'katib.kubeflow.org/metrics-collector-injection=enabled' \
    || warn "Katib metrics collector label not found on ${KUBEFLOW_PROFILE}"


# ============================================================
# Trainer
# ============================================================

log "Trainer components"

kubectl get deployment \
    -n kubeflow \
    | grep -Ei \
    'trainer|training' \
    || true


log "Trainer API resources"

kubectl api-resources \
    | grep -Ei \
    'trainjob|training' \
    || true


# ============================================================
# Model Registry
# ============================================================

log "Model Registry deployments"

kubectl get deployment \
    -n "${KUBEFLOW_PROFILE}" \
    | grep -E \
    'model-registry-db|model-registry-deployment|model-registry-ui' \
    || warn "Model Registry deployments not found in ${KUBEFLOW_PROFILE}"


log "Model Registry services"

kubectl get svc \
    -n "${KUBEFLOW_PROFILE}" \
    | grep -E \
    'model-registry-db|model-registry-service|model-registry-ui-service' \
    || warn "Model Registry services not found in ${KUBEFLOW_PROFILE}"


log "Model Registry routes"

kubectl get virtualservice \
    -n "${KUBEFLOW_PROFILE}" \
    | grep -E \
    'model-registry' \
    || warn "Model Registry VirtualServices not found in ${KUBEFLOW_PROFILE}"


log "Model Registry PVC"

kubectl get pvc \
    -n "${KUBEFLOW_PROFILE}" \
    | grep -E \
    'metadata-postgres' \
    || warn "Model Registry PostgreSQL PVC not found in ${KUBEFLOW_PROFILE}"


# ============================================================
# Istio Gateway
# ============================================================

log "Istio ingress gateway"

kubectl get svc \
    -n istio-system \
    | grep \
    'istio-ingressgateway' \
    || true


# ============================================================
# Certificates
# ============================================================

log "Certificates"

kubectl get certificate \
    -A \
    || true


# ============================================================
# PVC
# ============================================================

log "Persistent Volume Claims"

kubectl get pvc -A


# ============================================================
# Non-ready Pods
# ============================================================

log "Pods not Running / Completed"

NON_READY="$(
    kubectl get pods -A \
        --no-headers \
        | awk '
            $4 != "Running" &&
            $4 != "Completed" {
                print
            }
        '
)"

if [[ -n "${NON_READY}" ]]; then

    warn "Some Pods are not Running or Completed"

    echo "${NON_READY}"

else

    echo "All Pods are Running or Completed."

fi


# ============================================================
# Deployment readiness
# ============================================================

log "Deployments not fully ready"

NOT_READY_DEPLOYMENTS="$(
    kubectl get deployment -A \
        --no-headers \
        | awk '
            {
                split($3, desired, "/")

                if (desired[1] != desired[2]) {
                    print
                }
            }
        '
)"

if [[ -n "${NOT_READY_DEPLOYMENTS}" ]]; then

    warn "Some Deployments are not fully ready"

    echo "${NOT_READY_DEPLOYMENTS}"

else

    echo "All Deployments are fully ready."

fi


# ============================================================
# Final
# ============================================================

log "Kubeflow verification completed"
