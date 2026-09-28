#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/versions.env"
source "${ROOT_DIR}/config/mlflow.env"
source "${ROOT_DIR}/config/object-storage.env"
source "${ROOT_DIR}/config/registry.env"

require_command kubectl
require_command helm
require_command openssl
require_value MLFLOW_NAMESPACE
require_value MLFLOW_RELEASE_NAME
require_value MLFLOW_VERSION
require_value MLFLOW_HELM_CHART_VERSION
require_value MLFLOW_IMAGE_NAME
require_value MLFLOW_ARTIFACT_BUCKET
require_value IMAGE_DISTRIBUTION_MODE

CHART_ARCHIVE="${SCRIPT_DIR}/vendor/mlflow-v${MLFLOW_VERSION}.tgz"
[[ -s "${CHART_ARCHIVE}" ]] || fatal "Official MLflow chart cache not found: ${CHART_ARCHIVE}. Run 81-prepare-mlflow.sh first."

kubectl get secret mlflow-backend-secret -n "${MLFLOW_NAMESPACE}" >/dev/null 2>&1 \
    || fatal "mlflow-backend-secret missing. Run 83-install-mysql.sh."
kubectl get secret mlflow-artifact-secret -n "${MLFLOW_NAMESPACE}" >/dev/null 2>&1 \
    || fatal "mlflow-artifact-secret missing. Run 84-configure-mlflow-storage.sh."

if ! kubectl get secret mlflow-auth-secret -n "${MLFLOW_NAMESPACE}" >/dev/null 2>&1; then
    ADMIN_PASSWORD="$(openssl rand -hex 20)"
    FLASK_SECRET="$(openssl rand -hex 32)"
    kubectl create secret generic mlflow-auth-secret \
        -n "${MLFLOW_NAMESPACE}" \
        --from-literal=MLFLOW_ADMIN_USERNAME="${MLFLOW_ADMIN_USERNAME}" \
        --from-literal=MLFLOW_ADMIN_PASSWORD="${ADMIN_PASSWORD}" \
        --from-literal=MLFLOW_FLASK_SERVER_SECRET_KEY="${FLASK_SECRET}"
    unset ADMIN_PASSWORD FLASK_SECRET
fi

ADMIN_USERNAME="$(kubectl get secret mlflow-auth-secret -n "${MLFLOW_NAMESPACE}" -o jsonpath='{.data.MLFLOW_ADMIN_USERNAME}' | base64 -d)"
ADMIN_PASSWORD="$(kubectl get secret mlflow-auth-secret -n "${MLFLOW_NAMESPACE}" -o jsonpath='{.data.MLFLOW_ADMIN_PASSWORD}' | base64 -d)"

AUTH_INI="$(mktemp)"
trap 'rm -f "${AUTH_INI}"' EXIT
cat > "${AUTH_INI}" <<EOF2
[mlflow]
default_permission = READ
database_uri = sqlite:////mlflow/basic_auth.db
admin_username = ${ADMIN_USERNAME}
admin_password = ${ADMIN_PASSWORD}
authorization_function = mlflow.server.auth:authenticate_request_basic_auth
grant_default_workspace_access = false
auth_cache_ttl_seconds = 0
EOF2

kubectl create secret generic mlflow-auth-config \
    -n "${MLFLOW_NAMESPACE}" \
    --from-file=basic_auth.ini="${AUTH_INI}" \
    --dry-run=client -o yaml | kubectl apply -f -
unset ADMIN_PASSWORD

case "${IMAGE_DISTRIBUTION_MODE}" in
local)
    IMAGE_REPOSITORY="localhost/${MLFLOW_IMAGE_NAME}"
    IMAGE_TAG="${MLFLOW_VERSION}"
    IMAGE_PULL_POLICY="Never"
    IMAGE_PULL_SECRET_BLOCK="[]"
    ;;
registry)
    require_value REGISTRY_HOST
    AUTHORITY="${REGISTRY_HOST}${REGISTRY_PORT:+:${REGISTRY_PORT}}"
    PREFIX="${REGISTRY_REPOSITORY_PREFIX#/}"; PREFIX="${PREFIX%/}"
    if [[ -n "${PREFIX}" ]]; then IMAGE_REPOSITORY="${AUTHORITY}/${PREFIX}/${MLFLOW_IMAGE_NAME}"; else IMAGE_REPOSITORY="${AUTHORITY}/${MLFLOW_IMAGE_NAME}"; fi
    IMAGE_TAG="${MLFLOW_VERSION}"
    IMAGE_PULL_POLICY="IfNotPresent"
    IMAGE_PULL_SECRET_BLOCK="[]"
    if [[ "${REGISTRY_AUTH_REQUIRED}" == "true" ]]; then
        require_value REGISTRY_PULL_SECRET_NAME
        kubectl get secret "${REGISTRY_PULL_SECRET_NAME}" -n "${MLFLOW_NAMESPACE}" >/dev/null 2>&1 \
            || fatal "Registry pull secret ${REGISTRY_PULL_SECRET_NAME} is missing in ${MLFLOW_NAMESPACE}."
        IMAGE_PULL_SECRET_BLOCK="- name: ${REGISTRY_PULL_SECRET_NAME}"
    fi
    ;;
*) fatal "IMAGE_DISTRIBUTION_MODE must be local or registry." ;;
esac

GENERATED_DIR="${ROOT_DIR}/generated"
mkdir -p "${GENERATED_DIR}"
VALUES_FILE="${GENERATED_DIR}/mlflow-values.yaml"

cat > "${VALUES_FILE}" <<EOF2
fullnameOverride: mlflow-server
replicaCount: 1

image:
  repository: ${IMAGE_REPOSITORY}
  tag: "${IMAGE_TAG}"
  pullPolicy: ${IMAGE_PULL_POLICY}
  imagePullSecrets:
$(if [[ "${IMAGE_PULL_SECRET_BLOCK}" == "[]" ]]; then echo "    []"; else echo "    ${IMAGE_PULL_SECRET_BLOCK}"; fi)

deploymentStrategy:
  type: Recreate

server:
  value_options:
    host: "0.0.0.0"
    port: 5000
    workers: ${MLFLOW_WORKERS}
    app_name: basic-auth
  flag_options:
    - serve_artifacts
  staticPrefix: "/mlflow"

service:
  type: ClusterIP

mlflow:
  backendStoreUriFrom:
    secretKeyRef:
      name: mlflow-backend-secret
      key: MLFLOW_BACKEND_STORE_URI
  artifactsDestination: "s3://${MLFLOW_ARTIFACT_BUCKET}/"

envFrom:
  - secretRef:
      name: mlflow-artifact-secret

env:
  - name: MLFLOW_AUTH_CONFIG_PATH
    value: /etc/mlflow-auth/basic_auth.ini
  - name: MLFLOW_FLASK_SERVER_SECRET_KEY
    valueFrom:
      secretKeyRef:
        name: mlflow-auth-secret
        key: MLFLOW_FLASK_SERVER_SECRET_KEY

extraVolumes:
  - name: auth-config
    secret:
      secretName: mlflow-auth-config

extraVolumeMounts:
  - name: auth-config
    mountPath: /etc/mlflow-auth
    readOnly: true

storage:
  enabled: true
  size: ${MLFLOW_AUTH_PVC_SIZE}
  accessMode: ReadWriteOnce
  storageClassName: ${MLFLOW_STORAGE_CLASS}
  mountPath: /mlflow

resources:
  requests:
    cpu: ${MLFLOW_CPU_REQUEST}
    memory: ${MLFLOW_MEMORY_REQUEST}
  limits:
    cpu: ${MLFLOW_CPU_LIMIT}
    memory: ${MLFLOW_MEMORY_LIMIT}

networkPolicy:
  enabled: false

metrics:
  enabled: false

serviceMonitor:
  enabled: false

automountServiceAccountToken: false
EOF2

log "Rendering official MLflow Helm chart"
helm template "${MLFLOW_RELEASE_NAME}" "${CHART_ARCHIVE}" \
    -n "${MLFLOW_NAMESPACE}" \
    -f "${VALUES_FILE}" >/tmp/mlflow-rendered.yaml

kubectl apply --dry-run=server -f /tmp/mlflow-rendered.yaml >/dev/null

log "Installing/upgrading MLflow from official chart"
helm upgrade --install "${MLFLOW_RELEASE_NAME}" "${CHART_ARCHIVE}" \
    -n "${MLFLOW_NAMESPACE}" \
    -f "${VALUES_FILE}" \
    --wait \
    --timeout 10m

kubectl rollout status deployment/mlflow-server -n "${MLFLOW_NAMESPACE}" --timeout=5m

log "MLflow installation completed"
echo "Admin username: ${ADMIN_USERNAME}"
echo "Admin password is stored only in Kubernetes Secret mlflow-auth-secret."
