#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/kubeflow.env"
source "${ROOT_DIR}/config/object-storage.env"
source "${ROOT_DIR}/config/mlflow.env"

require_command kubectl
require_command jq

require_value KUBEFLOW_PROFILE

require_value MINIO_NAMESPACE
require_value MINIO_S3_SERVICE
require_value MINIO_S3_PORT
require_value MINIO_CONSOLE_SERVICE
require_value MINIO_CONSOLE_NODEPORT
require_value KFP_ARTIFACT_BUCKET
require_value MLFLOW_ARTIFACT_BUCKET

require_value MLFLOW_NAMESPACE
require_value MLFLOW_RELEASE_NAME
require_value KUBEFLOW_EXTERNAL_URL


# ============================================================
# Constants
# ============================================================

KUBEFLOW_NAMESPACE="kubeflow"

DASHBOARD_CONFIGMAP="dashboard-config"

MLFLOW_SERVICE="${MLFLOW_RELEASE_NAME}-server"
MLFLOW_PREFIX="/mlflow"

MODEL_REGISTRY_DB="model-registry-db"
MODEL_REGISTRY_API="model-registry-deployment"
MODEL_REGISTRY_UI="model-registry-ui"

MODEL_REGISTRY_API_SERVICE="model-registry-service"
MODEL_REGISTRY_UI_SERVICE="model-registry-ui-service"

KUBEFLOW_EXTERNAL_URL="${KUBEFLOW_EXTERNAL_URL%/}"

KUBEFLOW_SCHEME="${KUBEFLOW_EXTERNAL_URL%%://*}"
KUBEFLOW_HOSTPORT="${KUBEFLOW_EXTERNAL_URL#*://}"
KUBEFLOW_HOST="${KUBEFLOW_HOSTPORT%%:*}"

MINIO_EXTERNAL_URL="${KUBEFLOW_SCHEME}://${KUBEFLOW_HOST}:${MINIO_CONSOLE_NODEPORT}"


# ============================================================
# Helper
# ============================================================

run_verify_script() {
    local name="$1"
    local script="$2"

    [[ -x "${script}" ]] \
        || fatal "Verification script is missing or not executable: ${script}"

    log "${name}"

    "${script}"
}


check_rollout() {
    local namespace="$1"
    local deployment="$2"

    kubectl rollout status \
        "deployment/${deployment}" \
        -n "${namespace}" \
        --timeout=2m
}


# ============================================================
# 1. Kubernetes / Kubeflow verification
# ============================================================

run_verify_script \
    "Running Kubeflow verification" \
    "${ROOT_DIR}/50-kubeflow/59-verify-kubeflow.sh"


# ============================================================
# 2. MinIO verification
# ============================================================

run_verify_script \
    "Running MinIO verification" \
    "${ROOT_DIR}/60-object-storage/63-verify-minio.sh"


# ============================================================
# 3. Kubeflow Pipelines verification
# ============================================================

run_verify_script \
    "Running Kubeflow Pipelines verification" \
    "${ROOT_DIR}/70-pipelines/73-verify-pipelines.sh"


# ============================================================
# 4. MLflow verification
#
# This performs:
#
# - MLflow health check
# - MySQL connectivity
# - Basic Auth SQLite verification
# - Experiment creation
# - Run creation
# - Metric logging
# - Artifact upload
#
# Therefore MLflow -> MinIO integration is also exercised.
# ============================================================

run_verify_script \
    "Running MLflow verification" \
    "${ROOT_DIR}/80-mlflow/86-verify-mlflow.sh"


# ============================================================
# 5. Model Registry
# ============================================================

log "Checking Model Registry deployments"


for deployment in \
    "${MODEL_REGISTRY_DB}" \
    "${MODEL_REGISTRY_API}" \
    "${MODEL_REGISTRY_UI}"
do
    kubectl get deployment \
        "${deployment}" \
        -n "${KUBEFLOW_PROFILE}" \
        >/dev/null \
        || fatal "Model Registry deployment not found: ${deployment}"

    check_rollout \
        "${KUBEFLOW_PROFILE}" \
        "${deployment}"
done


log "Checking Model Registry services"


for service in \
    "${MODEL_REGISTRY_DB}" \
    "${MODEL_REGISTRY_API_SERVICE}" \
    "${MODEL_REGISTRY_UI_SERVICE}"
do
    kubectl get service \
        "${service}" \
        -n "${KUBEFLOW_PROFILE}" \
        >/dev/null \
        || fatal "Model Registry service not found: ${service}"
done


log "Checking Model Registry VirtualServices"


for virtualservice in \
    model-registry \
    model-registry-ui
do
    kubectl get virtualservice \
        "${virtualservice}" \
        -n "${KUBEFLOW_PROFILE}" \
        >/dev/null \
        || fatal "Model Registry VirtualService not found: ${virtualservice}"
done


# ============================================================
# 6. Model Registry database PVC
# ============================================================

log "Checking Model Registry PostgreSQL PVC"


MODEL_REGISTRY_PVC="$(
    kubectl get pvc \
        -n "${KUBEFLOW_PROFILE}" \
        --no-headers \
        2>/dev/null \
    | awk '
        /metadata-postgres/ {
            print $1
            exit
        }
      '
)"


[[ -n "${MODEL_REGISTRY_PVC}" ]] \
    || fatal "Model Registry PostgreSQL PVC not found."


MODEL_REGISTRY_PVC_PHASE="$(
    kubectl get pvc \
        "${MODEL_REGISTRY_PVC}" \
        -n "${KUBEFLOW_PROFILE}" \
        -o jsonpath='{.status.phase}'
)"


[[ "${MODEL_REGISTRY_PVC_PHASE}" == "Bound" ]] \
    || fatal \
        "Model Registry PVC is not Bound: ${MODEL_REGISTRY_PVC} (${MODEL_REGISTRY_PVC_PHASE})"


echo "Model Registry PVC : ${MODEL_REGISTRY_PVC}"
echo "PVC phase          : ${MODEL_REGISTRY_PVC_PHASE}"


# ============================================================
# 7. KServe
# ============================================================

log "Checking KServe"


kubectl get deployment \
    kserve-controller-manager \
    -n "${KUBEFLOW_NAMESPACE}" \
    >/dev/null \
    || fatal "KServe controller deployment not found."


check_rollout \
    "${KUBEFLOW_NAMESPACE}" \
    kserve-controller-manager


kubectl get crd \
    inferenceservices.serving.kserve.io \
    >/dev/null \
    || fatal "KServe InferenceService CRD not found."


echo "KServe controller : PASS"
echo "InferenceService CRD: PASS"


# ============================================================
# 8. MinIO buckets
# ============================================================

log "Checking MLOps artifact buckets"


MINIO_POD="$(
    kubectl get pod \
        -n "${MINIO_NAMESPACE}" \
        -l app=minio \
        -o jsonpath='{.items[0].metadata.name}'
)"


[[ -n "${MINIO_POD}" ]] \
    || fatal "MinIO Pod not found."


ROOT_USER="$(
    kubectl get secret \
        "${MINIO_ROOT_SECRET}" \
        -n "${MINIO_NAMESPACE}" \
        -o jsonpath='{.data.rootUser}' \
    | base64 -d
)"


ROOT_PASSWORD="$(
    kubectl get secret \
        "${MINIO_ROOT_SECRET}" \
        -n "${MINIO_NAMESPACE}" \
        -o jsonpath='{.data.rootPassword}' \
    | base64 -d
)"


MC_CONFIG_DIR="/tmp/mlops-integration-mc"


kubectl exec \
    -n "${MINIO_NAMESPACE}" \
    "${MINIO_POD}" \
    -- rm -rf "${MC_CONFIG_DIR}" \
    >/dev/null 2>&1 \
    || true


kubectl exec \
    -n "${MINIO_NAMESPACE}" \
    "${MINIO_POD}" \
    -- mkdir -p "${MC_CONFIG_DIR}"


kubectl exec \
    -n "${MINIO_NAMESPACE}" \
    "${MINIO_POD}" \
    -- \
    /usr/local/bin/mc \
        --config-dir "${MC_CONFIG_DIR}" \
        alias set \
        local \
        "http://${MINIO_S3_SERVICE}:${MINIO_S3_PORT}" \
        "${ROOT_USER}" \
        "${ROOT_PASSWORD}" \
    >/dev/null


for bucket in \
    "${KFP_ARTIFACT_BUCKET}" \
    "${MLFLOW_ARTIFACT_BUCKET}"
do

    kubectl exec \
        -n "${MINIO_NAMESPACE}" \
        "${MINIO_POD}" \
        -- \
        /usr/local/bin/mc \
            --config-dir "${MC_CONFIG_DIR}" \
            stat \
            "local/${bucket}" \
        >/dev/null \
        || fatal "Required MinIO bucket is unavailable: ${bucket}"

    echo "Bucket ${bucket}: PASS"

done


kubectl exec \
    -n "${MINIO_NAMESPACE}" \
    "${MINIO_POD}" \
    -- rm -rf "${MC_CONFIG_DIR}" \
    >/dev/null 2>&1 \
    || true


unset ROOT_USER ROOT_PASSWORD


# ============================================================
# 9. Kubeflow Dashboard links
# ============================================================

log "Checking Kubeflow Dashboard integration"


LINKS="$(
    kubectl get configmap \
        "${DASHBOARD_CONFIGMAP}" \
        -n "${KUBEFLOW_NAMESPACE}" \
        -o jsonpath='{.data.links}'
)"


# MLflow:
# in-cluster application
echo "${LINKS}" \
| jq \
    --arg link "${MLFLOW_PREFIX}/" \
    -e \
    '
    .menuLinks[]
    |
    select(
        .text == "MLflow"
        and
        .link == $link
    )
    ' \
>/dev/null \
|| fatal "MLflow link is missing from Kubeflow Dashboard."


echo "Kubeflow -> MLflow link: PASS"


# MinIO:
# external application, iframe disabled
echo "${LINKS}" \
| jq \
    --arg link "${MINIO_EXTERNAL_URL}" \
    -e \
    '
    .externalLinks[]
    |
    select(
        .text == "MinIO"
        and
        .iframe == false
        and
        .link == $link
    )
    ' \
>/dev/null \
|| fatal "MinIO external link is missing from Kubeflow Dashboard."


echo "Kubeflow -> MinIO link: PASS"


# Model Registry is supplied by Kubeflow itself.
echo "${LINKS}" \
| jq \
    -e \
    '
    .menuLinks[]
    |
    select(
        (.text | ascii_downcase | contains("model"))
        and
        (.link | contains("model-registry"))
    )
    ' \
>/dev/null \
|| warn "Model Registry menu link was not detected in dashboard-config."


# ============================================================
# 10. MLflow route
# ============================================================

log "Checking MLflow Istio route"


kubectl get virtualservice \
    mlflow \
    -n "${MLFLOW_NAMESPACE}" \
    >/dev/null \
    || fatal "MLflow VirtualService not found."


MLFLOW_ROUTE="$(
    kubectl get virtualservice \
        mlflow \
        -n "${MLFLOW_NAMESPACE}" \
        -o json
)"


echo "${MLFLOW_ROUTE}" \
| jq \
    --arg prefix "${MLFLOW_PREFIX}/" \
    -e \
    '
    [
      .spec.http[]?.match[]?.uri.prefix
    ]
    |
    index($prefix) != null
    ' \
>/dev/null \
|| fatal "MLflow /mlflow/ route not found."


echo "MLflow VirtualService: PASS"


# ============================================================
# 11. MinIO Console NodePort
# ============================================================

log "Checking MinIO Console access configuration"


MINIO_SERVICE_TYPE="$(
    kubectl get service \
        "${MINIO_CONSOLE_SERVICE}" \
        -n "${MINIO_NAMESPACE}" \
        -o jsonpath='{.spec.type}'
)"


[[ "${MINIO_SERVICE_TYPE}" == "NodePort" ]] \
    || fatal \
        "MinIO Console Service is not NodePort: ${MINIO_SERVICE_TYPE}"


ACTUAL_MINIO_NODEPORT="$(
    kubectl get service \
        "${MINIO_CONSOLE_SERVICE}" \
        -n "${MINIO_NAMESPACE}" \
        -o jsonpath='{.spec.ports[0].nodePort}'
)"


[[ "${ACTUAL_MINIO_NODEPORT}" == "${MINIO_CONSOLE_NODEPORT}" ]] \
    || fatal \
        "MinIO Console NodePort mismatch: actual=${ACTUAL_MINIO_NODEPORT}, expected=${MINIO_CONSOLE_NODEPORT}"


echo "MinIO Console NodePort: ${ACTUAL_MINIO_NODEPORT}"
echo "MinIO Console URL     : ${MINIO_EXTERNAL_URL}"


# ============================================================
# 12. Cluster-wide Pod health
# ============================================================

log "Checking non-ready Pods"


NON_READY_PODS="$(
    kubectl get pods -A \
        --no-headers \
    | awk '
        $4 != "Running" &&
        $4 != "Completed" {
            print
        }
      '
)"


if [[ -n "${NON_READY_PODS}" ]]; then

    echo "${NON_READY_PODS}"

    warn "Some Pods are not Running/Completed."

else

    echo "All Pods are Running or Completed."

fi


# ============================================================
# 13. Deployment readiness
# ============================================================

log "Checking Deployment readiness"


NOT_READY_DEPLOYMENTS="$(
    kubectl get deployment -A \
        --no-headers \
    | awk '
        {
            split($3, ready, "/")

            if (ready[1] != ready[2]) {
                print
            }
        }
      '
)"


if [[ -n "${NOT_READY_DEPLOYMENTS}" ]]; then

    echo "${NOT_READY_DEPLOYMENTS}"

    warn "Some Deployments are not fully ready."

else

    echo "All Deployments are fully ready."

fi


# ============================================================
# Completed
# ============================================================

log "MLOps infrastructure integration verification completed"


echo
echo "Verified:"
echo "  Kubernetes / Kubeflow"
echo "  Kubeflow Model Registry"
echo "  KServe"
echo "  Kubeflow Pipelines"
echo "  MinIO"
echo "  MLflow"
echo "  KFP -> MinIO"
echo "  MLflow -> MinIO"
echo "  Kubeflow -> MLflow UI"
echo "  Kubeflow -> MinIO Console"
echo

echo "Kubeflow:"
echo "  ${KUBEFLOW_EXTERNAL_URL}/"

echo
echo "MLflow:"
echo "  ${KUBEFLOW_EXTERNAL_URL}/_/mlflow/"

echo
echo "MinIO:"
echo "  ${MINIO_EXTERNAL_URL}"

echo
echo "Model Registry:"
echo "  Open Model Registry from the Kubeflow Dashboard."
echo
