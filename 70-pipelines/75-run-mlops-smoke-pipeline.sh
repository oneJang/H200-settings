#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/kubeflow.env"
source "${ROOT_DIR}/config/mlflow.env"

require_command kubectl

require_value KUBEFLOW_PROFILE
require_value MLFLOW_NAMESPACE


# ============================================================
# Configuration
# ============================================================

GENERATED_DIR="${ROOT_DIR}/generated"

PIPELINE_PACKAGE="${GENERATED_DIR}/mlops-smoke-pipeline.yaml"

SUBMITTER_POD="mlops-smoke-submitter"

KFP_NAMESPACE="kubeflow"
KFP_HOST="http://ml-pipeline.${KFP_NAMESPACE}.svc.cluster.local:8888"

SMOKE_SECRET="mlops-smoke-credentials"

MLFLOW_AUTH_SECRET="mlflow-auth-secret"
MLFLOW_ARTIFACT_SECRET="mlflow-artifact-secret"

TOKEN_PATH="/var/run/secrets/kubeflow/pipelines/token"


# ============================================================
# Validate Pipeline package
# ============================================================

log "Validating MLOps smoke-test Pipeline package"


[[ -s "${PIPELINE_PACKAGE}" ]] \
    || fatal \
        "Pipeline package not found: ${PIPELINE_PACKAGE}. Run 74-create-mlops-smoke-pipeline.sh first."


kubectl get namespace \
    "${KUBEFLOW_PROFILE}" \
    >/dev/null \
    || fatal \
        "Kubeflow Profile namespace not found: ${KUBEFLOW_PROFILE}"


kubectl get service \
    ml-pipeline \
    -n "${KFP_NAMESPACE}" \
    >/dev/null \
    || fatal \
        "KFP API Service not found: ${KFP_NAMESPACE}/ml-pipeline"


# ============================================================
# Select ServiceAccount
#
# Kubeflow Profile normally provides default-editor.
# Prefer it because the submitted Pipeline belongs to the
# Profile namespace.
# ============================================================

if kubectl get serviceaccount \
    default-editor \
    -n "${KUBEFLOW_PROFILE}" \
    >/dev/null 2>&1; then

    SUBMITTER_SERVICE_ACCOUNT="default-editor"

else

    warn \
        "ServiceAccount default-editor not found. Falling back to default."

    SUBMITTER_SERVICE_ACCOUNT="default"

fi


log "Using ServiceAccount: ${SUBMITTER_SERVICE_ACCOUNT}"


# ============================================================
# Validate MLflow Secrets
# ============================================================

log "Validating MLflow Secrets"


kubectl get secret \
    "${MLFLOW_AUTH_SECRET}" \
    -n "${MLFLOW_NAMESPACE}" \
    >/dev/null \
    || fatal \
        "MLflow auth Secret not found: ${MLFLOW_NAMESPACE}/${MLFLOW_AUTH_SECRET}"


kubectl get secret \
    "${MLFLOW_ARTIFACT_SECRET}" \
    -n "${MLFLOW_NAMESPACE}" \
    >/dev/null \
    || fatal \
        "MLflow artifact Secret not found: ${MLFLOW_NAMESPACE}/${MLFLOW_ARTIFACT_SECRET}"


# ============================================================
# Read MLflow credentials
# ============================================================

log "Preparing MLOps smoke-test credentials"


MLFLOW_USERNAME="$(
    kubectl get secret \
        "${MLFLOW_AUTH_SECRET}" \
        -n "${MLFLOW_NAMESPACE}" \
        -o jsonpath='{.data.MLFLOW_ADMIN_USERNAME}' \
    | base64 -d
)"


MLFLOW_PASSWORD="$(
    kubectl get secret \
        "${MLFLOW_AUTH_SECRET}" \
        -n "${MLFLOW_NAMESPACE}" \
        -o jsonpath='{.data.MLFLOW_ADMIN_PASSWORD}' \
    | base64 -d
)"


AWS_ACCESS_KEY_ID="$(
    kubectl get secret \
        "${MLFLOW_ARTIFACT_SECRET}" \
        -n "${MLFLOW_NAMESPACE}" \
        -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' \
    | base64 -d
)"


AWS_SECRET_ACCESS_KEY="$(
    kubectl get secret \
        "${MLFLOW_ARTIFACT_SECRET}" \
        -n "${MLFLOW_NAMESPACE}" \
        -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' \
    | base64 -d
)"


AWS_DEFAULT_REGION="$(
    kubectl get secret \
        "${MLFLOW_ARTIFACT_SECRET}" \
        -n "${MLFLOW_NAMESPACE}" \
        -o jsonpath='{.data.AWS_DEFAULT_REGION}' \
    | base64 -d
)"


MLFLOW_S3_ENDPOINT_URL="$(
    kubectl get secret \
        "${MLFLOW_ARTIFACT_SECRET}" \
        -n "${MLFLOW_NAMESPACE}" \
        -o jsonpath='{.data.MLFLOW_S3_ENDPOINT_URL}' \
    | base64 -d
)"


[[ -n "${MLFLOW_USERNAME}" ]] \
    || fatal "MLflow username is empty."

[[ -n "${MLFLOW_PASSWORD}" ]] \
    || fatal "MLflow password is empty."

[[ -n "${AWS_ACCESS_KEY_ID}" ]] \
    || fatal "MLflow artifact access key is empty."

[[ -n "${AWS_SECRET_ACCESS_KEY}" ]] \
    || fatal "MLflow artifact secret key is empty."

[[ -n "${MLFLOW_S3_ENDPOINT_URL}" ]] \
    || fatal "MLflow S3 endpoint URL is empty."


# ============================================================
# Create Profile-scoped smoke-test Secret
#
# Pipeline Pods cannot directly consume Secrets from the
# mlflow namespace, so copy only the required values into the
# Profile namespace.
# ============================================================

log "Creating Profile-scoped MLOps smoke-test Secret"


kubectl create secret generic \
    "${SMOKE_SECRET}" \
    -n "${KUBEFLOW_PROFILE}" \
    --from-literal=MLFLOW_TRACKING_USERNAME="${MLFLOW_USERNAME}" \
    --from-literal=MLFLOW_TRACKING_PASSWORD="${MLFLOW_PASSWORD}" \
    --from-literal=AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
    --from-literal=AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
    --from-literal=AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION}" \
    --from-literal=MLFLOW_S3_ENDPOINT_URL="${MLFLOW_S3_ENDPOINT_URL}" \
    --dry-run=client \
    -o yaml \
| kubectl apply -f -


# Remove sensitive shell variables as soon as possible.
unset MLFLOW_PASSWORD
unset AWS_SECRET_ACCESS_KEY


kubectl get secret \
    "${SMOKE_SECRET}" \
    -n "${KUBEFLOW_PROFILE}" \
    >/dev/null \
    || fatal \
        "Failed to create ${KUBEFLOW_PROFILE}/${SMOKE_SECRET}"


# ============================================================
# Temporary files
# ============================================================

TMP_DIR="$(mktemp -d /tmp/h200-kfp-submit.XXXXXX)"

SUBMIT_SCRIPT="${TMP_DIR}/submit.py"


cleanup() {

    kubectl delete pod \
        "${SUBMITTER_POD}" \
        -n "${KUBEFLOW_PROFILE}" \
        --ignore-not-found \
        --wait=false \
        >/dev/null 2>&1 \
        || true

    rm -rf "${TMP_DIR}"
}

trap cleanup EXIT


# ============================================================
# Create KFP submission script
#
# Important:
#
# Do NOT spoof kubeflow-userid.
#
# Kubeflow multi-user KFP authenticates this request using a
# projected ServiceAccount token whose audience is
# pipelines.kubeflow.org.
# ============================================================

cat > "${SUBMIT_SCRIPT}" <<PY
import os
import kfp


HOST = "${KFP_HOST}"
NAMESPACE = "${KUBEFLOW_PROFILE}"

TOKEN_PATH = os.environ.get(
    "KF_PIPELINES_SA_TOKEN_PATH",
    "${TOKEN_PATH}",
)


print("KFP host      :", HOST)
print("KFP namespace :", NAMESPACE)
print("Token path    :", TOKEN_PATH)


if not os.path.isfile(TOKEN_PATH):
    raise RuntimeError(
        f"KFP ServiceAccount token not found: {TOKEN_PATH}"
    )


with open(
    TOKEN_PATH,
    "r",
    encoding="utf-8",
) as f:
    token = f.read().strip()


if not token:
    raise RuntimeError(
        "KFP ServiceAccount token is empty."
    )


client = kfp.Client(
    host=HOST,
    namespace=NAMESPACE,
    existing_token=token,
)


run = client.create_run_from_pipeline_package(
    "/tmp/mlops-smoke-pipeline.yaml",
    arguments={},
    run_name="mlops-smoke-test",
    namespace=NAMESPACE,
)


print()
print("Pipeline submitted successfully.")
print("run_id   =", run.run_id)
print("run_name =", RUN_NAME)
PY


# ============================================================
# Remove previous submitter Pod
# ============================================================

log "Removing previous KFP submitter Pod"


kubectl delete pod \
    "${SUBMITTER_POD}" \
    -n "${KUBEFLOW_PROFILE}" \
    --ignore-not-found \
    --wait=true


# ============================================================
# Create submitter Pod
#
# A projected ServiceAccount token is mounted explicitly with:
#
#   audience: pipelines.kubeflow.org
#
# This is the authentication mechanism expected by multi-user
# Kubeflow Pipelines.
# ============================================================

log "Creating KFP submitter Pod"


cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod

metadata:
  name: ${SUBMITTER_POD}
  namespace: ${KUBEFLOW_PROFILE}

spec:

  serviceAccountName: ${SUBMITTER_SERVICE_ACCOUNT}

  restartPolicy: Never

  containers:

    - name: submitter

      image: python:3.11-slim

      command:
        - sh
        - -c
        - |
          set -e

          echo "[submitter] Installing KFP SDK..."

          python -m pip install \
            --no-cache-dir \
            "kfp>=2.16.1"

          python -c \
            'import kfp; print("[submitter] KFP SDK version:", kfp.__version__)'

          touch /tmp/kfp-sdk-ready

          echo "[submitter] KFP SDK ready."

          sleep infinity

      env:

        - name: KF_PIPELINES_SA_TOKEN_PATH
          value: ${TOKEN_PATH}

      volumeMounts:

        - name: volume-kf-pipeline-token
          mountPath: /var/run/secrets/kubeflow/pipelines
          readOnly: true

  volumes:

    - name: volume-kf-pipeline-token

      projected:

        sources:

          - serviceAccountToken:
              path: token
              expirationSeconds: 7200
              audience: pipelines.kubeflow.org
EOF


# ============================================================
# Wait for submitter Pod
# ============================================================

log "Waiting for KFP submitter Pod"


kubectl wait \
    --for=condition=Ready \
    "pod/${SUBMITTER_POD}" \
    -n "${KUBEFLOW_PROFILE}" \
    --timeout=10m


# ============================================================
# Wait until KFP SDK installation actually finishes
#
# Pod Ready != pip installation complete.
# ============================================================

log "Waiting for KFP SDK installation"


MAX_ATTEMPTS=120
ATTEMPT=1


while true; do

    if kubectl exec \
        -n "${KUBEFLOW_PROFILE}" \
        "${SUBMITTER_POD}" \
        -- \
        test -f /tmp/kfp-sdk-ready \
        >/dev/null 2>&1; then

        break

    fi


    POD_PHASE="$(
        kubectl get pod \
            "${SUBMITTER_POD}" \
            -n "${KUBEFLOW_PROFILE}" \
            -o jsonpath='{.status.phase}'
    )"


    if [[ "${POD_PHASE}" == "Failed" ]]; then

        echo
        kubectl logs \
            "${SUBMITTER_POD}" \
            -n "${KUBEFLOW_PROFILE}" \
            || true

        fatal \
            "KFP submitter Pod failed while installing KFP SDK."

    fi


    if (( ATTEMPT >= MAX_ATTEMPTS )); then

        echo
        kubectl logs \
            "${SUBMITTER_POD}" \
            -n "${KUBEFLOW_PROFILE}" \
            || true

        fatal \
            "Timed out waiting for KFP SDK installation."

    fi


    sleep 5

    ATTEMPT=$((ATTEMPT + 1))

done


log "KFP SDK installation completed"


kubectl exec \
    -n "${KUBEFLOW_PROFILE}" \
    "${SUBMITTER_POD}" \
    -- \
    python -c \
    'import kfp; print("KFP SDK:", kfp.__version__)'


# ============================================================
# Verify projected token
#
# Do not print the token itself.
# ============================================================

log "Checking KFP ServiceAccount token"


kubectl exec \
    -n "${KUBEFLOW_PROFILE}" \
    "${SUBMITTER_POD}" \
    -- \
    test -s "${TOKEN_PATH}" \
    || fatal \
        "Projected KFP ServiceAccount token is missing or empty."


echo "KFP projected ServiceAccount token: PASS"


# ============================================================
# Copy Pipeline package
# ============================================================

log "Copying MLOps smoke-test Pipeline package"


kubectl cp \
    "${PIPELINE_PACKAGE}" \
    "${KUBEFLOW_PROFILE}/${SUBMITTER_POD}:/tmp/mlops-smoke-pipeline.yaml"


# ============================================================
# Copy submission script
# ============================================================

log "Copying KFP submission script"


kubectl cp \
    "${SUBMIT_SCRIPT}" \
    "${KUBEFLOW_PROFILE}/${SUBMITTER_POD}:/tmp/submit.py"


# ============================================================
# Submit Pipeline
# ============================================================

log "Submitting MLOps smoke-test Pipeline"


kubectl exec \
    -n "${KUBEFLOW_PROFILE}" \
    "${SUBMITTER_POD}" \
    -- \
    python /tmp/submit.py


# ============================================================
# Completed
# ============================================================

log "MLOps smoke-test Pipeline submitted successfully"


echo
echo "Profile namespace:"
echo "  ${KUBEFLOW_PROFILE}"

echo
echo "KFP endpoint:"
echo "  ${KFP_HOST}"

echo
echo "Pipeline:"
echo "  mlops-smoke-test"

echo
echo "Check from Kubeflow Dashboard:"
echo
echo "  Pipelines"
echo "    -> Runs"
echo "    -> mlops-smoke-test"
echo
