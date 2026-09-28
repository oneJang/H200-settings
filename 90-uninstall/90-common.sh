#!/usr/bin/env bash
# Shared helpers for uninstall scripts.
# Intentionally does NOT source anything from config/*.env.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"

namespace_exists() {
    kubectl get namespace "$1" >/dev/null 2>&1
}

helm_release_namespace() {
    local release="$1"
    helm list -A -q 2>/dev/null | grep -Fxq "${release}" || return 1
    helm list -A 2>/dev/null | awk -v r="${release}" '$1==r {print $2; exit}'
}

resource_namespaces() {
    local resource="$1"
    local name="$2"
    kubectl get "${resource}" -A \
        -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name' \
        --no-headers 2>/dev/null \
        | awk -v n="${name}" '$2==n {print $1}'
}

unique_nonempty() {
    awk 'NF && !seen[$0]++'
}

preserve_namespace_pvcs() {
    local ns="$1"
    namespace_exists "${ns}" || return 0

    while IFS= read -r pvc; do
        [[ -n "${pvc}" ]] || continue
        kubectl annotate -n "${ns}" "${pvc}" \
            helm.sh/resource-policy=keep \
            --overwrite >/dev/null 2>&1 || true
    done < <(kubectl get pvc -n "${ns}" -o name 2>/dev/null || true)
}

safe_delete_namespace() {
    local ns="$1"
    namespace_exists "${ns}" || return 0
    kubectl delete namespace "${ns}" --wait=false || true
}
