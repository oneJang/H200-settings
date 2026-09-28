#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/90-common.sh"

require_command kubectl

PURGE_DATA=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge-data) PURGE_DATA=true; shift ;;
        *) fatal "Unknown option: $1" ;;
    esac
done

KF_DIR="${ROOT_DIR}/third_party/kubeflow-community-distribution"

kdelete() {
    local rel="$1"
    local path="${KF_DIR}/${rel}"

    [[ -d "${path}" ]] || return 0
    command -v kustomize >/dev/null 2>&1 || return 0

    log "Removing ${rel}"
    kustomize build "${path}" \
        | kubectl delete -f - --ignore-not-found=true --wait=false || true
}

fdelete() {
    local rel="$1"
    local path="${KF_DIR}/${rel}"
    [[ -f "${path}" ]] || return 0
    kubectl delete -f "${path}" --ignore-not-found=true --wait=false || true
}

# Profiles are discovered from the live cluster. No kubeflow.env required.
mapfile -t PROFILE_NAMES < <(
    kubectl get profiles.kubeflow.org \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
        2>/dev/null || true
)

if [[ "${PURGE_DATA}" != "true" && ${#PROFILE_NAMES[@]} -gt 0 ]]; then
    warn "Preserving Kubeflow profile namespaces and their PVCs:"
    printf '  - %s\n' "${PROFILE_NAMES[@]}"
    for ns in "${PROFILE_NAMES[@]}"; do
        preserve_namespace_pvcs "${ns}"
    done
fi

# Model Registry is installed per Profile namespace. The upstream 26.03.1
# overlay embeds kubeflow-user-example-com, so render a temporary copy for each
# live Profile namespace instead of depending on config/kubeflow.env.
if command -v kustomize >/dev/null 2>&1 && [[ -d "${KF_DIR}/applications/hub" ]]; then
    for ns in "${PROFILE_NAMES[@]}"; do
        [[ -n "${ns}" ]] || continue

        TMP_MR_DIR="$(mktemp -d /tmp/h200-uninstall-model-registry.XXXXXX)"
        cp -a "${KF_DIR}/applications/hub" "${TMP_MR_DIR}/hub"
        sed -i \
            "s/kubeflow-user-example-com/${ns}/g" \
            "${TMP_MR_DIR}/hub/overlays/model-registry/kustomization.yaml"

        log "Removing Model Registry from profile namespace: ${ns}"

        if [[ "${PURGE_DATA}" == "true" ]]; then
            kustomize build "${TMP_MR_DIR}/hub/overlays/model-registry" \
                | kubectl delete -f - --ignore-not-found=true --wait=false \
                || true
        else
            # Preserve the Model Registry PostgreSQL PVC while removing the
            # remaining Model Registry resources.
            kustomize build "${TMP_MR_DIR}/hub/overlays/model-registry" \
                | awk '
                    BEGIN { RS="---"; ORS="---\n" }
                    $0 !~ /kind:[[:space:]]*PersistentVolumeClaim/ {
                        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
                        if (length($0) > 0) print $0
                    }
                  ' \
                | kubectl delete -f - --ignore-not-found=true --wait=false \
                || true
        fi

        rm -rf "${TMP_MR_DIR}"
    done
fi

log "Removing Kubeflow training components"
kdelete applications/notebooks-v1/overlays/istio
kdelete applications/katib/upstream/installs/katib-with-kubeflow
fdelete applications/trainer/upstream/overlays/kubeflow-platform/kubeflow-trainer-roles.yaml
kdelete applications/trainer/upstream/overlays/runtimes
kdelete applications/trainer/overlays
kdelete applications/trainer/upstream/base/crds

log "Removing KServe"
kdelete applications/kserve/models-web-app/overlays/kubeflow
kdelete applications/kserve/kserve

log "Removing Knative Serving"
kdelete common/istio/cluster-local-gateway/overlays/m2m-auth
kdelete common/knative/knative-serving/overlays/gateways

log "Removing Kubeflow dashboard and common components"
kdelete applications/dashboard/overlays/istio
kdelete common/dex/overlays/oauth2-proxy
kdelete common/kubeflow-roles/base
kdelete common/istio/kubeflow-istio-resources/base
kdelete common/oauth2-proxy/overlays/m2m-dex-only
kdelete common/istio/istio-install/overlays/oauth2-proxy
kdelete common/istio/istio-namespace/base
kdelete common/istio/istio-crds/base
kdelete common/cert-manager/overlays/kubeflow
kdelete common/cert-manager/base

if [[ "${PURGE_DATA}" == "true" ]]; then
    if [[ ${#PROFILE_NAMES[@]} -gt 0 ]]; then
        warn "PURGE DATA enabled: deleting Kubeflow profiles and profile namespaces."
        for profile in "${PROFILE_NAMES[@]}"; do
            kubectl delete profile "${profile}" --ignore-not-found=true --wait=false 2>/dev/null || true
            safe_delete_namespace "${profile}"
        done
    fi
else
    # If the Profile CRD is removed as part of the dashboard manifest, the
    # namespaces remain. We intentionally do not delete those namespaces.
    echo "Profile namespaces were preserved."
fi

# These are platform namespaces, not user data namespaces. Remove them after
# their manifests have been deleted. kubeflow-system is included for Trainer.
for ns in kubeflow auth oauth2-proxy knative-serving knative-eventing istio-system cert-manager kubeflow-system; do
    safe_delete_namespace "${ns}"
done

log "Kubeflow uninstall completed"
