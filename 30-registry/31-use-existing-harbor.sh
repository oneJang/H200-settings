#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "[WARN] 31-use-existing-harbor.sh is kept for compatibility; use 31-use-existing-registry.sh." >&2
exec "${SCRIPT_DIR}/31-use-existing-registry.sh" "$@"
