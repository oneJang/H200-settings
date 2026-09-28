#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/versions.env"

require_root
check_ubuntu_2404
require_value CONTAINERD_VERSION

log "OS verification"

source /etc/os-release

echo "OS        : ${PRETTY_NAME}"
echo "Codename  : ${VERSION_CODENAME}"

log "Installing repository prerequisites"

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    gpg

log "Adding Docker APT repository"

install -m 0755 -d /etc/apt/keyrings

curl -fsSL \
    https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc

chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable
EOF

log "Docker repository"

cat /etc/apt/sources.list.d/docker.list

if ! grep -q "ubuntu ${VERSION_CODENAME} stable" \
    /etc/apt/sources.list.d/docker.list; then

    fatal "Docker repository codename mismatch."
fi

apt-get update

log "Finding containerd ${CONTAINERD_VERSION}"

CONTAINERD_APT_VERSION="$(
    apt-cache madison containerd.io \
    | awk '{print $3}' \
    | grep "^${CONTAINERD_VERSION}-" \
    | head -n1 || true
)"

if [[ -z "${CONTAINERD_APT_VERSION}" ]]; then
    echo
    echo "Available versions:"
    apt-cache madison containerd.io
    echo

    fatal "containerd ${CONTAINERD_VERSION} is unavailable."
fi

echo
echo "Selected containerd package:"
echo "${CONTAINERD_APT_VERSION}"
echo

log "Installing containerd"

apt-get install -y \
    containerd.io="${CONTAINERD_APT_VERSION}"

apt-mark hold containerd.io

log "Generating containerd config"

mkdir -p /etc/containerd

containerd config default \
    > /etc/containerd/config.toml

log "Configuring systemd cgroup"

sed -i \
    's/SystemdCgroup = false/SystemdCgroup = true/g' \
    /etc/containerd/config.toml

if ! grep -q 'SystemdCgroup = true' \
    /etc/containerd/config.toml; then

    fatal "Failed to enable SystemdCgroup."
fi

log "Checking CRI plugin"

if grep -Eq \
    'disabled_plugins.*["'\'']cri["'\'']' \
    /etc/containerd/config.toml; then

    fatal "CRI plugin is disabled."
fi

log "Starting containerd"

systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd

log "Verification"

containerd --version

systemctl is-active --quiet containerd \
    || fatal "containerd is not running."

grep -n \
    'SystemdCgroup' \
    /etc/containerd/config.toml

log "containerd ${CONTAINERD_VERSION} installed successfully"
