#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"

log "OS"
cat /etc/os-release

log "Kernel"
uname -r

log "CPU"
lscpu

log "Memory"
free -h

log "Disk"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS

log "Filesystem"
df -hT

log "Network"
ip -br addr

log "Routing"
ip route

log "Timezone"

echo "Current time:"
date

echo
echo "Timezone:"
timedatectl

log "Swap"
swapon --show || true

log "containerd"

if command -v containerd >/dev/null 2>&1; then
    containerd --version
else
    echo "Not installed"
fi

log "Kubernetes"

command -v kubeadm >/dev/null 2>&1 \
    && kubeadm version \
    || echo "kubeadm: not installed"

command -v kubelet >/dev/null 2>&1 \
    && kubelet --version \
    || echo "kubelet: not installed"

command -v kubectl >/dev/null 2>&1 \
    && kubectl version --client \
    || echo "kubectl: not installed"

log "NVIDIA"

if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi
else
    echo "GPU / NVIDIA Driver not detected"
fi
