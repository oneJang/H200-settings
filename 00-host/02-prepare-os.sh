#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/cluster.env"

require_root
check_ubuntu_2404

log "Installing base packages"

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    gpg \
    jq \
    apt-transport-https

log "Setting timezone: ${TIMEZONE}"

timedatectl set-timezone "${TIMEZONE}"

log "Disabling swap"

swapoff -a

sed -ri \
    '/^[^#].*[[:space:]]swap[[:space:]]/ s/^/#/' \
    /etc/fstab

log "Loading kernel modules"

cat > /etc/modules-load.d/kubernetes.conf <<'EOF'
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

log "Setting sysctl"

cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

log "Verification"

echo "--- swap ---"
swapon --show || true

echo "--- modules ---"
lsmod | grep -E 'overlay|br_netfilter'

echo "--- sysctl ---"

sysctl net.bridge.bridge-nf-call-iptables
sysctl net.bridge.bridge-nf-call-ip6tables
sysctl net.ipv4.ip_forward

log "Host preparation completed"
