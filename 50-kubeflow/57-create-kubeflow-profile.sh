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

cd "${KF_DIR}"

export KF_PROFILE="${KUBEFLOW_PROFILE}"

log "Creating Kubeflow profile: ${KF_PROFILE}"

./tests/kubeflow_profile_install.sh

log "Profile verification"

kubectl get profiles

kubectl get namespace "${KF_PROFILE}"

log "Kubeflow profile created"
