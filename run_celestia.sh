#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Keep the same defaults used by the existing home-level launcher.
export CELESTIA_APPD_BIN="${CELESTIA_APPD_BIN:-${REPO_DIR}/build/celestia-appd}"
export PATH="/home/mikers/go1.23.4/bin:${PATH}"
export DB_BACKEND="${DB_BACKEND:-treedb}"
export APP_DB_BACKEND="${APP_DB_BACKEND:-${DB_BACKEND}}"

printf '%s\n' "$(date)"
echo "[run_celestia] Building celestia-appd..."
(
  set -eu
  cd "${REPO_DIR}"
  PATH="/home/mikers/go1.23.4/bin:${PATH}" GOTOOLCHAIN="${GOTOOLCHAIN:-go1.25.5}" go build -o build/celestia-appd ./cmd/celestia-appd
)

echo "[run_celestia] Starting monitored sync..."
exec "${REPO_DIR}/scripts/mainnet-treedb-fast-sync-forensics.sh" "$@"
