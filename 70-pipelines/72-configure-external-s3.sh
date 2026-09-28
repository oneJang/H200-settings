#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/kubeflow.env"
source "${ROOT_DIR}/config/object-storage.env"

require_command kubectl
require_command openssl
require_value KUBEFLOW_PROFILE
require_value MINIO_NAMESPACE
require_value MINIO_S3_SERVICE
require_value MINIO_S3_PORT
require_value MINIO_ROOT_SECRET
require_value KFP_ARTIFACT_BUCKET
require_value KFP_S3_ACCESS_KEY
require_value KFP_S3_POLICY
require_value KFP_S3_SECRET

KFP_NAMESPACE="kubeflow"
S3_HOST="${MINIO_S3_SERVICE}.${MINIO_NAMESPACE}.svc.cluster.local"
S3_ENDPOINT="http://${S3_HOST}:${MINIO_S3_PORT}"

log "Checking prerequisites"
kubectl get deployment ml-pipeline -n "${KFP_NAMESPACE}" >/dev/null 2>&1 \
  || fatal "KFP ml-pipeline deployment not found. Run 71-install-pipelines.sh first."
kubectl get namespace "${KUBEFLOW_PROFILE}" >/dev/null 2>&1 \
  || fatal "Profile namespace not found: ${KUBEFLOW_PROFILE}"
kubectl get secret "${MINIO_ROOT_SECRET}" -n "${MINIO_NAMESPACE}" >/dev/null 2>&1 \
  || fatal "MinIO root Secret not found."

MINIO_POD="$(kubectl get pod -n "${MINIO_NAMESPACE}" -l app=minio -o jsonpath='{.items[0].metadata.name}')"
[[ -n "${MINIO_POD}" ]] || fatal "MinIO pod not found."

ROOT_USER="$(kubectl get secret "${MINIO_ROOT_SECRET}" -n "${MINIO_NAMESPACE}" -o jsonpath='{.data.rootUser}' | base64 -d)"
ROOT_PASSWORD="$(kubectl get secret "${MINIO_ROOT_SECRET}" -n "${MINIO_NAMESPACE}" -o jsonpath='{.data.rootPassword}' | base64 -d)"
[[ -n "${ROOT_USER}" && -n "${ROOT_PASSWORD}" ]] || fatal "MinIO root credentials are empty."

MC_CONFIG_DIR="/tmp/kfp-admin-mc"
log "Configuring temporary MinIO admin client"
kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- rm -rf "${MC_CONFIG_DIR}" || true
kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- mkdir -p "${MC_CONFIG_DIR}"
kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- \
  /usr/local/bin/mc --config-dir "${MC_CONFIG_DIR}" alias set admin "${S3_ENDPOINT}" "${ROOT_USER}" "${ROOT_PASSWORD}" >/dev/null

log "Ensuring KFP artifact bucket exists"
kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- \
  /usr/local/bin/mc --config-dir "${MC_CONFIG_DIR}" mb --ignore-existing "admin/${KFP_ARTIFACT_BUCKET}" >/dev/null

# Kubernetes Secret is the source of truth for the KFP runtime credential.
if kubectl get secret "${KFP_S3_SECRET}" -n "${KFP_NAMESPACE}" >/dev/null 2>&1; then
  log "Reusing existing KFP S3 credential Secret"
  KFP_ACCESS_KEY="$(kubectl get secret "${KFP_S3_SECRET}" -n "${KFP_NAMESPACE}" -o jsonpath='{.data.accesskey}' | base64 -d)"
  KFP_SECRET_KEY="$(kubectl get secret "${KFP_S3_SECRET}" -n "${KFP_NAMESPACE}" -o jsonpath='{.data.secretkey}' | base64 -d)"
else
  KFP_ACCESS_KEY="${KFP_S3_ACCESS_KEY}"
  KFP_SECRET_KEY="$(openssl rand -hex 24)"
fi
[[ -n "${KFP_ACCESS_KEY}" && -n "${KFP_SECRET_KEY}" ]] || fatal "KFP S3 credentials are empty."

log "Ensuring dedicated MinIO user exists"
if ! kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- \
  /usr/local/bin/mc --config-dir "${MC_CONFIG_DIR}" admin user info admin "${KFP_ACCESS_KEY}" >/dev/null 2>&1; then
  kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- \
    /usr/local/bin/mc --config-dir "${MC_CONFIG_DIR}" admin user add admin "${KFP_ACCESS_KEY}" "${KFP_SECRET_KEY}" >/dev/null
fi

POLICY_JSON="$(cat <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"],
      "Resource": ["arn:aws:s3:::${KFP_ARTIFACT_BUCKET}"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::${KFP_ARTIFACT_BUCKET}/*"]
    }
  ]
}
POLICY
)"

log "Applying least-privilege MinIO policy for KFP"
printf '%s\n' "${POLICY_JSON}" | kubectl exec -i -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- sh -c 'cat > /tmp/kfp-policy.json'
kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- \
  /usr/local/bin/mc --config-dir "${MC_CONFIG_DIR}" admin policy create admin "${KFP_S3_POLICY}" /tmp/kfp-policy.json >/dev/null
kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- \
  /usr/local/bin/mc --config-dir "${MC_CONFIG_DIR}" admin policy attach admin "${KFP_S3_POLICY}" --user "${KFP_ACCESS_KEY}" >/dev/null

log "Creating KFP S3 secrets"
for ns in "${KFP_NAMESPACE}" "${KUBEFLOW_PROFILE}"; do
  kubectl create secret generic "${KFP_S3_SECRET}" \
    -n "${ns}" \
    --from-literal=accesskey="${KFP_ACCESS_KEY}" \
    --from-literal=secretkey="${KFP_SECRET_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -
done

log "Configuring KFP API server"
kubectl patch configmap pipeline-install-config -n "${KFP_NAMESPACE}" --type merge -p \
  "{\"data\":{\"bucketName\":\"${KFP_ARTIFACT_BUCKET}\",\"defaultPipelineRoot\":\"s3://${KFP_ARTIFACT_BUCKET}/private-artifacts/${KUBEFLOW_PROFILE}/v2/artifacts\"}}"

kubectl set env deployment/ml-pipeline -n "${KFP_NAMESPACE}" \
  OBJECTSTORECONFIG_HOST="${S3_HOST}" \
  OBJECTSTORECONFIG_PORT="${MINIO_S3_PORT}" \
  OBJECTSTORECONFIG_SECURE="false" \
  OBJECTSTORECONFIG_REGION="us-east-1"

log "Creating profile-scoped KFP artifact configuration"
cat <<EOF2 | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kfp-launcher
  namespace: ${KUBEFLOW_PROFILE}
data:
  defaultPipelineRoot: s3://${KFP_ARTIFACT_BUCKET}/private-artifacts/${KUBEFLOW_PROFILE}/v2/artifacts
  clusterDomain: cluster.local
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: metadata-grpc-configmap
  namespace: ${KUBEFLOW_PROFILE}
data:
  METADATA_GRPC_SERVICE_HOST: metadata-grpc-service.kubeflow
  METADATA_GRPC_SERVICE_PORT: "8080"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: artifact-repositories
  namespace: ${KUBEFLOW_PROFILE}
  annotations:
    workflows.argoproj.io/default-artifact-repository: default-namespaced
data:
  default-namespaced: |
    archiveLogs: true
    s3:
      endpoint: ${S3_HOST}:${MINIO_S3_PORT}
      bucket: ${KFP_ARTIFACT_BUCKET}
      keyFormat: private-artifacts/${KUBEFLOW_PROFILE}/{{workflow.name}}/{{pod.name}}
      insecure: true
      accessKeySecret:
        name: ${KFP_S3_SECRET}
        key: accesskey
      secretKeySecret:
        name: ${KFP_S3_SECRET}
        key: secretkey
EOF2

unset ROOT_USER ROOT_PASSWORD KFP_SECRET_KEY POLICY_JSON
kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- rm -rf "${MC_CONFIG_DIR}" /tmp/kfp-policy.json || true

log "Restarting KFP components that consume object-store configuration"
kubectl rollout restart deployment/ml-pipeline -n "${KFP_NAMESPACE}"
kubectl rollout restart deployment/ml-pipeline-ui -n "${KFP_NAMESPACE}" >/dev/null 2>&1 || true
kubectl rollout status deployment/ml-pipeline -n "${KFP_NAMESPACE}" --timeout=600s

log "KFP external MinIO configuration completed"
echo "S3 endpoint : ${S3_ENDPOINT}"
echo "Bucket      : ${KFP_ARTIFACT_BUCKET}"
echo "Profile     : ${KUBEFLOW_PROFILE}"
