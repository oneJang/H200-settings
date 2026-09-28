#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/versions.env"
source "${ROOT_DIR}/config/mlflow.env"

require_command kubectl
require_command openssl
require_value MLFLOW_NAMESPACE
require_value MLFLOW_DATABASE_MODE
require_value MLFLOW_MYSQL_DATABASE
require_value MLFLOW_MYSQL_USER

kubectl create namespace "${MLFLOW_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

case "${MLFLOW_DATABASE_MODE}" in
internal)
    require_value MLFLOW_MYSQL_VERSION
    require_value MLFLOW_MYSQL_IMAGE_REPOSITORY
    require_value MLFLOW_STORAGE_CLASS
    require_value MLFLOW_MYSQL_PVC_SIZE

    if ! kubectl get secret mlflow-mysql-secret -n "${MLFLOW_NAMESPACE}" >/dev/null 2>&1; then
        MYSQL_ROOT_PASSWORD="$(openssl rand -hex 24)"
        MYSQL_PASSWORD="$(openssl rand -hex 24)"
        kubectl create secret generic mlflow-mysql-secret \
            -n "${MLFLOW_NAMESPACE}" \
            --from-literal=MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}" \
            --from-literal=MYSQL_DATABASE="${MLFLOW_MYSQL_DATABASE}" \
            --from-literal=MYSQL_USER="${MLFLOW_MYSQL_USER}" \
            --from-literal=MYSQL_PASSWORD="${MYSQL_PASSWORD}"
        unset MYSQL_ROOT_PASSWORD MYSQL_PASSWORD
    fi

    MYSQL_PASSWORD="$(kubectl get secret mlflow-mysql-secret -n "${MLFLOW_NAMESPACE}" -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d)"
    BACKEND_URI="mysql+pymysql://${MLFLOW_MYSQL_USER}:${MYSQL_PASSWORD}@mlflow-mysql.${MLFLOW_NAMESPACE}.svc.cluster.local:3306/${MLFLOW_MYSQL_DATABASE}?charset=utf8mb4"

    kubectl create secret generic mlflow-backend-secret \
        -n "${MLFLOW_NAMESPACE}" \
        --from-literal=MLFLOW_BACKEND_STORE_URI="${BACKEND_URI}" \
        --dry-run=client -o yaml | kubectl apply -f -
    unset MYSQL_PASSWORD BACKEND_URI

    cat <<EOF2 | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: mlflow-mysql-config
  namespace: ${MLFLOW_NAMESPACE}
data:
  my.cnf: |
    [mysqld]
    character-set-server=utf8mb4
    collation-server=utf8mb4_unicode_ci
    skip-name-resolve
---
apiVersion: v1
kind: Service
metadata:
  name: mlflow-mysql
  namespace: ${MLFLOW_NAMESPACE}
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: mlflow-mysql
  ports:
    - name: mysql
      port: 3306
      targetPort: 3306
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mlflow-mysql
  namespace: ${MLFLOW_NAMESPACE}
spec:
  serviceName: mlflow-mysql
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: mlflow-mysql
  template:
    metadata:
      labels:
        app.kubernetes.io/name: mlflow-mysql
    spec:
      terminationGracePeriodSeconds: 60
      containers:
        - name: mysql
          image: ${MLFLOW_MYSQL_IMAGE_REPOSITORY}:${MLFLOW_MYSQL_VERSION}
          imagePullPolicy: IfNotPresent
          ports:
            - name: mysql
              containerPort: 3306
          envFrom:
            - secretRef:
                name: mlflow-mysql-secret
          volumeMounts:
            - name: mysql-data
              mountPath: /var/lib/mysql
            - name: mysql-config
              mountPath: /etc/mysql/conf.d/platform.cnf
              subPath: my.cnf
              readOnly: true
          startupProbe:
            exec:
              command:
                - sh
                - -ec
                - 'MYSQL_PWD="\$MYSQL_ROOT_PASSWORD" mysqladmin ping -h 127.0.0.1 -uroot'
            periodSeconds: 5
            timeoutSeconds: 5
            failureThreshold: 60

          readinessProbe:
            exec:
              command:
                - sh
                - -ec
                - 'MYSQL_PWD="\$MYSQL_ROOT_PASSWORD" mysqladmin ping -h 127.0.0.1 -uroot'
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6

          livenessProbe:
            exec:
              command:
                - sh
                - -ec
                - 'MYSQL_PWD="\$MYSQL_ROOT_PASSWORD" mysqladmin ping -h 127.0.0.1 -uroot'
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 6
          resources:
            requests:
              cpu: ${MLFLOW_MYSQL_CPU_REQUEST}
              memory: ${MLFLOW_MYSQL_MEMORY_REQUEST}
            limits:
              cpu: ${MLFLOW_MYSQL_CPU_LIMIT}
              memory: ${MLFLOW_MYSQL_MEMORY_LIMIT}
      volumes:
        - name: mysql-config
          configMap:
            name: mlflow-mysql-config
  volumeClaimTemplates:
    - metadata:
        name: mysql-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: ${MLFLOW_STORAGE_CLASS}
        resources:
          requests:
            storage: ${MLFLOW_MYSQL_PVC_SIZE}
EOF2

    kubectl rollout status statefulset/mlflow-mysql -n "${MLFLOW_NAMESPACE}" --timeout=10m
    ;;

external)
    require_value MLFLOW_EXTERNAL_MYSQL_HOST
    require_value MLFLOW_EXTERNAL_MYSQL_PORT
    require_value MLFLOW_EXTERNAL_MYSQL_DATABASE
    require_value MLFLOW_EXTERNAL_MYSQL_USER

    read -rsp "External MySQL password: " MYSQL_PASSWORD
    echo
    [[ -n "${MYSQL_PASSWORD}" ]] || fatal "External MySQL password cannot be empty."

    BACKEND_URI="mysql+pymysql://${MLFLOW_EXTERNAL_MYSQL_USER}:${MYSQL_PASSWORD}@${MLFLOW_EXTERNAL_MYSQL_HOST}:${MLFLOW_EXTERNAL_MYSQL_PORT}/${MLFLOW_EXTERNAL_MYSQL_DATABASE}?charset=utf8mb4"
    kubectl create secret generic mlflow-backend-secret \
        -n "${MLFLOW_NAMESPACE}" \
        --from-literal=MLFLOW_BACKEND_STORE_URI="${BACKEND_URI}" \
        --dry-run=client -o yaml | kubectl apply -f -
    unset MYSQL_PASSWORD BACKEND_URI
    ;;

*)
    fatal "MLFLOW_DATABASE_MODE must be internal or external."
    ;;
esac

log "MLflow backend database configuration completed"
