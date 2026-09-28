#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"

require_command kubectl

log "StorageClasses"

kubectl get storageclass

log "Local Path Provisioner"

kubectl get pods \
    -n local-path-storage \
    -o wide

log "Creating test PVC"

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: storage-test
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: storage-test
spec:
  containers:
    - name: test
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          echo "storage-test" > /data/test.txt
          sleep 3600
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: storage-test
EOF

kubectl wait \
    --for=condition=Ready \
    pod/storage-test \
    --timeout=120s

log "PVC/PV"

kubectl get pvc
kubectl get pv

log "File inside volume"

kubectl exec storage-test -- cat /data/test.txt

log "Storage verification completed"

log "Delete pod and pvc"

kubectl delete pod storage-test
kubectl delete pvc storage-test
