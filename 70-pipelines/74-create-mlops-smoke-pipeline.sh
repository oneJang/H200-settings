#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/config/kubeflow.env"
source "${ROOT_DIR}/config/mlflow.env"
source "${ROOT_DIR}/config/object-storage.env"

require_command python3
require_command kubectl

require_value KUBEFLOW_PROFILE

require_value MLFLOW_NAMESPACE
require_value MLFLOW_RELEASE_NAME

require_value MINIO_NAMESPACE
require_value MINIO_S3_SERVICE
require_value MINIO_S3_PORT

require_value MLFLOW_ARTIFACT_BUCKET


# ============================================================
# Configuration
# ============================================================

GENERATED_DIR="${ROOT_DIR}/generated"

PIPELINE_SOURCE="${GENERATED_DIR}/mlops-smoke-pipeline.py"
PIPELINE_PACKAGE="${GENERATED_DIR}/mlops-smoke-pipeline.yaml"

VENV_DIR="${GENERATED_DIR}/.kfp-smoke-venv"

MLFLOW_SERVICE="${MLFLOW_RELEASE_NAME}-server"

MLFLOW_TRACKING_URI="http://${MLFLOW_SERVICE}.${MLFLOW_NAMESPACE}.svc.cluster.local:5000/mlflow"

MINIO_ENDPOINT_URL="http://${MINIO_S3_SERVICE}.${MINIO_NAMESPACE}.svc.cluster.local:${MINIO_S3_PORT}"

SMOKE_SECRET="mlops-smoke-credentials"

KFP_SDK_VERSION="2.16.1"


mkdir -p "${GENERATED_DIR}"


# ============================================================
# Validate Python venv support
# ============================================================

log "Checking Python virtual environment support"


VENV_TEST_DIR="$(mktemp -d /tmp/h200-kfp-venv-test.XXXXXX)"


if ! python3 -m venv "${VENV_TEST_DIR}" >/dev/null 2>&1; then

    rm -rf "${VENV_TEST_DIR}"

    fatal \
        "Python venv support is unavailable. Install it with: sudo apt-get install -y python3-venv"

fi


rm -rf "${VENV_TEST_DIR}"


# ============================================================
# Prepare Python virtual environment
#
# A previous failed python3 -m venv can leave a partially
# created directory. Therefore check both Python and pip.
# ============================================================

log "Preparing temporary Python environment"


if [[ ! -x "${VENV_DIR}/bin/python" ]] \
    || ! "${VENV_DIR}/bin/python" -m pip --version >/dev/null 2>&1; then

    log "Creating Python virtual environment"

    rm -rf "${VENV_DIR}"

    python3 -m venv "${VENV_DIR}"

fi


# ============================================================
# Install compiler dependencies
#
# Keep the SDK version aligned with the installed KFP release.
# kfp-kubernetes provides Kubernetes-specific task modifiers,
# including Secret -> environment variable injection.
# ============================================================

log "Installing KFP compiler dependencies"


"${VENV_DIR}/bin/python" -m pip install \
    --upgrade pip \
    >/dev/null


"${VENV_DIR}/bin/python" -m pip install \
    "kfp==${KFP_SDK_VERSION}" \
    "kfp-kubernetes==${KFP_SDK_VERSION}" \
    >/dev/null


log "KFP SDK version"

"${VENV_DIR}/bin/python" -c \
    'import kfp; print(kfp.__version__)'


# ============================================================
# Generate Pipeline source
# ============================================================

log "Creating MLOps smoke-test Pipeline source"


cat > "${PIPELINE_SOURCE}" <<PY
from kfp import compiler
from kfp import dsl
from kfp import kubernetes


MLFLOW_TRACKING_URI = "${MLFLOW_TRACKING_URI}"

MINIO_ENDPOINT_URL = "${MINIO_ENDPOINT_URL}"

MLFLOW_ARTIFACT_BUCKET = "${MLFLOW_ARTIFACT_BUCKET}"

SMOKE_SECRET = "${SMOKE_SECRET}"


# ============================================================
# Component
# ============================================================

@dsl.component(
    base_image="python:3.11-slim",
    packages_to_install=[
        "mlflow==3.13.0",
        "boto3",
    ],
)
def mlops_smoke_test(
    mlflow_tracking_uri: str,
    minio_endpoint_url: str,
    mlflow_artifact_bucket: str,
):
    import os
    import uuid

    import boto3
    import mlflow


    print("============================================")
    print("MLOps smoke test")
    print("============================================")

    print("MLflow URI :", mlflow_tracking_uri)
    print("MinIO URI  :", minio_endpoint_url)
    print("Bucket     :", mlflow_artifact_bucket)


    # --------------------------------------------------------
    # Required credentials
    # --------------------------------------------------------

    required_environment = [
        "MLFLOW_TRACKING_USERNAME",
        "MLFLOW_TRACKING_PASSWORD",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_DEFAULT_REGION",
        "MLFLOW_S3_ENDPOINT_URL",
    ]


    missing = [
        name
        for name in required_environment
        if not os.environ.get(name)
    ]


    if missing:

        raise RuntimeError(
            "Required environment variables are missing: "
            + ", ".join(missing)
        )


    # --------------------------------------------------------
    # MLflow authentication
    # --------------------------------------------------------

    mlflow_username = os.environ[
        "MLFLOW_TRACKING_USERNAME"
    ]

    mlflow_password = os.environ[
        "MLFLOW_TRACKING_PASSWORD"
    ]


    os.environ[
        "MLFLOW_TRACKING_USERNAME"
    ] = mlflow_username

    os.environ[
        "MLFLOW_TRACKING_PASSWORD"
    ] = mlflow_password


    # --------------------------------------------------------
    # MinIO / S3 configuration
    #
    # mlflow-artifact-secret already provides these values,
    # but explicitly keep the endpoint aligned with the
    # Pipeline argument as well.
    # --------------------------------------------------------

    s3_access_key = os.environ[
        "AWS_ACCESS_KEY_ID"
    ]

    s3_secret_key = os.environ[
        "AWS_SECRET_ACCESS_KEY"
    ]


    os.environ[
        "MLFLOW_S3_ENDPOINT_URL"
    ] = minio_endpoint_url


    # --------------------------------------------------------
    # 1. Direct MinIO validation
    #
    # This validates:
    #
    #   Pipeline Pod
    #       ->
    #   MinIO Service
    #       ->
    #   mlflow-artifacts bucket
    # --------------------------------------------------------

    print()
    print("============================================")
    print("Direct MinIO validation")
    print("============================================")


    s3 = boto3.client(
        "s3",
        endpoint_url=minio_endpoint_url,
        aws_access_key_id=s3_access_key,
        aws_secret_access_key=s3_secret_key,
        region_name=os.environ.get(
            "AWS_DEFAULT_REGION",
            "us-east-1",
        ),
    )


    response = s3.list_objects_v2(
        Bucket=mlflow_artifact_bucket,
        MaxKeys=1,
    )


    http_status = (
        response
        .get("ResponseMetadata", {})
        .get("HTTPStatusCode")
    )


    if http_status != 200:

        raise RuntimeError(
            "MinIO bucket validation failed: "
            f"HTTP {http_status}"
        )


    print(
        "MinIO bucket access:",
        http_status,
    )


    # --------------------------------------------------------
    # 2. MLflow validation
    #
    # This validates:
    #
    #   Pipeline Pod
    #       ->
    #   MLflow Tracking Server
    #       ->
    #   MySQL backend
    #
    # and:
    #
    #   MLflow artifact
    #       ->
    #   MinIO
    # --------------------------------------------------------

    print()
    print("============================================")
    print("MLflow validation")
    print("============================================")


    mlflow.set_tracking_uri(
        mlflow_tracking_uri
    )


    experiment_name = (
        "kfp-mlops-smoke-test"
    )


    mlflow.set_experiment(
        experiment_name
    )


    run_name = (
        "smoke-"
        + uuid.uuid4().hex[:8]
    )


    with mlflow.start_run(
        run_name=run_name
    ) as run:

        mlflow.log_param(
            "pipeline",
            "kubeflow-pipelines",
        )

        mlflow.log_param(
            "purpose",
            "infrastructure-smoke-test",
        )

        mlflow.log_param(
            "artifact_store",
            "minio",
        )


        mlflow.log_metric(
            "smoke_test_score",
            1.0,
        )


        mlflow.log_text(
            (
                "KFP -> MLflow -> MinIO "
                "smoke test succeeded.\\n"
            ),
            "smoke-test/result.txt",
        )


        print(
            "experiment =",
            experiment_name,
        )

        print(
            "run_id     =",
            run.info.run_id,
        )

        print(
            "artifact   =",
            run.info.artifact_uri,
        )


    print()
    print("============================================")
    print("MLOPS SMOKE TEST: PASS")
    print("============================================")


# ============================================================
# Pipeline
# ============================================================

@dsl.pipeline(
    name="mlops-smoke-test",
    description=(
        "Validate KFP -> MLflow -> MinIO integration"
    ),
)
def pipeline():

    task = mlops_smoke_test(
        mlflow_tracking_uri=MLFLOW_TRACKING_URI,
        minio_endpoint_url=MINIO_ENDPOINT_URL,
        mlflow_artifact_bucket=MLFLOW_ARTIFACT_BUCKET,
    )


    # --------------------------------------------------------
    # Resource request
    #
    # Keep the normal Pipeline definition unchanged.
    #
    # The current local VM is resource-constrained, so during
    # VM validation this can be adjusted temporarily on the
    # live Workflow if necessary.
    #
    # Do not make the production definition depend on the
    # small validation VM.
    # --------------------------------------------------------

    task.set_cpu_request(
        "100m"
    )

    task.set_memory_request(
        "256Mi"
    )


    # --------------------------------------------------------
    # Inject credentials from the Profile-scoped Secret
    #
    # 75-run-mlops-smoke-pipeline.sh creates:
    #
    #   kubeflow-user-example-com/
    #   mlops-smoke-credentials
    #
    # Secret values are never embedded into the compiled
    # Pipeline YAML.
    # --------------------------------------------------------

    kubernetes.use_secret_as_env(
        task,
        secret_name=SMOKE_SECRET,
        secret_key_to_env={
            "MLFLOW_TRACKING_USERNAME":
                "MLFLOW_TRACKING_USERNAME",

            "MLFLOW_TRACKING_PASSWORD":
                "MLFLOW_TRACKING_PASSWORD",

            "AWS_ACCESS_KEY_ID":
                "AWS_ACCESS_KEY_ID",

            "AWS_SECRET_ACCESS_KEY":
                "AWS_SECRET_ACCESS_KEY",

            "AWS_DEFAULT_REGION":
                "AWS_DEFAULT_REGION",

            "MLFLOW_S3_ENDPOINT_URL":
                "MLFLOW_S3_ENDPOINT_URL",
        },
    )


# ============================================================
# Compile
# ============================================================

if __name__ == "__main__":

    compiler.Compiler().compile(
        pipeline_func=pipeline,
        package_path="${PIPELINE_PACKAGE}",
    )
PY


# ============================================================
# Compile Pipeline
# ============================================================

log "Compiling MLOps smoke-test Pipeline"


"${VENV_DIR}/bin/python" \
    "${PIPELINE_SOURCE}"


[[ -s "${PIPELINE_PACKAGE}" ]] \
    || fatal \
        "Pipeline package was not created: ${PIPELINE_PACKAGE}"


# ============================================================
# Validate compiled Pipeline
# ============================================================

log "Validating compiled Pipeline"


# The Secret name must be present in the generated package.
grep -q \
    "${SMOKE_SECRET}" \
    "${PIPELINE_PACKAGE}" \
    || fatal \
        "Compiled Pipeline does not reference ${SMOKE_SECRET}"


# Secret values themselves must NOT appear in the package.
#
# Only Secret references should exist.
if grep -q \
    "MLFLOW_TRACKING_PASSWORD.*value:" \
    "${PIPELINE_PACKAGE}"; then

    fatal \
        "Compiled Pipeline may contain a plaintext MLflow password."

fi


# ============================================================
# Completed
# ============================================================

log "MLOps smoke-test Pipeline package created"


echo
echo "Pipeline source:"
echo "  ${PIPELINE_SOURCE}"

echo
echo "Pipeline package:"
echo "  ${PIPELINE_PACKAGE}"

echo
echo "KFP SDK:"
echo "  ${KFP_SDK_VERSION}"

echo
echo "MLflow:"
echo "  ${MLFLOW_TRACKING_URI}"

echo
echo "MinIO:"
echo "  ${MINIO_ENDPOINT_URL}"

echo
echo "Artifact bucket:"
echo "  ${MLFLOW_ARTIFACT_BUCKET}"

echo
echo "Runtime Secret:"
echo "  ${KUBEFLOW_PROFILE}/${SMOKE_SECRET}"

echo
