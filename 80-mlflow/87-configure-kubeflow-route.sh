#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/mlflow.env"
source "${ROOT_DIR}/config/object-storage.env"

require_command kubectl
require_command jq

require_value MLFLOW_NAMESPACE
require_value MLFLOW_RELEASE_NAME
require_value MLFLOW_KUBEFLOW_ROUTE_ENABLED
require_value KUBEFLOW_EXTERNAL_URL

require_value MINIO_NAMESPACE
require_value MINIO_RELEASE_NAME
require_value MINIO_CONSOLE_SERVICE
require_value MINIO_CONSOLE_PORT
require_value MINIO_CONSOLE_NODEPORT

[[ "${MLFLOW_KUBEFLOW_ROUTE_ENABLED}" == "true" ]] \
    || fatal "MLFLOW_KUBEFLOW_ROUTE_ENABLED must be true."


# ============================================================
# Kubeflow / Istio
# ============================================================

KUBEFLOW_NAMESPACE="kubeflow"
KUBEFLOW_GATEWAY="kubeflow-gateway"

DASHBOARD_CONFIGMAP="dashboard-config"
DASHBOARD_DEPLOYMENT="dashboard"

ISTIO_NAMESPACE="istio-system"
JWT_POLICY="istio-ingressgateway-require-jwt"


# ============================================================
# MLflow
# ============================================================

MLFLOW_SERVICE="${MLFLOW_RELEASE_NAME}-server"
MLFLOW_PORT="5000"
MLFLOW_PREFIX="/mlflow"


# ============================================================
# MinIO
#
# MinIO Console은 Kubeflow iframe으로 열지 않는다.
# NodePort를 externalLinks로 직접 연다.
# ============================================================

MINIO_DEPLOYMENT="${MINIO_RELEASE_NAME}"

KUBEFLOW_EXTERNAL_URL="${KUBEFLOW_EXTERNAL_URL%/}"

# 예:
# KUBEFLOW_EXTERNAL_URL=http://192.168.253.134:8080
# ->
# MINIO_EXTERNAL_URL=http://192.168.253.134:30901
#
KUBEFLOW_SCHEME="${KUBEFLOW_EXTERNAL_URL%%://*}"
KUBEFLOW_HOSTPORT="${KUBEFLOW_EXTERNAL_URL#*://}"
KUBEFLOW_HOST="${KUBEFLOW_HOSTPORT%%:*}"

MINIO_EXTERNAL_URL="${KUBEFLOW_SCHEME}://${KUBEFLOW_HOST}:${MINIO_CONSOLE_NODEPORT}"


# ============================================================
# Temporary files
# ============================================================

TMP_DIR="$(mktemp -d /tmp/h200-kubeflow-ui.XXXXXX)"
TMP_POLICY="${TMP_DIR}/jwt-policy.json"
TMP_DASHBOARD="${TMP_DIR}/dashboard-config.json"

cleanup() {
    rm -rf "${TMP_DIR}"
}

trap cleanup EXIT


# ============================================================
# 1. Validate required resources
# ============================================================

log "Validating required resources"


kubectl get gateway \
    "${KUBEFLOW_GATEWAY}" \
    -n "${KUBEFLOW_NAMESPACE}" \
    >/dev/null


kubectl get deployment \
    "${DASHBOARD_DEPLOYMENT}" \
    -n "${KUBEFLOW_NAMESPACE}" \
    >/dev/null


kubectl get configmap \
    "${DASHBOARD_CONFIGMAP}" \
    -n "${KUBEFLOW_NAMESPACE}" \
    >/dev/null


kubectl get deployment \
    "${MLFLOW_SERVICE}" \
    -n "${MLFLOW_NAMESPACE}" \
    >/dev/null


kubectl get service \
    "${MLFLOW_SERVICE}" \
    -n "${MLFLOW_NAMESPACE}" \
    >/dev/null


kubectl get deployment \
    "${MINIO_DEPLOYMENT}" \
    -n "${MINIO_NAMESPACE}" \
    >/dev/null


kubectl get service \
    "${MINIO_CONSOLE_SERVICE}" \
    -n "${MINIO_NAMESPACE}" \
    >/dev/null


kubectl get authorizationpolicy \
    "${JWT_POLICY}" \
    -n "${ISTIO_NAMESPACE}" \
    >/dev/null


# ============================================================
# 2. MLflow VirtualService
#
# 85-install-mlflow.sh:
#
#   server:
#     staticPrefix: "/mlflow"
#
# MLflow에는 /mlflow/... 경로를 그대로 전달한다.
# ============================================================

log "Configuring MLflow VirtualService"


cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: mlflow
  namespace: ${MLFLOW_NAMESPACE}
spec:
  hosts:
    - "*"

  gateways:
    - ${KUBEFLOW_NAMESPACE}/${KUBEFLOW_GATEWAY}

  http:
    - match:
        - uri:
            exact: ${MLFLOW_PREFIX}

      redirect:
        uri: ${MLFLOW_PREFIX}/

    - match:
        - uri:
            prefix: ${MLFLOW_PREFIX}/

      route:
        - destination:
            host: ${MLFLOW_SERVICE}.${MLFLOW_NAMESPACE}.svc.cluster.local
            port:
              number: ${MLFLOW_PORT}
EOF


# ============================================================
# 3. Remove obsolete MinIO in-cluster route
#
# MinIO Console은 Kubeflow iframe과 호환 문제가 있으므로
# 더 이상 VirtualService를 사용하지 않는다.
# ============================================================

log "Removing obsolete MinIO VirtualService"

kubectl delete virtualservice \
    minio-console \
    -n "${MINIO_NAMESPACE}" \
    --ignore-not-found


# ============================================================
# 4. Remove obsolete MinIO redirect configuration
#
# 이전 87에서 설정했던 MINIO_BROWSER_REDIRECT_URL을 제거한다.
# NodePort로 직접 접근하므로 필요 없다.
# ============================================================

log "Removing obsolete MinIO browser redirect configuration"

kubectl set env \
    deployment/"${MINIO_DEPLOYMENT}" \
    -n "${MINIO_NAMESPACE}" \
    MINIO_BROWSER_REDIRECT_URL-


log "Waiting for MinIO rollout"

kubectl rollout status \
    deployment/"${MINIO_DEPLOYMENT}" \
    -n "${MINIO_NAMESPACE}" \
    --timeout=5m


# ============================================================
# 5. Kubeflow ingress JWT exceptions
#
# MLflow Native Basic Auth의 Authorization: Basic 헤더가
# Kubeflow JWT 정책과 충돌하지 않도록 MLflow 경로만 예외 처리.
#
# MinIO는 이제 Gateway를 통과하지 않으므로 MinIO 예외는 제거한다.
# ============================================================

log "Configuring Kubeflow ingress JWT exceptions"


kubectl get authorizationpolicy \
    "${JWT_POLICY}" \
    -n "${ISTIO_NAMESPACE}" \
    -o json \
| jq \
    --arg mlflow "${MLFLOW_PREFIX}" \
    '
    .spec.rules[0].to[0].operation.notPaths |=
    (
      [
        .[]

        | select(
            . != "/minio"
            and . != "/minio/*"
            and . != "/minio/**"
            and . != "/_/minio"
            and . != "/_/minio/*"
            and . != "/_/minio/**"
          )
      ]

      +

      [
        $mlflow,
        ($mlflow + "/*"),
        ($mlflow + "/**"),
        ("/_" + $mlflow),
        ("/_" + $mlflow + "/*"),
        ("/_" + $mlflow + "/**")
      ]

      | unique
    )

    |

    del(
      .metadata.creationTimestamp,
      .metadata.generation,
      .metadata.managedFields,
      .metadata.resourceVersion,
      .metadata.uid
    )
    ' \
> "${TMP_POLICY}"


kubectl apply -f "${TMP_POLICY}"


# ============================================================
# 6. Kubeflow Dashboard links
#
# MLflow:
#   in-cluster app -> menuLinks
#
# MinIO:
#   external app   -> externalLinks
#   iframe=false
# ============================================================

log "Configuring Kubeflow Dashboard links"


kubectl get configmap \
    "${DASHBOARD_CONFIGMAP}" \
    -n "${KUBEFLOW_NAMESPACE}" \
    -o json \
| jq \
    --arg mlflowLink "${MLFLOW_PREFIX}/" \
    --arg minioLink "${MINIO_EXTERNAL_URL}" \
    '
    .data.links |=
    (
      fromjson

      |

      .menuLinks =
      (
        [
          .menuLinks[]

          | select(
              .text != "MLflow"
              and
              .text != "MinIO"
            )
        ]

        +

        [
          {
            "icon": "assessment",
            "link": $mlflowLink,
            "text": "MLflow",
            "type": "item"
          }
        ]
      )

      |

      .externalLinks =
      (
        [
          (.externalLinks // [])[]

          | select(
              .text != "MinIO"
            )
        ]

        +

        [
          {
            "type": "item",
            "iframe": false,
            "link": $minioLink,
            "text": "MinIO",
            "icon": "device:storage"
          }
        ]
      )

      |

      tojson
    )

    |

    del(
      .metadata.creationTimestamp,
      .metadata.managedFields,
      .metadata.resourceVersion,
      .metadata.uid
    )
    ' \
> "${TMP_DASHBOARD}"


kubectl apply -f "${TMP_DASHBOARD}"


# ============================================================
# 7. Restart Kubeflow Dashboard
# ============================================================

log "Restarting Kubeflow Dashboard"


kubectl rollout restart \
    deployment/"${DASHBOARD_DEPLOYMENT}" \
    -n "${KUBEFLOW_NAMESPACE}"


kubectl rollout status \
    deployment/"${DASHBOARD_DEPLOYMENT}" \
    -n "${KUBEFLOW_NAMESPACE}" \
    --timeout=5m


# ============================================================
# 8. Verify MLflow
# ============================================================

log "Verifying MLflow"


kubectl rollout status \
    deployment/"${MLFLOW_SERVICE}" \
    -n "${MLFLOW_NAMESPACE}" \
    --timeout=5m


MLFLOW_READINESS_PATH="$(
    kubectl get deployment \
        "${MLFLOW_SERVICE}" \
        -n "${MLFLOW_NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}'
)"


EXPECTED_MLFLOW_HEALTH="${MLFLOW_PREFIX}/health"


[[ "${MLFLOW_READINESS_PATH}" == "${EXPECTED_MLFLOW_HEALTH}" ]] \
    || fatal \
        "MLflow readiness probe is '${MLFLOW_READINESS_PATH}', expected '${EXPECTED_MLFLOW_HEALTH}'"


kubectl get virtualservice \
    mlflow \
    -n "${MLFLOW_NAMESPACE}" \
    >/dev/null


# ============================================================
# 9. Verify MinIO external access
# ============================================================

log "Verifying MinIO external link"

ACTUAL_NODEPORT="$(
    kubectl get service \
        "${MINIO_CONSOLE_SERVICE}" \
        -n "${MINIO_NAMESPACE}" \
        -o jsonpath='{.spec.ports[0].nodePort}'
)"


[[ "${ACTUAL_NODEPORT}" == "${MINIO_CONSOLE_NODEPORT}" ]] \
    || fatal \
        "MinIO NodePort is '${ACTUAL_NODEPORT}', expected '${MINIO_CONSOLE_NODEPORT}'"


# ============================================================
# 10. Verify Dashboard links
# ============================================================

log "Verifying Kubeflow Dashboard links"


LINKS="$(
    kubectl get configmap \
        "${DASHBOARD_CONFIGMAP}" \
        -n "${KUBEFLOW_NAMESPACE}" \
        -o jsonpath='{.data.links}'
)"


echo "${LINKS}" \
| jq \
    --arg link "${MLFLOW_PREFIX}/" \
    -e \
    '
    .menuLinks[]
    |
    select(
      .text == "MLflow"
      and
      .link == $link
    )
    ' \
>/dev/null \
|| fatal "MLflow Dashboard link not found."


echo "${LINKS}" \
| jq \
    --arg link "${MINIO_EXTERNAL_URL}" \
    -e \
    '
    .externalLinks[]
    |
    select(
      .text == "MinIO"
      and
      .iframe == false
      and
      .link == $link
    )
    ' \
>/dev/null \
|| fatal "MinIO external Dashboard link not found."


# ============================================================
# 11. Verify JWT exceptions
# ============================================================

log "Verifying MLflow JWT exceptions"


kubectl get authorizationpolicy \
    "${JWT_POLICY}" \
    -n "${ISTIO_NAMESPACE}" \
    -o json \
| jq \
    --arg mlflow "${MLFLOW_PREFIX}" \
    -e \
    '
    .spec.rules[0].to[0].operation.notPaths

    |

    (
      index($mlflow + "/**") != null
      and
      index("/_" + $mlflow + "/**") != null
    )
    ' \
>/dev/null \
|| fatal "MLflow JWT exception verification failed."


# ============================================================
# Completed
# ============================================================

log "Kubeflow MLOps UI integration completed"

echo
echo "Kubeflow Dashboard:"
echo "  ${KUBEFLOW_EXTERNAL_URL}/"

echo
echo "MLflow:"
echo "  ${KUBEFLOW_EXTERNAL_URL}/_${MLFLOW_PREFIX}/"

echo
echo "MinIO:"
echo "  ${MINIO_EXTERNAL_URL}"

echo
