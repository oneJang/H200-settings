#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/versions.env"

require_command git
require_value KUBEFLOW_VERSION

KF_DIR="${ROOT_DIR}/third_party/kubeflow-community-distribution"

log "Fetching Kubeflow Community Distribution ${KUBEFLOW_VERSION}"

if [[ -d "${KF_DIR}/.git" ]]; then

    log "Kubeflow repository already exists"

    git -C "${KF_DIR}" fetch --tags --prune

else

    git clone \
        https://github.com/kubeflow/community-distribution.git \
        "${KF_DIR}"
fi

git -C "${KF_DIR}" checkout \
    "${KUBEFLOW_VERSION}"

log "Verification"

echo "Directory:"
echo "${KF_DIR}"

echo
echo "Git revision:"

git -C "${KF_DIR}" describe --tags --always

echo
echo "Git commit:"

git -C "${KF_DIR}" rev-parse HEAD

log "Kubeflow source prepared"
