#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/kubeflow.env"

require_command kubectl
require_value KUBEFLOW_PROFILE

KF_DIR="${ROOT_DIR}/third_party/kubeflow-community-distribution"

if [[ ! -d "${KF_DIR}" ]]; then
    fatal "Kubeflow repository not found."
fi

export KF_PROFILE="${KUBEFLOW_PROFILE}"

if ! kubectl get namespace "${KF_PROFILE}" >/dev/null 2>&1; then
    fatal "Kubeflow profile namespace not found: ${KF_PROFILE}. Run 57-create-kubeflow-profile.sh first."
fi

cd "${KF_DIR}"


log "Installing Kubeflow Notebooks"

./tests/notebooks_install.sh


log "Installing Katib"

./tests/katib_install.sh


log "Installing Kubeflow Trainer"

./tests/trainer_install.sh


log "Training components"

kubectl get pods \
    -n kubeflow \
    -o wide


log "Training components installation completed"
