#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/mlflow.env"
source "${ROOT_DIR}/config/object-storage.env"

require_command kubectl
require_command openssl
require_value MLFLOW_NAMESPACE
require_value MINIO_NAMESPACE
require_value MINIO_ROOT_SECRET
require_value MINIO_S3_SERVICE
require_value MINIO_S3_PORT
require_value MLFLOW_ARTIFACT_BUCKET
require_value MLFLOW_S3_ACCESS_KEY
require_value MLFLOW_S3_POLICY

kubectl get deployment minio -n "${MINIO_NAMESPACE}" >/dev/null 2>&1 \
    || fatal "MinIO deployment not found in namespace ${MINIO_NAMESPACE}."

MINIO_POD="$(kubectl get pod -n "${MINIO_NAMESPACE}" -l app=minio -o jsonpath='{.items[0].metadata.name}')"
[[ -n "${MINIO_POD}" ]] || fatal "MinIO pod not found."

ROOT_USER="$(kubectl get secret "${MINIO_ROOT_SECRET}" -n "${MINIO_NAMESPACE}" -o jsonpath='{.data.rootUser}' | base64 -d)"
ROOT_PASSWORD="$(kubectl get secret "${MINIO_ROOT_SECRET}" -n "${MINIO_NAMESPACE}" -o jsonpath='{.data.rootPassword}' | base64 -d)"

if kubectl get secret mlflow-artifact-secret -n "${MLFLOW_NAMESPACE}" >/dev/null 2>&1; then
    ACCESS_KEY="$(kubectl get secret mlflow-artifact-secret -n "${MLFLOW_NAMESPACE}" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)"
    SECRET_KEY="$(kubectl get secret mlflow-artifact-secret -n "${MLFLOW_NAMESPACE}" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)"
else
    ACCESS_KEY="${MLFLOW_S3_ACCESS_KEY}"
    SECRET_KEY="$(openssl rand -hex 24)"
fi

MC_DIR="/tmp/mc-mlflow-config"
POLICY_FILE="/tmp/mlflow-artifacts-policy.json"

kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- rm -rf "${MC_DIR}" "${POLICY_FILE}" || true
kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- mkdir -p "${MC_DIR}"

kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- \
    /usr/local/bin/mc --config-dir "${MC_DIR}" alias set local \
    "http://${MINIO_S3_SERVICE}:${MINIO_S3_PORT}" "${ROOT_USER}" "${ROOT_PASSWORD}" >/dev/null

kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- \
    /usr/local/bin/mc --config-dir "${MC_DIR}" mb --ignore-existing "local/${MLFLOW_ARTIFACT_BUCKET}" >/dev/null

POLICY_JSON="$(cat <<EOF2
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::${MLFLOW_ARTIFACT_BUCKET}"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::${MLFLOW_ARTIFACT_BUCKET}/*"]
    }
  ]
}
EOF2
)"

printf '%s' "${POLICY_JSON}" | kubectl exec -i -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- sh -c "cat > ${POLICY_FILE}"

kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- \
    /usr/local/bin/mc --config-dir "${MC_DIR}" admin policy create local "${MLFLOW_S3_POLICY}" "${POLICY_FILE}" >/dev/null 2>&1 \
    || kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- \
       /usr/local/bin/mc --config-dir "${MC_DIR}" admin policy update local "${MLFLOW_S3_POLICY}" "${POLICY_FILE}" >/dev/null 2>&1 \
    || true

kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- \
    /usr/local/bin/mc --config-dir "${MC_DIR}" admin user add local "${ACCESS_KEY}" "${SECRET_KEY}" >/dev/null

kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- \
    /usr/local/bin/mc --config-dir "${MC_DIR}" admin policy attach local "${MLFLOW_S3_POLICY}" --user "${ACCESS_KEY}" >/dev/null

S3_ENDPOINT="http://${MINIO_S3_SERVICE}.${MINIO_NAMESPACE}.svc.cluster.local:${MINIO_S3_PORT}"

kubectl create secret generic mlflow-artifact-secret \
    -n "${MLFLOW_NAMESPACE}" \
    --from-literal=AWS_ACCESS_KEY_ID="${ACCESS_KEY}" \
    --from-literal=AWS_SECRET_ACCESS_KEY="${SECRET_KEY}" \
    --from-literal=AWS_DEFAULT_REGION="us-east-1" \
    --from-literal=MLFLOW_S3_ENDPOINT_URL="${S3_ENDPOINT}" \
    --dry-run=client -o yaml | kubectl apply -f -

unset ROOT_USER ROOT_PASSWORD SECRET_KEY POLICY_JSON
kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- rm -rf "${MC_DIR}" "${POLICY_FILE}" || true

log "MLflow MinIO storage configuration completed"
echo "Bucket   : ${MLFLOW_ARTIFACT_BUCKET}"
echo "Identity : ${ACCESS_KEY}"
echo "Endpoint : ${S3_ENDPOINT}"
