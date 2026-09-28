#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/object-storage.env"
require_command kubectl
require_value MINIO_NAMESPACE
require_value MINIO_S3_SERVICE
require_value MINIO_S3_PORT
require_value MINIO_ROOT_SECRET
require_value MINIO_CONSOLE_SERVICE
require_value MINIO_CONSOLE_SERVICE_TYPE
require_value KFP_ARTIFACT_BUCKET
require_value MLFLOW_ARTIFACT_BUCKET

log "MinIO resources"
kubectl get deployment,pod,svc,pvc,job -n "${MINIO_NAMESPACE}" -o wide
kubectl rollout status deployment/minio -n "${MINIO_NAMESPACE}" --timeout=60s
PVC_PHASE="$(kubectl get pvc minio-data -n "${MINIO_NAMESPACE}" -o jsonpath='{.status.phase}')"
[[ "${PVC_PHASE}" == "Bound" ]] || fatal "minio-data PVC is not Bound: ${PVC_PHASE}"
POD="$(kubectl get pod -n "${MINIO_NAMESPACE}" -l app=minio -o jsonpath='{.items[0].metadata.name}')"
[[ -n "${POD}" ]] || fatal "MinIO pod not found."
ROOT_USER="$(kubectl get secret "${MINIO_ROOT_SECRET}" -n "${MINIO_NAMESPACE}" -o jsonpath='{.data.rootUser}' | base64 -d)"
ROOT_PASSWORD="$(kubectl get secret "${MINIO_ROOT_SECRET}" -n "${MINIO_NAMESPACE}" -o jsonpath='{.data.rootPassword}' | base64 -d)"
MC_CONFIG_DIR="/tmp/mc-config"
kubectl exec -n "${MINIO_NAMESPACE}" "${POD}" -- rm -rf "${MC_CONFIG_DIR}" || true
kubectl exec -n "${MINIO_NAMESPACE}" "${POD}" -- mkdir -p "${MC_CONFIG_DIR}"
kubectl exec -n "${MINIO_NAMESPACE}" "${POD}" -- /usr/local/bin/mc --config-dir "${MC_CONFIG_DIR}" alias set local "http://${MINIO_S3_SERVICE}:${MINIO_S3_PORT}" "${ROOT_USER}" "${ROOT_PASSWORD}" >/dev/null
kubectl exec -n "${MINIO_NAMESPACE}" "${POD}" -- /usr/local/bin/mc --config-dir "${MC_CONFIG_DIR}" admin info local
for bucket in "${KFP_ARTIFACT_BUCKET}" "${MLFLOW_ARTIFACT_BUCKET}"; do
  kubectl exec -n "${MINIO_NAMESPACE}" "${POD}" -- /usr/local/bin/mc --config-dir "${MC_CONFIG_DIR}" stat "local/${bucket}" >/dev/null \
    || fatal "Bucket not found or inaccessible: ${bucket}"
  echo "OK: ${bucket}"
done
kubectl exec -n "${MINIO_NAMESPACE}" "${POD}" -- rm -rf "${MC_CONFIG_DIR}" || true
unset ROOT_USER ROOT_PASSWORD

log "MinIO Console service"

CONSOLE_SERVICE_TYPE="$(
  kubectl get service "${MINIO_CONSOLE_SERVICE}" \
    -n "${MINIO_NAMESPACE}" \
    -o jsonpath='{.spec.type}'
)"

[[ "${CONSOLE_SERVICE_TYPE}" == "${MINIO_CONSOLE_SERVICE_TYPE}" ]] \
  || fatal "MinIO Console Service type mismatch: actual=${CONSOLE_SERVICE_TYPE}, expected=${MINIO_CONSOLE_SERVICE_TYPE}"

if [[ "${MINIO_CONSOLE_SERVICE_TYPE}" == "NodePort" ]]; then
  require_value MINIO_CONSOLE_NODEPORT

  ACTUAL_NODEPORT="$(
    kubectl get service "${MINIO_CONSOLE_SERVICE}" \
      -n "${MINIO_NAMESPACE}" \
      -o jsonpath='{.spec.ports[0].nodePort}'
  )"

  [[ "${ACTUAL_NODEPORT}" == "${MINIO_CONSOLE_NODEPORT}" ]] \
    || fatal "MinIO Console NodePort mismatch: actual=${ACTUAL_NODEPORT}, expected=${MINIO_CONSOLE_NODEPORT}"

  echo "Console NodePort : ${ACTUAL_NODEPORT}"
fi

log "MinIO verification completed"
echo "S3 endpoint : http://${MINIO_S3_SERVICE}.${MINIO_NAMESPACE}.svc.cluster.local:${MINIO_S3_PORT}"
