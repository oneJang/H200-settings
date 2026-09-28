#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"

require_root

export KUBECONFIG=/etc/kubernetes/admin.conf

log "Node"

kubectl get nodes \
    -o wide

log "Node conditions"

kubectl describe node \
    | sed -n '/Conditions:/,/Addresses:/p'

log "System Pods"

kubectl get pods \
    -n kube-system \
    -o wide

log "Container runtime"

kubectl get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.containerRuntimeVersion}{"\n"}{end}'

log "CRI"

crictl info \
    | jq '{
        runtimeName: .status.runtimeHandlers,
        networkReady: .status.conditions
    }' 2>/dev/null || crictl info

log "CNI configuration"

ls -al /etc/cni/net.d/ || true

log "Control-plane taints"

kubectl get nodes \
    -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

log "Running simple network test"

kubectl delete pod network-test \
    --ignore-not-found=true

kubectl run network-test \
    --image=busybox:1.36 \
    --restart=Never \
    --command -- \
    sh -c 'ip addr; echo "---"; nslookup kubernetes.default.svc.cluster.local'

kubectl wait \
    --for=condition=Ready \
    pod/network-test \
    --timeout=120s

kubectl logs network-test

kubectl delete pod network-test

log "Cluster validation completed successfully"
