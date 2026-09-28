#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT_DIR}/lib/common.sh"

require_root
require_command kubeadm

[[ "${1:-}" == "--yes-really-reset" ]] \
    || fatal "Destructive operation. Re-run with --yes-really-reset"

log "Resetting kubeadm cluster"
kubeadm reset -f

rm -rf /etc/cni/net.d /var/lib/cni /var/lib/calico /etc/kubernetes

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    USER_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
    [[ -n "${USER_HOME}" ]] && rm -rf "${USER_HOME}/.kube"
fi

log "Kubernetes cluster reset completed"
echo "Kubernetes packages and containerd are intentionally left installed."
