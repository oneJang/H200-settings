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

log "Installing Knative Serving"

./tests/knative_serving_install.sh


log "Waiting for Knative Serving"

kubectl wait \
    --for=condition=Ready \
    pod \
    --all \
    -n knative-serving \
    --timeout=600s


log "Knative Serving resources"

kubectl get pods \
    -n knative-serving \
    -o wide

kubectl get svc \
    -n knative-serving


log "Knative Serving installation completed"
