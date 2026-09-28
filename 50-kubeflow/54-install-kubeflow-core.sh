#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/versions.env"

require_command kubectl
require_command kustomize
require_value KUBEFLOW_VERSION

KF_DIR="${ROOT_DIR}/third_party/kubeflow-community-distribution"

if [[ ! -d "${KF_DIR}/.git" ]]; then
    fatal "Kubeflow repository not found. Run 52-fetch-kubeflow.sh first."
fi

cd "${KF_DIR}"

log "Kubeflow revision"
git describe --tags --always


# ------------------------------------------------------------
# Kubeflow Namespace
# ------------------------------------------------------------

log "Installing Kubeflow namespace"

kustomize build \
    common/kubeflow-namespace/base \
    | kubectl apply -f -


# ------------------------------------------------------------
# cert-manager
# ------------------------------------------------------------

log "Installing cert-manager"

./tests/cert_manager_install.sh


# ------------------------------------------------------------
# Istio + Istio CNI
# ------------------------------------------------------------

log "Installing Istio + Istio CNI"

./tests/istio-cni_install.sh


# ------------------------------------------------------------
# OAuth2 Proxy
# ------------------------------------------------------------

log "Installing OAuth2 Proxy"

kustomize build \
    common/oauth2-proxy/overlays/m2m-dex-only/ \
    | kubectl apply -f -

kubectl wait \
    --for=condition=Ready \
    pod \
    -l 'app.kubernetes.io/name=oauth2-proxy' \
    -n oauth2-proxy \
    --timeout=300s


# ------------------------------------------------------------
# Kubeflow Istio Resources
# ------------------------------------------------------------

log "Installing Kubeflow Istio resources"

kustomize build \
    common/istio/kubeflow-istio-resources/base \
    | kubectl apply -f -


# ------------------------------------------------------------
# Profiles / KFAM / Multi-tenancy
# ------------------------------------------------------------

log "Installing multi-tenancy components"

./tests/multi_tenancy_install.sh


# ------------------------------------------------------------
# Dex
# ------------------------------------------------------------

log "Installing Dex"

./tests/dex_install.sh


# ------------------------------------------------------------
# Dashboard + PodDefaults Admission Webhook
# ------------------------------------------------------------

log "Installing Kubeflow Dashboard"

./tests/dashboard_install.sh


log "Kubeflow core installation completed"
