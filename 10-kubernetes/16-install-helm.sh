#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/versions.env"

require_root
require_value HELM_VERSION
check_ubuntu_2404

ARCH="amd64"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

log "Downloading Helm ${HELM_VERSION}"

curl -fL \
  "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" \
  -o "${TMP_DIR}/helm.tar.gz"

log "Extracting Helm"

tar -xzf "${TMP_DIR}/helm.tar.gz" \
  -C "${TMP_DIR}"

log "Installing Helm"

install -m 0755 \
  "${TMP_DIR}/linux-${ARCH}/helm" \
  /usr/local/bin/helm

log "Verification"

helm version

log "Helm installation completed"
