#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/versions.env"

require_root
check_ubuntu_2404

require_value KUBERNETES_MINOR
require_value KUBERNETES_APT_VERSION

log "Adding Kubernetes repository: ${KUBERNETES_MINOR}"

install -m 0755 -d /etc/apt/keyrings

rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

curl -fsSL \
    "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/Release.key" \
    | gpg --dearmor \
    -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat > /etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/ /
EOF

apt-get update

log "Checking Kubernetes package version"

AVAILABLE="$(
    apt-cache madison kubeadm \
    | awk '{print $3}' \
    | grep -Fx "${KUBERNETES_APT_VERSION}" \
    || true
)"

if [[ -z "${AVAILABLE}" ]]; then
    echo
    echo "Requested:"
    echo "${KUBERNETES_APT_VERSION}"
    echo
    echo "Available:"
    apt-cache madison kubeadm

    fatal "Requested Kubernetes version is unavailable."
fi

log "Installing Kubernetes ${KUBERNETES_APT_VERSION}"

apt-mark unhold kubelet kubeadm kubectl cri-tools \
    2>/dev/null || true

apt-get install -y \
    kubelet="${KUBERNETES_APT_VERSION}" \
    kubeadm="${KUBERNETES_APT_VERSION}" \
    kubectl="${KUBERNETES_APT_VERSION}" \
    cri-tools
apt-mark hold \
    kubelet \
    kubeadm \
    kubectl \
    cri-tools
systemctl enable kubelet

log "Configuring crictl"

cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

log "Verification"

kubeadm version
kubelet --version
kubectl version --client
crictl version

log "Checking CRI connectivity"

crictl info >/dev/null

log "Kubernetes packages installed successfully"
