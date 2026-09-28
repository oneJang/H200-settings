#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/versions.env"
source "${ROOT_DIR}/config/cluster.env"
source "${ROOT_DIR}/config/registry.env"

require_command kubectl
require_command helm

require_value HARBOR_CHART_VERSION
require_value HARBOR_NAMESPACE
require_value HARBOR_ADMIN_SECRET
require_value HARBOR_STORAGE_CLASS
require_value HARBOR_REGISTRY_SIZE
require_value HARBOR_EXPOSE_TYPE
require_value HARBOR_TLS_ENABLED

RELEASE_NAME="harbor"
VALUES_FILE="${ROOT_DIR}/generated/harbor-values.yaml"

mkdir -p "${ROOT_DIR}/generated"


# ------------------------------------------------------------
# 기본 검증
# ------------------------------------------------------------

case "${HARBOR_EXPOSE_TYPE}" in
    nodePort|ingress|loadBalancer)
        ;;
    *)
        fatal "HARBOR_EXPOSE_TYPE must be nodePort, ingress, or loadBalancer."
        ;;
esac

case "${HARBOR_TLS_ENABLED}" in
    true|false)
        ;;
    *)
        fatal "HARBOR_TLS_ENABLED must be true or false."
        ;;
esac


log "Harbor configuration"

echo "Namespace      : ${HARBOR_NAMESPACE}"
echo "Chart version  : ${HARBOR_CHART_VERSION}"
echo "StorageClass   : ${HARBOR_STORAGE_CLASS}"
echo "Expose type    : ${HARBOR_EXPOSE_TYPE}"
echo "TLS enabled    : ${HARBOR_TLS_ENABLED}"


# ------------------------------------------------------------
# StorageClass 확인
# ------------------------------------------------------------

log "Checking StorageClass"

if ! kubectl get storageclass \
    "${HARBOR_STORAGE_CLASS}" \
    >/dev/null 2>&1; then

    fatal "StorageClass does not exist: ${HARBOR_STORAGE_CLASS}"
fi


# ------------------------------------------------------------
# Harbor Helm repository
# ------------------------------------------------------------

log "Adding Harbor Helm repository"

helm repo add harbor \
    https://helm.goharbor.io \
    --force-update

helm repo update


log "Checking Harbor chart version"

if ! helm search repo harbor/harbor \
    --versions \
    | awk 'NR>1 {print $2}' \
    | grep -Fxq "${HARBOR_CHART_VERSION}"; then

    helm search repo harbor/harbor --versions | head -n 20

    fatal "Harbor chart ${HARBOR_CHART_VERSION} not found."
fi


# ------------------------------------------------------------
# Namespace
# ------------------------------------------------------------

log "Creating Harbor namespace"

kubectl create namespace \
    "${HARBOR_NAMESPACE}" \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -


# ------------------------------------------------------------
# Admin Password Secret
# ------------------------------------------------------------

log "Configuring Harbor admin password"

read -rsp "Harbor admin password: " HARBOR_ADMIN_PASSWORD
echo

if [[ -z "${HARBOR_ADMIN_PASSWORD}" ]]; then
    fatal "Harbor admin password cannot be empty."
fi

kubectl create secret generic \
    "${HARBOR_ADMIN_SECRET}" \
    --namespace "${HARBOR_NAMESPACE}" \
    --from-literal=HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD}" \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -

unset HARBOR_ADMIN_PASSWORD


# ------------------------------------------------------------
# expose 설정 생성
# ------------------------------------------------------------

log "Generating Harbor values"


# 공통 persistence 부분
cat > "${VALUES_FILE}" <<EOF
existingSecretAdminPassword: ${HARBOR_ADMIN_SECRET}
existingSecretAdminPasswordKey: HARBOR_ADMIN_PASSWORD

persistence:
  enabled: true
  resourcePolicy: keep

  persistentVolumeClaim:
    registry:
      storageClass: ${HARBOR_STORAGE_CLASS}
      accessMode: ReadWriteOnce
      size: ${HARBOR_REGISTRY_SIZE}

    jobservice:
      jobLog:
        storageClass: ${HARBOR_STORAGE_CLASS}
        accessMode: ReadWriteOnce
        size: 5Gi

    database:
      storageClass: ${HARBOR_STORAGE_CLASS}
      accessMode: ReadWriteOnce
      size: 10Gi

    redis:
      storageClass: ${HARBOR_STORAGE_CLASS}
      accessMode: ReadWriteOnce
      size: 5Gi

    trivy:
      storageClass: ${HARBOR_STORAGE_CLASS}
      accessMode: ReadWriteOnce
      size: 10Gi
EOF


# ------------------------------------------------------------
# NodePort
# ------------------------------------------------------------

if [[ "${HARBOR_EXPOSE_TYPE}" == "nodePort" ]]; then

    require_value CONTROL_PLANE_IP

    if [[ "${HARBOR_TLS_ENABLED}" == "true" ]]; then

        require_value HARBOR_HTTPS_NODEPORT

        cat >> "${VALUES_FILE}" <<EOF

expose:
  type: nodePort

  tls:
    enabled: true
    certSource: auto

  nodePort:
    ports:
      http:
        port: 80
        nodePort: ${HARBOR_HTTP_NODEPORT}

      https:
        port: 443
        nodePort: ${HARBOR_HTTPS_NODEPORT}

externalURL: https://${CONTROL_PLANE_IP}:${HARBOR_HTTPS_NODEPORT}
EOF

    else

        require_value HARBOR_HTTP_NODEPORT

        cat >> "${VALUES_FILE}" <<EOF

expose:
  type: nodePort

  tls:
    enabled: false

  nodePort:
    ports:
      http:
        port: 80
        nodePort: ${HARBOR_HTTP_NODEPORT}

externalURL: http://${CONTROL_PLANE_IP}:${HARBOR_HTTP_NODEPORT}
EOF

    fi
fi


# ------------------------------------------------------------
# Ingress
# ------------------------------------------------------------

if [[ "${HARBOR_EXPOSE_TYPE}" == "ingress" ]]; then

    require_value HARBOR_DOMAIN
    require_value HARBOR_INGRESS_CLASS

    if [[ "${HARBOR_TLS_ENABLED}" == "true" ]]; then

        require_value HARBOR_TLS_SECRET

        cat >> "${VALUES_FILE}" <<EOF

expose:
  type: ingress

  tls:
    enabled: true
    certSource: secret

    secret:
      secretName: ${HARBOR_TLS_SECRET}

  ingress:
    hosts:
      core: ${HARBOR_DOMAIN}

    className: ${HARBOR_INGRESS_CLASS}

externalURL: https://${HARBOR_DOMAIN}
EOF

    else

        cat >> "${VALUES_FILE}" <<EOF

expose:
  type: ingress

  tls:
    enabled: false

  ingress:
    hosts:
      core: ${HARBOR_DOMAIN}

    className: ${HARBOR_INGRESS_CLASS}

externalURL: http://${HARBOR_DOMAIN}
EOF

    fi
fi


# ------------------------------------------------------------
# LoadBalancer
# ------------------------------------------------------------

if [[ "${HARBOR_EXPOSE_TYPE}" == "loadBalancer" ]]; then

    require_value HARBOR_DOMAIN

    if [[ "${HARBOR_TLS_ENABLED}" == "true" ]]; then

        cat >> "${VALUES_FILE}" <<EOF

expose:
  type: loadBalancer

  tls:
    enabled: true
    certSource: auto

externalURL: https://${HARBOR_DOMAIN}
EOF

    else

        cat >> "${VALUES_FILE}" <<EOF

expose:
  type: loadBalancer

  tls:
    enabled: false

externalURL: http://${HARBOR_DOMAIN}
EOF

    fi
fi


# ------------------------------------------------------------
# values 확인
# ------------------------------------------------------------

log "Generated Harbor values"

cat "${VALUES_FILE}"


# ------------------------------------------------------------
# Helm install / upgrade
# ------------------------------------------------------------

log "Installing Harbor"

helm upgrade --install \
    "${RELEASE_NAME}" \
    harbor/harbor \
    --namespace "${HARBOR_NAMESPACE}" \
    --version "${HARBOR_CHART_VERSION}" \
    --values "${VALUES_FILE}" \
    --wait \
    --timeout 15m


# ------------------------------------------------------------
# 상태 확인
# ------------------------------------------------------------

log "Harbor Pods"

kubectl get pods \
    -n "${HARBOR_NAMESPACE}" \
    -o wide


log "Harbor Services"

kubectl get svc \
    -n "${HARBOR_NAMESPACE}"


log "Harbor PVCs"

kubectl get pvc \
    -n "${HARBOR_NAMESPACE}"


log "Harbor Helm release"

helm list \
    -n "${HARBOR_NAMESPACE}"


# ------------------------------------------------------------
# 최종 URL 출력
# ------------------------------------------------------------

log "Harbor installation completed"

echo

case "${HARBOR_EXPOSE_TYPE}" in

    nodePort)

        if [[ "${HARBOR_TLS_ENABLED}" == "true" ]]; then
            echo "Harbor URL:"
            echo "https://${CONTROL_PLANE_IP}:${HARBOR_HTTPS_NODEPORT}"
        else
            echo "Harbor URL:"
            echo "http://${CONTROL_PLANE_IP}:${HARBOR_HTTP_NODEPORT}"
        fi
        ;;

    ingress)

        if [[ "${HARBOR_TLS_ENABLED}" == "true" ]]; then
            echo "Harbor URL:"
            echo "https://${HARBOR_DOMAIN}"
        else
            echo "Harbor URL:"
            echo "http://${HARBOR_DOMAIN}"
        fi
        ;;

    loadBalancer)

        if [[ "${HARBOR_TLS_ENABLED}" == "true" ]]; then
            echo "Configured external URL:"
            echo "https://${HARBOR_DOMAIN}"
        else
            echo "Configured external URL:"
            echo "http://${HARBOR_DOMAIN}"
        fi

        echo
        echo "Check assigned LoadBalancer IP:"
        echo "kubectl get svc -n ${HARBOR_NAMESPACE}"
        ;;

esac

echo
echo "Username: admin"
