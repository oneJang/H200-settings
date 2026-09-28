#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/registry.env"
require_command curl
require_value REGISTRY_SCHEME
require_value REGISTRY_HOST

if [[ -z "${REGISTRY_PORT:-}" ]]; then
    [[ "${REGISTRY_SCHEME}" == "https" ]] && REGISTRY_PORT=443 || REGISTRY_PORT=80
fi
REGISTRY_URL="${REGISTRY_SCHEME}://${REGISTRY_HOST}:${REGISTRY_PORT}"

log "Checking OCI Registry API"
CURL_OPTS=(--silent --show-error --connect-timeout 5 --max-time 10)
[[ "${REGISTRY_TLS_VERIFY:-true}" == "false" ]] && CURL_OPTS+=(-k)
HTTP_CODE="$(curl "${CURL_OPTS[@]}" -o /tmp/registry-v2-response -w '%{http_code}' "${REGISTRY_URL}/v2/" || true)"
rm -f /tmp/registry-v2-response
case "${HTTP_CODE}" in
    200|401) echo "OCI Registry API reachable: HTTP ${HTTP_CODE}" ;;
    *) fatal "Registry /v2/ check failed: HTTP ${HTTP_CODE}" ;;
esac

echo "Registry authority : ${REGISTRY_HOST}:${REGISTRY_PORT}"
echo "Repository prefix  : ${REGISTRY_REPOSITORY_PREFIX:-<none>}"
echo "Authentication     : ${REGISTRY_AUTH_REQUIRED:-true}"
log "Existing OCI registry check completed"
