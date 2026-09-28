#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/versions.env"
source "${ROOT_DIR}/config/object-storage.env"

require_command kubectl
require_command helm

require_value SEAWEEDFS_NAMESPACE
require_value SEAWEEDFS_RELEASE_NAME
require_value SEAWEEDFS_STORAGE_CLASS
require_value SEAWEEDFS_VERSION
require_value SEAWEEDFS_S3_SECRET

VALUES_FILE="${ROOT_DIR}/generated/seaweedfs-values.yaml"

mkdir -p "${ROOT_DIR}/generated"

log "Creating namespace"

kubectl create namespace "${SEAWEEDFS_NAMESPACE}" \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -


# ------------------------------------------------------------
# S3 credentials
# ------------------------------------------------------------

log "Creating SeaweedFS S3 credentials"

read -rp "SeaweedFS S3 Access Key: " S3_ACCESS_KEY
read -rsp "SeaweedFS S3 Secret Key: " S3_SECRET_KEY
echo

if [[ -z "${S3_ACCESS_KEY}" || -z "${S3_SECRET_KEY}" ]]; then
    fatal "S3 credentials cannot be empty."
fi

S3_CONFIG="$(
cat <<EOF2
{
  "identities": [
    {
      "name": "ml-platform-admin",
      "credentials": [
        {
          "accessKey": "${S3_ACCESS_KEY}",
          "secretKey": "${S3_SECRET_KEY}"
        }
      ],
      "actions": [
        "Admin",
        "Read",
        "Write"
      ]
    }
  ]
}
EOF2
)"

kubectl create secret generic \
    "${SEAWEEDFS_S3_SECRET}" \
    -n "${SEAWEEDFS_NAMESPACE}" \
    --from-literal=seaweedfs_s3_config="${S3_CONFIG}" \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -

unset S3_CONFIG
unset S3_ACCESS_KEY
unset S3_SECRET_KEY


# ------------------------------------------------------------
# Helm repository
# ------------------------------------------------------------

log "Adding SeaweedFS Helm repository"

helm repo add seaweedfs \
    https://seaweedfs.github.io/seaweedfs/helm \
    --force-update

helm repo update


# ------------------------------------------------------------
# values
# ------------------------------------------------------------

log "Generating SeaweedFS values"

cat > "${VALUES_FILE}" <<EOF2
global:
  seaweedfs:
    image:
      name: chrislusf/seaweedfs
      tag: "${SEAWEEDFS_VERSION}"

master:
  replicas: 1
  data:
    type: persistentVolumeClaim
    size: ${SEAWEEDFS_MASTER_SIZE}
    storageClass: ${SEAWEEDFS_STORAGE_CLASS}

volume:
  replicas: 1
  dataDirs:
    - name: data
      type: persistentVolumeClaim
      size: ${SEAWEEDFS_VOLUME_SIZE}
      storageClass: ${SEAWEEDFS_STORAGE_CLASS}
      maxVolumes: 0

filer:
  replicas: 1
  data:
    type: persistentVolumeClaim
    size: ${SEAWEEDFS_FILER_SIZE}
    storageClass: ${SEAWEEDFS_STORAGE_CLASS}

  s3:
    enabled: false

s3:
  enabled: true
  replicas: 1
  port: ${SEAWEEDFS_S3_PORT}
  enableAuth: true
  existingConfigSecret: ${SEAWEEDFS_S3_SECRET}

  createBuckets:
    - name: ${KFP_ARTIFACT_BUCKET}
    - name: ${MLFLOW_ARTIFACT_BUCKET}

admin:
  enabled: false
EOF2


# ------------------------------------------------------------
# Install
# ------------------------------------------------------------

log "Installing SeaweedFS"

helm upgrade --install \
    "${SEAWEEDFS_RELEASE_NAME}" \
    seaweedfs/seaweedfs \
    -n "${SEAWEEDFS_NAMESPACE}" \
    --values "${VALUES_FILE}" \
    --wait \
    --timeout 15m


log "SeaweedFS installed"

kubectl get pods \
    -n "${SEAWEEDFS_NAMESPACE}" \
    -o wide

kubectl get svc \
    -n "${SEAWEEDFS_NAMESPACE}"

kubectl get pvc \
    -n "${SEAWEEDFS_NAMESPACE}"
