#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/versions.env"
source "${ROOT_DIR}/config/object-storage.env"

require_value MINIO_VERSION
require_value MINIO_MC_VERSION
require_value MINIO_BUILD_GO_IMAGE
require_value MINIO_RUNTIME_BASE_IMAGE
require_value MINIO_IMAGE_NAME
require_command sudo

if ! command -v buildah >/dev/null 2>&1; then
    log "Installing Buildah"
    sudo apt-get update
    sudo apt-get install -y buildah
fi
require_command buildah

# localhost is intentionally INTERNAL to Buildah local storage only.
# It is never used as the deployment image when registry mode is selected.
LOCAL_IMAGE_REF="localhost/${MINIO_IMAGE_NAME}:${MINIO_VERSION}"

BUILD_DIR="$(mktemp -d)"
CONTAINERFILE="${BUILD_DIR}/Containerfile"
trap 'rm -rf "${BUILD_DIR}"' EXIT

log "Generating MinIO build definition"
cat > "${CONTAINERFILE}" <<EOF2
FROM ${MINIO_BUILD_GO_IMAGE} AS minio-build
ARG MINIO_VERSION
RUN apk add --no-cache git ca-certificates
RUN mkdir -p /out && \
    CGO_ENABLED=0 GOBIN=/out go install github.com/minio/minio@\${MINIO_VERSION}

FROM ${MINIO_BUILD_GO_IMAGE} AS mc-build
ARG MINIO_MC_VERSION
RUN apk add --no-cache git ca-certificates
RUN mkdir -p /out && \
    CGO_ENABLED=0 GOBIN=/out go install github.com/minio/mc@\${MINIO_MC_VERSION}

FROM ${MINIO_RUNTIME_BASE_IMAGE}
RUN apk add --no-cache ca-certificates && \
    addgroup -S -g 1000 minio && \
    adduser -S -D -H -u 1000 -G minio minio
COPY --from=minio-build /out/minio /usr/local/bin/minio
COPY --from=mc-build /out/mc /usr/local/bin/mc
USER 1000:1000
VOLUME ["/data"]
EXPOSE 9000 9001
ENTRYPOINT ["/usr/local/bin/minio"]
CMD ["server", "/data", "--console-address", ":9001"]
EOF2

log "Building MinIO Community image"
echo "MinIO       : ${MINIO_VERSION}"
echo "mc          : ${MINIO_MC_VERSION}"
echo "Build image : ${MINIO_BUILD_GO_IMAGE}"
echo "Runtime     : ${MINIO_RUNTIME_BASE_IMAGE}"
echo "Local ref   : ${LOCAL_IMAGE_REF}"

# Rootful + chroot avoids dependence on rootless user namespaces and OCI runtime
# capability handling. This is appropriate for a controlled infrastructure build host.
sudo buildah bud \
    --isolation chroot \
    --build-arg "MINIO_VERSION=${MINIO_VERSION}" \
    --build-arg "MINIO_MC_VERSION=${MINIO_MC_VERSION}" \
    --label "org.opencontainers.image.title=MinIO Community" \
    --label "org.opencontainers.image.version=${MINIO_VERSION}" \
    --label "org.opencontainers.image.source=https://github.com/minio/minio" \
    --tag "${LOCAL_IMAGE_REF}" \
    --file "${CONTAINERFILE}" \
    "${BUILD_DIR}"

log "Verifying built image"
sudo buildah images --format '{{.Name}}:{{.Tag}}' | grep -Fx "${LOCAL_IMAGE_REF}" >/dev/null \
    || fatal "Built image not found in Buildah storage: ${LOCAL_IMAGE_REF}"

log "MinIO image build completed"
echo "Next: ./60-object-storage/61-publish-minio-image.sh"
