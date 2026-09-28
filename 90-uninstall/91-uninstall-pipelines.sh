#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/90-common.sh"

require_command kubectl

KF_DIR="${ROOT_DIR}/third_party/kubeflow-community-distribution"
CUSTOM_DIR="${KF_DIR}/applications/pipeline/upstream/env/platform-agnostic-multi-user-external-s3"

# ============================================================
# 1. Remove Profile-scoped KFP configuration
#
# 72-configure-external-s3.sh creates these objects in the Profile
# namespace. 74/75 smoke-test scripts additionally create
# mlops-smoke-credentials.
#
# Discover namespaces from live cluster state; do not depend on config files.
# ============================================================

log "Removing KFP Profile-scoped configuration"

PROFILE_NAMESPACES="$({
    resource_namespaces configmap kfp-launcher 2>/dev/null || true
    resource_namespaces configmap metadata-grpc-configmap 2>/dev/null || true
    resource_namespaces configmap artifact-repositories 2>/dev/null || true
    resource_namespaces secret mlpipeline-minio-artifact 2>/dev/null || true
    resource_namespaces secret mlops-smoke-credentials 2>/dev/null || true
} | unique_nonempty)"

while IFS= read -r ns; do
    [[ -n "${ns}" ]] || continue

    # The kubeflow namespace also owns KFP control-plane objects. Only remove
    # Profile-scoped objects here; cluster/control-plane cleanup happens below.
    if [[ "${ns}" != "kubeflow" ]]; then
        log "Cleaning KFP Profile resources from namespace: ${ns}"

        kubectl delete configmap \
            kfp-launcher \
            metadata-grpc-configmap \
            artifact-repositories \
            -n "${ns}" \
            --ignore-not-found=true || true

        kubectl delete secret \
            mlpipeline-minio-artifact \
            mlops-smoke-credentials \
            -n "${ns}" \
            --ignore-not-found=true || true

        # Remove smoke-test workflows/runs that may still exist in the Profile.
        kubectl delete workflow \
            -n "${ns}" \
            -l pipelines.kubeflow.org/v2_component=true \
            --ignore-not-found=true \
            --wait=false \
            2>/dev/null || true
    fi
done <<< "${PROFILE_NAMESPACES}"


# Backward compatibility with an older secret name, if present anywhere.
while IFS= read -r ns; do
    [[ -n "${ns}" ]] || continue
    kubectl delete secret kfp-s3-credentials \
        -n "${ns}" \
        --ignore-not-found=true || true
done < <(resource_namespaces secret kfp-s3-credentials | unique_nonempty)


# KFP control-plane copy created by 72.
kubectl delete secret mlpipeline-minio-artifact \
    -n kubeflow \
    --ignore-not-found=true \
    2>/dev/null || true


# ============================================================
# 2. Remove KFP control plane
# ============================================================

if [[ -d "${CUSTOM_DIR}" ]] && command -v kustomize >/dev/null 2>&1; then
    log "Deleting KFP resources from the generated Kustomization"

    kustomize build "${CUSTOM_DIR}" \
        | kubectl delete -f - \
            --ignore-not-found=true \
            --wait=false || true
else
    warn "KFP Kustomization is unavailable. Falling back to labels and known resource names."

    for kind in \
        deployment statefulset daemonset service job cronjob \
        configmap secret serviceaccount role rolebinding; do

        kubectl delete "${kind}" \
            -n kubeflow \
            -l application-crd-id=kubeflow-pipelines \
            --ignore-not-found=true \
            --wait=false \
            2>/dev/null || true
    done

    for crd in \
        compositecontrollers.metacontroller.k8s.io \
        controllerrevisions.metacontroller.k8s.io \
        decoratorcontrollers.metacontroller.k8s.io \
        workflows.argoproj.io \
        workflowtemplates.argoproj.io \
        clusterworkflowtemplates.argoproj.io \
        cronworkflows.argoproj.io; do

        kubectl delete crd "${crd}" \
            --ignore-not-found=true \
            --wait=false \
            2>/dev/null || true
    done
fi


# ============================================================
# 3. Verification
# ============================================================

log "KFP uninstall verification"

if kubectl get deployment -n kubeflow -o name 2>/dev/null \
    | grep -Eq 'ml-pipeline|cache-server|metadata-writer'; then

    warn "Some KFP deployments still remain in namespace kubeflow."

    kubectl get deployment -n kubeflow 2>/dev/null \
        | grep -E 'ml-pipeline|cache-server|metadata|mysql|workflow' \
        || true
else
    echo "KFP workloads removed."
fi

log "Pipelines uninstall completed"
