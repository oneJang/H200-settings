#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/versions.env"

require_command curl
require_value KUSTOMIZE_VERSION

ARCH="$(dpkg --print-architecture)"

case "${ARCH}" in
    amd64)
        ARCH="amd64"
        ;;
    arm64)
        ARCH="arm64"
        ;;
    *)
        fatal "Unsupported architecture: ${ARCH}"
        ;;
esac

TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

log "Downloading Kustomize ${KUSTOMIZE_VERSION}"

curl -fL \
    "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz" \
    -o "${TMP_DIR}/kustomize.tar.gz"

tar -xzf \
    "${TMP_DIR}/kustomize.tar.gz" \
    -C "${TMP_DIR}"

log "Installing Kustomize"

sudo install -m 0755 \
    "${TMP_DIR}/kustomize" \
    /usr/local/bin/kustomize

log "Verification"

kustomize version
