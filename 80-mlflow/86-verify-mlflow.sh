#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/mlflow.env"
source "${ROOT_DIR}/config/object-storage.env"

require_command kubectl
require_value MLFLOW_NAMESPACE
require_value MLFLOW_ARTIFACT_BUCKET

log "MLflow resources"
kubectl get pod,svc,pvc -n "${MLFLOW_NAMESPACE}" -o wide

kubectl rollout status deployment/mlflow-server -n "${MLFLOW_NAMESPACE}" --timeout=2m

if kubectl get statefulset mlflow-mysql -n "${MLFLOW_NAMESPACE}" >/dev/null 2>&1; then
    kubectl rollout status statefulset/mlflow-mysql -n "${MLFLOW_NAMESPACE}" --timeout=2m
fi

MLFLOW_POD="$(kubectl get pod -n "${MLFLOW_NAMESPACE}" -l app.kubernetes.io/name=mlflow -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "${MLFLOW_POD}" ]]; then
    MLFLOW_POD="$(kubectl get pod -n "${MLFLOW_NAMESPACE}" -l app.kubernetes.io/instance=mlflow -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi
if [[ -z "${MLFLOW_POD}" ]]; then
    MLFLOW_POD="$(kubectl get pod -n "${MLFLOW_NAMESPACE}" -o name | grep mlflow-server | head -n1 | cut -d/ -f2)"
fi
[[ -n "${MLFLOW_POD}" ]] || fatal "MLflow pod not found."

MLFLOW_PREFIX="/mlflow"

log "MLflow health"
kubectl exec -n "${MLFLOW_NAMESPACE}" "${MLFLOW_POD}" -- \
    python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:5000${MLFLOW_PREFIX}/health', timeout=5).read().decode())"

log "Backend DB connectivity"
kubectl exec -i -n "${MLFLOW_NAMESPACE}" "${MLFLOW_POD}" -- python - <<'PY'
import os
from sqlalchemy import create_engine, text

uri = os.environ["MLFLOW_BACKEND_STORE_URI"]

engine = create_engine(uri, pool_pre_ping=True)

with engine.connect() as connection:
    result = connection.execute(text("SELECT 1")).scalar()
    print("SELECT 1 =", result)
    assert result == 1

engine.dispose()

print("backend DB: PASS")
PY

log "Auth SQLite persistence"
kubectl exec -i -n "${MLFLOW_NAMESPACE}" "${MLFLOW_POD}" -- python - <<'PY'
from pathlib import Path
import sqlite3

db = Path("/mlflow/basic_auth.db")

print("db_exists =", db.exists())
print("db_size   =", db.stat().st_size if db.exists() else 0)

assert db.exists()
assert db.stat().st_size > 0

connection = sqlite3.connect(db)

tables = {
    row[0]
    for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    ).fetchall()
}

print("tables =", sorted(tables))

assert "users" in tables

connection.close()

print("auth sqlite: PASS")
PY

ADMIN_USERNAME="$(kubectl get secret mlflow-auth-secret -n "${MLFLOW_NAMESPACE}" -o jsonpath='{.data.MLFLOW_ADMIN_USERNAME}' | base64 -d)"
ADMIN_PASSWORD="$(kubectl get secret mlflow-auth-secret -n "${MLFLOW_NAMESPACE}" -o jsonpath='{.data.MLFLOW_ADMIN_PASSWORD}' | base64 -d)"

log "End-to-end Experiment / Run / Metric / Artifact validation"
kubectl exec -i -n "${MLFLOW_NAMESPACE}" "${MLFLOW_POD}" -- env \
    MLFLOW_TRACKING_USERNAME="${ADMIN_USERNAME}" \
    MLFLOW_TRACKING_PASSWORD="${ADMIN_PASSWORD}" \
    python - <<'PY'
import mlflow
import uuid

mlflow.set_tracking_uri('http://127.0.0.1:5000/mlflow')

exp = 'h200-install-validation'

mlflow.set_experiment(exp)

with mlflow.start_run(
    run_name='validation-' + uuid.uuid4().hex[:8]
) as run:

    mlflow.log_param('platform', 'h200')
    mlflow.log_param('tracking_db', 'mysql')

    mlflow.log_metric(
        'validation_score',
        1.0
    )

    mlflow.log_text(
        'MLflow H200 end-to-end validation succeeded.\n',
        'validation/result.txt'
    )

    print('experiment=', exp)
    print('run_id=', run.info.run_id)
    print('artifact_uri=', run.info.artifact_uri)

print('END-TO-END VALIDATION: PASS')
PY

unset ADMIN_PASSWORD

log "MLflow verification completed"
