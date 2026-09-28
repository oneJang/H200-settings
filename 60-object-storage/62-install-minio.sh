#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/versions.env"
source "${ROOT_DIR}/config/object-storage.env"
source "${ROOT_DIR}/config/registry.env"

require_command kubectl
require_value IMAGE_DISTRIBUTION_MODE
require_value MINIO_VERSION
require_value MINIO_IMAGE_NAME
require_value MINIO_NAMESPACE
require_value MINIO_STORAGE_CLASS
require_value MINIO_DATA_SIZE
require_value MINIO_S3_SERVICE
require_value MINIO_S3_PORT
require_value MINIO_CONSOLE_SERVICE
require_value MINIO_CONSOLE_PORT
require_value MINIO_CONSOLE_SERVICE_TYPE
require_value MINIO_ROOT_SECRET
require_value MINIO_CPU_REQUEST
require_value MINIO_MEMORY_REQUEST
require_value KFP_ARTIFACT_BUCKET
require_value MLFLOW_ARTIFACT_BUCKET

registry_authority() {
    local authority="${REGISTRY_HOST}"
    if [[ -n "${REGISTRY_PORT:-}" ]]; then authority="${authority}:${REGISTRY_PORT}"; fi
    printf '%s' "${authority}"
}
registry_image_ref() {
    local authority prefix
    authority="$(registry_authority)"
    prefix="${REGISTRY_REPOSITORY_PREFIX#/}"; prefix="${prefix%/}"
    if [[ -n "${prefix}" ]]; then
        printf '%s/%s/%s:%s' "${authority}" "${prefix}" "${MINIO_IMAGE_NAME}" "${MINIO_VERSION}"
    else
        printf '%s/%s:%s' "${authority}" "${MINIO_IMAGE_NAME}" "${MINIO_VERSION}"
    fi
}

IMAGE_PULL_SECRET_BLOCK=""
case "${IMAGE_DISTRIBUTION_MODE}" in
    local)
        require_command sudo
        require_command ctr
        MINIO_IMAGE="localhost/${MINIO_IMAGE_NAME}:${MINIO_VERSION}"
        IMAGE_PULL_POLICY="Never"

        READY_NODES="$(kubectl get nodes --no-headers | awk '$2 ~ /^Ready/ && $2 !~ /SchedulingDisabled/ {count++} END {print count+0}')"
        [[ "${READY_NODES}" -eq 1 ]] \
            || fatal "local mode requires exactly one Ready schedulable node. Use registry mode for multi-node clusters."

        sudo ctr -n k8s.io images list | grep -F "${MINIO_IMAGE}" >/dev/null \
            || fatal "MinIO image is not present in containerd. Run 61-publish-minio-image.sh first."
        ;;

    registry)
        require_value REGISTRY_HOST
        require_value REGISTRY_AUTH_REQUIRED
        require_value REGISTRY_TLS_VERIFY
        MINIO_IMAGE="$(registry_image_ref)"
        IMAGE_PULL_POLICY="IfNotPresent"

        # An insecure/plain-HTTP registry requires node-level containerd trust config.
        # Do not silently mutate containerd here: registry runtime trust belongs to 30-registry.
        if [[ "${REGISTRY_SCHEME:-https}" == "http" || "${REGISTRY_TLS_VERIFY}" == "false" ]]; then
            AUTHORITY="$(registry_authority)"
            if [[ ! -f "/etc/containerd/certs.d/${AUTHORITY}/hosts.toml" ]]; then
                fatal "Registry is HTTP/unverified TLS but containerd trust is not configured at /etc/containerd/certs.d/${AUTHORITY}/hosts.toml. Configure registry runtime trust first."
            fi
        fi
        ;;

    *) fatal "IMAGE_DISTRIBUTION_MODE must be local or registry." ;;
esac

log "Checking StorageClass"
kubectl get storageclass "${MINIO_STORAGE_CLASS}" >/dev/null 2>&1 \
    || fatal "StorageClass not found: ${MINIO_STORAGE_CLASS}"

log "Creating object-storage namespace"
kubectl create namespace "${MINIO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

if [[ "${IMAGE_DISTRIBUTION_MODE}" == "registry" && "${REGISTRY_AUTH_REQUIRED}" == "true" ]]; then
    require_value REGISTRY_PULL_SECRET_NAME
    if kubectl get secret "${REGISTRY_PULL_SECRET_NAME}" -n "${MINIO_NAMESPACE}" >/dev/null 2>&1; then
        log "Reusing imagePullSecret ${REGISTRY_PULL_SECRET_NAME}"
    else
        USERNAME="${REGISTRY_USERNAME:-}"
        if [[ -z "${USERNAME}" ]]; then read -rp "Registry username: " USERNAME; fi
        read -rsp "Registry password/token for Kubernetes pull secret: " REGISTRY_PASSWORD
        echo
        [[ -n "${USERNAME}" && -n "${REGISTRY_PASSWORD}" ]] || fatal "Registry credentials cannot be empty."
        kubectl create secret docker-registry "${REGISTRY_PULL_SECRET_NAME}" \
            -n "${MINIO_NAMESPACE}" \
            --docker-server="$(registry_authority)" \
            --docker-username="${USERNAME}" \
            --docker-password="${REGISTRY_PASSWORD}" \
            --dry-run=client -o yaml | kubectl apply -f -
        unset REGISTRY_PASSWORD
    fi
    IMAGE_PULL_SECRET_BLOCK=$'      imagePullSecrets:\n        - name: '"${REGISTRY_PULL_SECRET_NAME}"
fi

if kubectl get secret "${MINIO_ROOT_SECRET}" -n "${MINIO_NAMESPACE}" >/dev/null 2>&1; then
    log "Reusing existing MinIO root credential Secret"
else
    log "Creating MinIO root credentials"
    read -rp "MinIO root access key: " MINIO_ROOT_USER
    read -rsp "MinIO root secret key: " MINIO_ROOT_PASSWORD
    echo
    [[ -n "${MINIO_ROOT_USER}" ]] || fatal "Root access key cannot be empty."
    [[ ${#MINIO_ROOT_PASSWORD} -ge 8 ]] || fatal "Root secret key must be at least 8 characters."
    kubectl create secret generic "${MINIO_ROOT_SECRET}" \
        -n "${MINIO_NAMESPACE}" \
        --from-literal=rootUser="${MINIO_ROOT_USER}" \
        --from-literal=rootPassword="${MINIO_ROOT_PASSWORD}" \
        --dry-run=client -o yaml | kubectl apply -f -
    unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
fi

case "${MINIO_CONSOLE_SERVICE_TYPE}" in
    ClusterIP|NodePort) ;;
    *) fatal "MINIO_CONSOLE_SERVICE_TYPE must be ClusterIP or NodePort." ;;
esac

CONSOLE_NODEPORT_LINE=""
if [[ "${MINIO_CONSOLE_SERVICE_TYPE}" == "NodePort" ]]; then
    require_value MINIO_CONSOLE_NODEPORT
    CONSOLE_NODEPORT_LINE="      nodePort: ${MINIO_CONSOLE_NODEPORT}"
fi

log "Deploying MinIO"
cat <<EOF2 | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-data
  namespace: ${MINIO_NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${MINIO_STORAGE_CLASS}
  resources:
    requests:
      storage: ${MINIO_DATA_SIZE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: ${MINIO_NAMESPACE}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
${IMAGE_PULL_SECRET_BLOCK}
      terminationGracePeriodSeconds: 60
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        fsGroupChangePolicy: OnRootMismatch
      containers:
        - name: minio
          image: ${MINIO_IMAGE}
          imagePullPolicy: ${IMAGE_PULL_POLICY}
          args: ["server", "/data", "--console-address", ":${MINIO_CONSOLE_PORT}"]
          env:
            - name: MINIO_ROOT_USER
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_ROOT_SECRET}
                  key: rootUser
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_ROOT_SECRET}
                  key: rootPassword
          ports:
            - name: s3
              containerPort: ${MINIO_S3_PORT}
            - name: console
              containerPort: ${MINIO_CONSOLE_PORT}
          startupProbe:
            httpGet:
              path: /minio/health/live
              port: s3
            periodSeconds: 5
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /minio/health/ready
              port: s3
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /minio/health/live
              port: s3
            periodSeconds: 10
            failureThreshold: 6
          resources:
            requests:
              cpu: ${MINIO_CPU_REQUEST}
              memory: ${MINIO_MEMORY_REQUEST}
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: minio-data
---
apiVersion: v1
kind: Service
metadata:
  name: ${MINIO_S3_SERVICE}
  namespace: ${MINIO_NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: minio
  ports:
    - name: s3
      port: ${MINIO_S3_PORT}
      targetPort: s3
---
apiVersion: v1
kind: Service
metadata:
  name: ${MINIO_CONSOLE_SERVICE}
  namespace: ${MINIO_NAMESPACE}
spec:
  type: ${MINIO_CONSOLE_SERVICE_TYPE}
  selector:
    app: minio
  ports:
    - name: console
      port: ${MINIO_CONSOLE_PORT}
      targetPort: console
${CONSOLE_NODEPORT_LINE}
EOF2

kubectl rollout status deployment/minio -n "${MINIO_NAMESPACE}" --timeout=600s

log "Creating artifact buckets"
kubectl delete job minio-create-buckets -n "${MINIO_NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
cat <<EOF2 | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-create-buckets
  namespace: ${MINIO_NAMESPACE}
spec:
  backoffLimit: 5
  template:
    spec:
${IMAGE_PULL_SECRET_BLOCK}
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
      containers:
        - name: mc
          image: ${MINIO_IMAGE}
          imagePullPolicy: ${IMAGE_PULL_POLICY}
          command: ["/bin/sh", "-ec"]
          args:
            - |
              MC_CONFIG_DIR=/tmp/mc-config
              mkdir -p "\${MC_CONFIG_DIR}"
              until /usr/local/bin/mc --config-dir "\${MC_CONFIG_DIR}" alias set local http://${MINIO_S3_SERVICE}:${MINIO_S3_PORT} "\${MINIO_ROOT_USER}" "\${MINIO_ROOT_PASSWORD}"; do sleep 2; done
              /usr/local/bin/mc --config-dir "\${MC_CONFIG_DIR}" mb --ignore-existing local/${KFP_ARTIFACT_BUCKET}
              /usr/local/bin/mc --config-dir "\${MC_CONFIG_DIR}" mb --ignore-existing local/${MLFLOW_ARTIFACT_BUCKET}
              /usr/local/bin/mc --config-dir "\${MC_CONFIG_DIR}" ls local
          env:
            - name: MINIO_ROOT_USER
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_ROOT_SECRET}
                  key: rootUser
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_ROOT_SECRET}
                  key: rootPassword
EOF2

kubectl wait --for=condition=complete job/minio-create-buckets -n "${MINIO_NAMESPACE}" --timeout=300s

log "MinIO installation completed"
echo "Image       : ${MINIO_IMAGE}"
echo "S3 endpoint : http://${MINIO_S3_SERVICE}.${MINIO_NAMESPACE}.svc.cluster.local:${MINIO_S3_PORT}"
