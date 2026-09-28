#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/cluster.env"

require_root
check_ubuntu_2404

require_command containerd
require_command kubeadm

log "Checking control-plane IP"

if ! ip -o addr show \
    | grep -Fq "${CONTROL_PLANE_IP}/"; then

    echo "Configured IP: ${CONTROL_PLANE_IP}"
    echo
    ip -br addr

    fatal "CONTROL_PLANE_IP does not exist on this host."
fi

log "Checking containerd"

systemctl is-active --quiet containerd \
    || fatal "containerd is not running."

if [[ -f /etc/kubernetes/admin.conf ]]; then

    warn "Cluster is already initialized."
    warn "Skipping kubeadm init."

else

    log "Initializing Kubernetes"

    kubeadm init \
        --apiserver-advertise-address="${CONTROL_PLANE_IP}" \
        --pod-network-cidr="${POD_CIDR}" \
        --cri-socket="${CRI_SOCKET}" \
        --node-name="$(hostname -s)"

fi

export KUBECONFIG=/etc/kubernetes/admin.conf

TARGET_USER="${SUDO_USER:-root}"

TARGET_HOME="$(
    getent passwd "${TARGET_USER}" \
    | cut -d: -f6
)"

log "Configuring kubectl for ${TARGET_USER}"

mkdir -p "${TARGET_HOME}/.kube"

cp /etc/kubernetes/admin.conf \
    "${TARGET_HOME}/.kube/config"

chown -R \
    "${TARGET_USER}:${TARGET_USER}" \
    "${TARGET_HOME}/.kube"

log "Removing control-plane NoSchedule taint"

kubectl taint nodes \
    --all \
    node-role.kubernetes.io/control-plane- \
    2>/dev/null || true

log "Current state"

kubectl get nodes -o wide

echo
echo "NotReady before CNI installation is expected."
