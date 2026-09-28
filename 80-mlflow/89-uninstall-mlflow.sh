#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/90-uninstall/90-common.sh"

require_command kubectl

PURGE_DATA=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge-data)
            PURGE_DATA=true
            shift
            ;;
        *)
            fatal "Unknown option: $1"
            ;;
    esac
done

MLFLOW_NAMESPACE="mlflow"
KUBEFLOW_NAMESPACE="kubeflow"
ISTIO_NAMESPACE="istio-system"
DASHBOARD_CONFIGMAP="dashboard-config"
DASHBOARD_DEPLOYMENT="dashboard"
JWT_POLICY="istio-ingressgateway-require-jwt"
MLFLOW_PREFIX="/mlflow"

TMP_DIR="$(mktemp -d /tmp/h200-uninstall-mlflow.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ============================================================
# 1. Remove Kubeflow / Istio integration created by 87
# ============================================================

log "Removing MLflow Istio VirtualService"

while IFS= read -r ns; do
    [[ -n "${ns}" ]] || continue
    kubectl delete virtualservice mlflow \
        -n "${ns}" \
        --ignore-not-found=true \
        --wait=false \
        2>/dev/null || true
done < <(resource_namespaces virtualservice mlflow | unique_nonempty)


# Remove only the MLflow Dashboard entry. Keep the MinIO external link;
# object-storage has its own uninstall lifecycle.
if namespace_exists "${KUBEFLOW_NAMESPACE}" \
    && kubectl get configmap "${DASHBOARD_CONFIGMAP}" \
        -n "${KUBEFLOW_NAMESPACE}" >/dev/null 2>&1; then

    if command -v jq >/dev/null 2>&1; then
        log "Removing MLflow link from Kubeflow Dashboard"

        DASHBOARD_JSON="${TMP_DIR}/dashboard-config.json"

        kubectl get configmap "${DASHBOARD_CONFIGMAP}" \
            -n "${KUBEFLOW_NAMESPACE}" \
            -o json \
        | jq '
            .data.links |=
            (
              fromjson
              | .menuLinks = [(.menuLinks // [])[] | select(.text != "MLflow")]
              | tojson
            )
            | del(
                .metadata.creationTimestamp,
                .metadata.managedFields,
                .metadata.resourceVersion,
                .metadata.uid
              )
          ' > "${DASHBOARD_JSON}"

        kubectl apply -f "${DASHBOARD_JSON}" >/dev/null || true

        if kubectl get deployment "${DASHBOARD_DEPLOYMENT}" \
            -n "${KUBEFLOW_NAMESPACE}" >/dev/null 2>&1; then
            kubectl rollout restart deployment/"${DASHBOARD_DEPLOYMENT}" \
                -n "${KUBEFLOW_NAMESPACE}" >/dev/null || true
        fi
    else
        warn "jq is unavailable; Kubeflow Dashboard MLflow link was not cleaned up."
    fi
fi


# Remove only MLflow path exceptions added by 87.
if namespace_exists "${ISTIO_NAMESPACE}" \
    && kubectl get authorizationpolicy "${JWT_POLICY}" \
        -n "${ISTIO_NAMESPACE}" >/dev/null 2>&1; then

    if command -v jq >/dev/null 2>&1; then
        log "Removing MLflow JWT exceptions"

        POLICY_JSON="${TMP_DIR}/jwt-policy.json"

        kubectl get authorizationpolicy "${JWT_POLICY}" \
            -n "${ISTIO_NAMESPACE}" \
            -o json \
        | jq --arg mlflow "${MLFLOW_PREFIX}" '
            [
              $mlflow,
              ($mlflow + "/*"),
              ($mlflow + "/**"),
              ("/_" + $mlflow),
              ("/_" + $mlflow + "/*"),
              ("/_" + $mlflow + "/**")
            ] as $remove
            |
            if (.spec.rules[0].to[0].operation.notPaths? | type) == "array" then
              .spec.rules[0].to[0].operation.notPaths |=
                [ .[] as $p | select(($remove | index($p)) == null) | $p ]
            else
              .
            end
            |
            del(
              .metadata.creationTimestamp,
              .metadata.generation,
              .metadata.managedFields,
              .metadata.resourceVersion,
              .metadata.uid
            )
          ' > "${POLICY_JSON}"

        kubectl apply -f "${POLICY_JSON}" >/dev/null || true
    else
        warn "jq is unavailable; MLflow JWT exceptions were not cleaned up."
    fi
fi


# ============================================================
# 2. Remove MLflow Helm release(s)
# ============================================================

if command -v helm >/dev/null 2>&1; then
    while read -r release namespace _; do
        [[ -n "${release:-}" && -n "${namespace:-}" ]] || continue
        [[ "${namespace}" == "${MLFLOW_NAMESPACE}" ]] || continue

        if [[ "${release}" == "mlflow" || "${release}" == *mlflow* ]]; then
            log "helm uninstall ${release} -n ${namespace}"
            helm uninstall "${release}" -n "${namespace}" || true
        fi
    done < <(helm list -A --no-headers 2>/dev/null || true)
fi


# ============================================================
# 3. Remove MLflow workloads / backend resources
# ============================================================

if namespace_exists "${MLFLOW_NAMESPACE}"; then
    log "Removing MLflow workloads and backend resources"

    # Fallback cleanup for environments where Helm metadata is unavailable.
    # These deletes are harmless when Helm already removed the resources.
    kubectl delete deployment mlflow-server \
        -n "${MLFLOW_NAMESPACE}" \
        --ignore-not-found=true \
        --wait=false || true

    kubectl delete service mlflow-server \
        -n "${MLFLOW_NAMESPACE}" \
        --ignore-not-found=true || true

    kubectl delete statefulset mlflow-mysql \
        -n "${MLFLOW_NAMESPACE}" \
        --ignore-not-found=true \
        --wait=false || true

    kubectl delete service mlflow-mysql \
        -n "${MLFLOW_NAMESPACE}" \
        --ignore-not-found=true || true

    kubectl delete configmap mlflow-mysql-config \
        -n "${MLFLOW_NAMESPACE}" \
        --ignore-not-found=true || true

    if [[ "${PURGE_DATA}" == "true" ]]; then
        warn "PURGE DATA enabled for MLflow."

        kubectl delete pvc --all \
            -n "${MLFLOW_NAMESPACE}" \
            --ignore-not-found=true \
            --wait=false || true

        kubectl delete secret \
            mlflow-mysql-secret \
            mlflow-backend-secret \
            mlflow-artifact-secret \
            mlflow-auth-secret \
            mlflow-auth-config \
            -n "${MLFLOW_NAMESPACE}" \
            --ignore-not-found=true || true

        safe_delete_namespace "${MLFLOW_NAMESPACE}"
    else
        log "MLflow PVCs and credential Secrets preserved. Use --purge-data to delete them."
    fi
fi

log "MLflow uninstall completed"
