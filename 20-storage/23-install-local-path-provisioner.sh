#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/versions.env"
source "${ROOT_DIR}/config/cluster.env"

require_command kubectl
require_command helm

log "Adding Local Path Provisioner Helm repo"

helm repo add containeroo \
    https://charts.containeroo.ch \
    --force-update

helm repo update

log "Creating values"

VALUES_FILE="${ROOT_DIR}/generated/local-path-values.yaml"

cat > "${VALUES_FILE}" <<EOF
storageClass:
  create: true
  name: local-path
  defaultClass: true
  reclaimPolicy: Retain

nodePathMap:
  - node: DEFAULT_PATH_FOR_NON_LISTED_NODES
    paths:
      - ${LOCAL_PATH_DIR}
EOF

log "Installing Local Path Provisioner"

helm upgrade --install local-path-provisioner \
    containeroo/local-path-provisioner \
    --namespace local-path-storage \
    --create-namespace \
    --values "${VALUES_FILE}"

log "Waiting for deployment"

kubectl rollout status deployment/local-path-provisioner \
    -n local-path-storage \
    --timeout=180s
