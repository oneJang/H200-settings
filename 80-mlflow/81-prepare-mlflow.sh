#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/versions.env"
source "${ROOT_DIR}/config/mlflow.env"

require_command helm
require_command curl
require_command tar
require_command sudo
require_command buildah

require_value MLFLOW_VERSION
require_value MLFLOW_HELM_CHART_VERSION
require_value MLFLOW_IMAGE_NAME

VENDOR_DIR="${SCRIPT_DIR}/vendor"
CHART_ARCHIVE="${VENDOR_DIR}/mlflow-v${MLFLOW_VERSION}.tgz"

OFFICIAL_IMAGE="ghcr.io/mlflow/mlflow:v${MLFLOW_VERSION}-full"
LOCAL_IMAGE="localhost/${MLFLOW_IMAGE_NAME}:${MLFLOW_VERSION}"

WORK_DIR=""
BUILD_DIR=""
VALIDATION_CONTAINER=""

mkdir -p "${VENDOR_DIR}"


cleanup() {
    if [[ -n "${VALIDATION_CONTAINER:-}" ]]; then
        sudo buildah rm "${VALIDATION_CONTAINER}" >/dev/null 2>&1 || true
    fi

    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}"
    fi

    if [[ -n "${BUILD_DIR:-}" && -d "${BUILD_DIR}" ]]; then
        rm -rf "${BUILD_DIR}"
    fi
}

trap cleanup EXIT


log "Preparing MLflow Helm chart from the exact MLflow v${MLFLOW_VERSION} source tag"


validate_chart() {
    local archive="$1"
    local chart_version
    local app_version

    chart_version="$(
        helm show chart "${archive}" |
            awk '$1=="version:" {print $2; exit}'
    )"

    app_version="$(
        helm show chart "${archive}" |
            awk '$1=="appVersion:" {gsub(/"/, "", $2); print $2; exit}'
    )"

    [[ "${chart_version}" == "${MLFLOW_HELM_CHART_VERSION}" ]] \
        || fatal "MLflow chart version=${chart_version}, expected ${MLFLOW_HELM_CHART_VERSION}"

    [[ "${app_version}" == "${MLFLOW_VERSION}" ]] \
        || fatal "MLflow chart appVersion=${app_version}, expected ${MLFLOW_VERSION}"

    echo "Chart version : ${chart_version}"
    echo "App version   : ${app_version}"
}


if [[ -s "${CHART_ARCHIVE}" ]]; then

    echo "Using cached chart: ${CHART_ARCHIVE}"

    validate_chart "${CHART_ARCHIVE}"

else

    WORK_DIR="$(mktemp -d /tmp/h200-mlflow-chart.XXXXXX)"

    SOURCE_ARCHIVE="${WORK_DIR}/mlflow-v${MLFLOW_VERSION}.tar.gz"
    SOURCE_URL="https://github.com/mlflow/mlflow/archive/refs/tags/v${MLFLOW_VERSION}.tar.gz"

    log "Downloading MLflow v${MLFLOW_VERSION} source archive"

    curl \
        --fail \
        --location \
        --show-error \
        --retry 3 \
        --output "${SOURCE_ARCHIVE}" \
        "${SOURCE_URL}"

    tar -xzf "${SOURCE_ARCHIVE}" -C "${WORK_DIR}"

    CHART_SOURCE_DIR="${WORK_DIR}/mlflow-${MLFLOW_VERSION}/charts"

    [[ -f "${CHART_SOURCE_DIR}/Chart.yaml" ]] \
        || fatal "MLflow chart source not found: ${CHART_SOURCE_DIR}/Chart.yaml"

    SOURCE_CHART_VERSION="$(
        awk '$1=="version:" {print $2; exit}' \
            "${CHART_SOURCE_DIR}/Chart.yaml"
    )"

    SOURCE_APP_VERSION="$(
        awk '$1=="appVersion:" {gsub(/"/, "", $2); print $2; exit}' \
            "${CHART_SOURCE_DIR}/Chart.yaml"
    )"

    [[ "${SOURCE_CHART_VERSION}" == "${MLFLOW_HELM_CHART_VERSION}" ]] \
        || fatal "Source chart version=${SOURCE_CHART_VERSION}, expected ${MLFLOW_HELM_CHART_VERSION}"

    [[ "${SOURCE_APP_VERSION}" == "${MLFLOW_VERSION}" ]] \
        || fatal "Source chart appVersion=${SOURCE_APP_VERSION}, expected ${MLFLOW_VERSION}"

    log "Packaging exact MLflow v${MLFLOW_VERSION} chart for offline reuse"

    helm package \
        "${CHART_SOURCE_DIR}" \
        --destination "${WORK_DIR}" \
        >/dev/null

    PACKAGED_CHART="${WORK_DIR}/mlflow-${MLFLOW_HELM_CHART_VERSION}.tgz"

    [[ -s "${PACKAGED_CHART}" ]] \
        || fatal "helm package did not produce ${PACKAGED_CHART}"

    mv "${PACKAGED_CHART}" "${CHART_ARCHIVE}"

    validate_chart "${CHART_ARCHIVE}"
fi


log "Building thin MLflow runtime image from official image"

BUILD_DIR="$(mktemp -d /tmp/h200-mlflow-build.XXXXXX)"


cat > "${BUILD_DIR}/Containerfile" <<EOF
FROM ${OFFICIAL_IMAGE}

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
    && rm -rf /var/lib/apt/lists/*

RUN python -m pip install --no-cache-dir \
    "mlflow[auth]==${MLFLOW_VERSION}" \
    pymysql \
    boto3

USER 1000
EOF


sudo buildah bud \
    --isolation chroot \
    --tag "${LOCAL_IMAGE}" \
    --file "${BUILD_DIR}/Containerfile" \
    "${BUILD_DIR}"


log "Validating MLflow runtime image"


VALIDATION_CONTAINER="$(
    sudo buildah from "${LOCAL_IMAGE}"
)"


log "Validating Git binary"

sudo buildah run \
    "${VALIDATION_CONTAINER}" \
    -- \
    git --version


log "Validating Python dependencies"

sudo buildah run \
    "${VALIDATION_CONTAINER}" \
    -- \
    python -c '
import boto3
import pymysql
import mlflow
import flask_wtf

print("MLflow:", mlflow.__version__)
print("PyMySQL:", pymysql.__version__)
print("boto3:", boto3.__version__)

assert mlflow.__version__ == "'"${MLFLOW_VERSION}"'"

print("runtime validation: PASS")
'


log "MLflow preparation completed"

echo "Chart : ${CHART_ARCHIVE}"
echo "Image : ${LOCAL_IMAGE}"
