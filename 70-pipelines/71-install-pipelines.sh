#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/kubeflow.env"
source "${ROOT_DIR}/config/object-storage.env"

require_command kubectl
require_command kustomize
require_command sed
require_value KUBEFLOW_PROFILE
require_value MINIO_NAMESPACE
require_value MINIO_S3_SERVICE

KF_DIR="${ROOT_DIR}/third_party/kubeflow-community-distribution"
UPSTREAM_DIR="${KF_DIR}/applications/pipeline/upstream"
SOURCE_OVERLAY_REL="env/platform-agnostic-multi-user-external-s3"
GENERATED_DIR="${ROOT_DIR}/generated"
RENDERED_MANIFEST="${GENERATED_DIR}/kfp-external-minio.yaml"

[[ -d "${UPSTREAM_DIR}" ]] || fatal "Kubeflow Community Distribution source is missing. Run 52-fetch-kubeflow.sh first."
[[ -f "${UPSTREAM_DIR}/${SOURCE_OVERLAY_REL}/kustomization.yaml" ]] || fatal "KFP external-S3 overlay is missing: ${UPSTREAM_DIR}/${SOURCE_OVERLAY_REL}"

log "Checking external MinIO"
kubectl get svc "${MINIO_S3_SERVICE}" -n "${MINIO_NAMESPACE}" >/dev/null 2>&1 \
  || fatal "MinIO service not found: ${MINIO_NAMESPACE}/${MINIO_S3_SERVICE}"
kubectl get namespace "${KUBEFLOW_PROFILE}" >/dev/null 2>&1 \
  || fatal "Kubeflow profile namespace not found: ${KUBEFLOW_PROFILE}. Run 57-create-kubeflow-profile.sh first."

# Kubeflow 26.03.1 already ships an external-S3 KFP overlay. Use that upstream
# layout instead of rebuilding the resource graph from a new sibling overlay.
#
# We only need to remove the pipelines profile controller because this KCD
# version's controller is tied to the bundled SeaweedFS IAM flow. 72 provisions
# the profile-specific KFP resources explicitly for MinIO.
#
# Work on a temporary copy so third_party remains an immutable vendor snapshot.
TMP_DIR="$(mktemp -d /tmp/h200-kfp-render.XXXXXX)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

WORK_DIR="${TMP_DIR}/upstream"
log "Preparing immutable KFP render workspace"
cp -a "${UPSTREAM_DIR}" "${WORK_DIR}"

MULTI_USER_KUSTOMIZATION="${WORK_DIR}/base/installs/multi-user/kustomization.yaml"
EXTERNAL_S3_KUSTOMIZATION="${WORK_DIR}/${SOURCE_OVERLAY_REL}/kustomization.yaml"

[[ -f "${MULTI_USER_KUSTOMIZATION}" ]] || fatal "KFP multi-user kustomization is missing."
[[ -f "${EXTERNAL_S3_KUSTOMIZATION}" ]] || fatal "KFP external-S3 kustomization is missing."

log "Removing SeaweedFS-specific KFP profile controller from render workspace"
sed -i '/^[[:space:]]*-[[:space:]]*pipelines-profile-controller[[:space:]]*$/d' \
  "${MULTI_USER_KUSTOMIZATION}"

# Metacontroller is only pulled into this overlay for the pipelines profile
# controller. Once that controller is omitted, do not install an otherwise
# unused cluster-scoped controller.
sed -i '\#../../third-party/metacontroller/base#d' \
  "${EXTERNAL_S3_KUSTOMIZATION}"

if grep -Eq '^[[:space:]]*-[[:space:]]*pipelines-profile-controller[[:space:]]*$' \
    "${MULTI_USER_KUSTOMIZATION}"; then
  fatal "Failed to remove pipelines-profile-controller from KFP render workspace."
fi

mkdir -p "${GENERATED_DIR}"

log "Rendering Kubeflow Pipelines external-S3 manifests"
kustomize build "${WORK_DIR}/${SOURCE_OVERLAY_REL}" > "${RENDERED_MANIFEST}"

[[ -s "${RENDERED_MANIFEST}" ]] || fatal "Rendered KFP manifest is empty."

# Guardrails: neither bundled SeaweedFS nor the SeaweedFS-specific profile
# controller should be part of this installation.
if grep -Eq '^[[:space:]]*name:[[:space:]]*seaweedfs([[:space:]]|$)' "${RENDERED_MANIFEST}"; then
  fatal "Rendered KFP manifest unexpectedly contains bundled SeaweedFS."
fi

if grep -Eq '^[[:space:]]*name:[[:space:]]*kubeflow-pipelines-profile-controller([[:space:]]|$)' "${RENDERED_MANIFEST}"; then
  fatal "Rendered KFP manifest unexpectedly contains kubeflow-pipelines-profile-controller."
fi

log "Validating rendered KFP manifests with Kubernetes API"
kubectl apply --dry-run=server -f "${RENDERED_MANIFEST}" >/dev/null

log "Installing Kubeflow Pipelines with external object storage"
kubectl apply -f "${RENDERED_MANIFEST}"

if kubectl get deployment seaweedfs -n kubeflow >/dev/null 2>&1; then
  fatal "Bundled SeaweedFS is present in kubeflow namespace. Remove the old KFP/object-store deployment before continuing."
fi

if kubectl get deployment kubeflow-pipelines-profile-controller -n kubeflow >/dev/null 2>&1; then
  fatal "kubeflow-pipelines-profile-controller is present from a previous installation. Run 91-uninstall-pipelines.sh and retry 71."
fi

log "KFP base resources applied"
echo "Rendered manifest: ${RENDERED_MANIFEST}"
echo "Next: run 72-configure-external-s3.sh before waiting for ml-pipeline readiness."

