#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/kubeflow.env"
source "${ROOT_DIR}/config/object-storage.env"

require_command kubectl
require_value KUBEFLOW_PROFILE
require_value MINIO_NAMESPACE
require_value MINIO_S3_SERVICE
require_value MINIO_S3_PORT
require_value KFP_ARTIFACT_BUCKET
require_value KFP_S3_SECRET

KFP_NAMESPACE="kubeflow"
S3_HOST="${MINIO_S3_SERVICE}.${MINIO_NAMESPACE}.svc.cluster.local"

log "Waiting for core KFP deployments"
for deploy in ml-pipeline ml-pipeline-ui; do
  kubectl rollout status "deployment/${deploy}" -n "${KFP_NAMESPACE}" --timeout=600s
 done

log "KFP deployment and pod status"
kubectl get deployment -n "${KFP_NAMESPACE}" | grep -E 'ml-pipeline|cache|metadata|mysql|workflow' || true
kubectl get pods -n "${KFP_NAMESPACE}" -o wide | grep -E 'ml-pipeline|cache|metadata|mysql|workflow' || true

log "Checking SeaweedFS-specific resources are absent"
! kubectl get deployment seaweedfs -n "${KFP_NAMESPACE}" >/dev/null 2>&1 \
  || fatal "Bundled SeaweedFS deployment exists unexpectedly."
! kubectl get deployment kubeflow-pipelines-profile-controller -n "${KFP_NAMESPACE}" >/dev/null 2>&1 \
  || fatal "SeaweedFS-specific pipelines profile controller exists unexpectedly."

log "Checking KFP API object-store settings"
ACTUAL_BUCKET="$(kubectl get configmap pipeline-install-config -n "${KFP_NAMESPACE}" -o jsonpath='{.data.bucketName}')"
[[ "${ACTUAL_BUCKET}" == "${KFP_ARTIFACT_BUCKET}" ]] \
  || fatal "Unexpected KFP bucket: ${ACTUAL_BUCKET}"

kubectl get deployment ml-pipeline -n "${KFP_NAMESPACE}" \
  -o jsonpath='{range .spec.template.spec.containers[?(@.name=="ml-pipeline-api-server")].env[*]}{.name}={.value}{"\n"}{end}' \
  | grep -E '^OBJECTSTORECONFIG_(HOST|PORT|SECURE|REGION)=' || true

log "Checking profile-scoped resources"
for resource in \
  "secret/${KFP_S3_SECRET}" \
  "configmap/kfp-launcher" \
  "configmap/metadata-grpc-configmap" \
  "configmap/artifact-repositories"; do
  kubectl get "${resource}" -n "${KUBEFLOW_PROFILE}" >/dev/null \
    || fatal "Missing profile KFP resource: ${resource}"
done

log "Checking MinIO bucket with KFP runtime credentials"
MINIO_POD="$(kubectl get pod -n "${MINIO_NAMESPACE}" -l app=minio -o jsonpath='{.items[0].metadata.name}')"
ACCESS_KEY="$(kubectl get secret "${KFP_S3_SECRET}" -n "${KFP_NAMESPACE}" -o jsonpath='{.data.accesskey}' | base64 -d)"
SECRET_KEY="$(kubectl get secret "${KFP_S3_SECRET}" -n "${KFP_NAMESPACE}" -o jsonpath='{.data.secretkey}' | base64 -d)"
MC_CONFIG_DIR="/tmp/kfp-verify-mc"
kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- rm -rf "${MC_CONFIG_DIR}" || true
kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- mkdir -p "${MC_CONFIG_DIR}"
kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- \
  /usr/local/bin/mc --config-dir "${MC_CONFIG_DIR}" alias set kfp "http://${S3_HOST}:${MINIO_S3_PORT}" "${ACCESS_KEY}" "${SECRET_KEY}" >/dev/null
kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- \
  /usr/local/bin/mc --config-dir "${MC_CONFIG_DIR}" stat "kfp/${KFP_ARTIFACT_BUCKET}" >/dev/null \
  || fatal "KFP runtime credential cannot access bucket ${KFP_ARTIFACT_BUCKET}."
kubectl exec -n "${MINIO_NAMESPACE}" "${MINIO_POD}" -- rm -rf "${MC_CONFIG_DIR}" || true
unset ACCESS_KEY SECRET_KEY

log "Checking for non-ready KFP pods"
NON_READY="$(kubectl get pods -n "${KFP_NAMESPACE}" --no-headers | grep -E 'ml-pipeline|cache|metadata|mysql|workflow' | awk '$3 != "Running" && $3 != "Completed" {print}' || true)"
if [[ -n "${NON_READY}" ]]; then
  echo "${NON_READY}"
  fatal "Some KFP pods are not Running/Completed."
fi

log "Kubeflow Pipelines verification completed"
echo "S3 endpoint : http://${S3_HOST}:${MINIO_S3_PORT}"
echo "Bucket      : ${KFP_ARTIFACT_BUCKET}"
echo "Profile     : ${KUBEFLOW_PROFILE}"
