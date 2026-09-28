#!/usr/bin/env bash

set -Eeuo pipefail

log() {
    echo
    echo "============================================================"
    echo "[INFO] $*"
    echo "============================================================"
}

warn() {
    echo "[WARN] $*" >&2
}

fatal() {
    echo "[ERROR] $*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        fatal "Run this script with sudo/root."
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 \
        || fatal "Required command not found: $1"
}

require_value() {
    local name="$1"
    local value="${!name:-}"

    [[ -n "${value}" ]] \
        || fatal "${name} is not configured."
}

check_ubuntu_2404() {
    source /etc/os-release

    if [[ "${ID}" != "ubuntu" ]]; then
        fatal "Ubuntu is required. Current OS: ${PRETTY_NAME}"
    fi

    if [[ "${VERSION_ID}" != "24.04" ]]; then
        fatal "Ubuntu 24.04 LTS is required. Current OS: ${PRETTY_NAME}"
    fi

    if [[ "${VERSION_CODENAME}" != "noble" ]]; then
        fatal "Expected Ubuntu codename noble. Current: ${VERSION_CODENAME}"
    fi
}
