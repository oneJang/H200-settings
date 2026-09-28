from kfp import compiler
from kfp import dsl
from kfp import kubernetes


MLFLOW_TRACKING_URI = "http://mlflow-server.mlflow.svc.cluster.local:5000/mlflow"

MINIO_ENDPOINT_URL = "http://minio.object-storage.svc.cluster.local:9000"

MLFLOW_ARTIFACT_BUCKET = "mlflow-artifacts"

SMOKE_SECRET = "mlops-smoke-credentials"


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
                "smoke test succeeded.\n"
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
        package_path="/home/clabi/h200-infra-kfp-minio-ready/generated/mlops-smoke-pipeline.yaml",
    )
