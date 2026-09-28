# Uninstall policy

The `90-uninstall` scripts intentionally do **not** source `config/*.env`.
They discover installed resources from the live Kubernetes cluster and Helm state.
This keeps cleanup usable even after config/version files have changed.

## Principles

- Default: remove workloads/configuration but preserve PVC data when practical.
- `--purge-data`: delete the component's PVCs/data namespaces as well.
- Kubernetes reset is never automatic; run `98-reset-kubernetes.sh --yes-really-reset` explicitly.
- Uninstall scripts are version-independent. They do not use `versions.env`.

## Current SeaweedFS -> MinIO migration

```bash
./90-uninstall/91-uninstall-pipelines.sh
./90-uninstall/92-uninstall-object-storage.sh --purge-data

./60-object-storage/60-build-minio-image.sh
./60-object-storage/61-install-minio.sh
./60-object-storage/62-verify-minio.sh

./70-pipelines/71-install-pipelines.sh
./70-pipelines/72-configure-external-s3.sh
./70-pipelines/73-verify-pipelines.sh
```

If SeaweedFS contains data you need, omit `--purge-data` and migrate/backup the data before deleting its PVCs.
