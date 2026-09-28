# 80-mlflow

MLflow 3.13.0 deployment for the H200 Kubernetes platform.

Design:
- Official MLflow Helm chart (chart 0.1.0, appVersion 3.13.0)
- Thin runtime image based on official `ghcr.io/mlflow/mlflow:v3.13.0-full`
  with `mlflow[auth]`, `pymysql`, and `boto3`
- Tracking backend: MySQL (`internal` or `external`)
- Basic Auth database: SQLite on MLflow PVC
- Artifact store: existing MinIO `mlflow-artifacts` bucket
- MinIO runtime identity dedicated to MLflow
- Registry transport reused from `config/registry.env`

Expected parent layout:

```
h200-infra/
├── config/
│   ├── versions.env
│   ├── registry.env
│   ├── object-storage.env
│   └── mlflow.env
├── lib/common.sh
└── 80-mlflow/
```

Execution order:

```
81-prepare-mlflow.sh
82-publish-mlflow-image.sh
83-install-mysql.sh
84-configure-mlflow-storage.sh
85-install-mlflow.sh
86-verify-mlflow.sh
# 87 is optional
```

For an offline H200, run `81-prepare-mlflow.sh` on an Internet-connected preparation host first so the official Helm chart is cached under `80-mlflow/vendor/`. The runtime image must also be delivered through the configured OCI registry or imported locally with step 82.

## MLflow 3.13.0 chart pinning note

Do not fetch the OCI chart only by chart version `0.1.0` for MLflow 3.13.0.
The same chart version has been observed resolving to a later appVersion from GHCR.
`81-prepare-mlflow.sh` therefore downloads the exact MLflow source tag `v${MLFLOW_VERSION}`,
validates both `Chart.yaml.version` and `Chart.yaml.appVersion`, packages the chart locally,
and caches it as `vendor/mlflow-v${MLFLOW_VERSION}.tgz` for offline H200 reuse.
