#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ROOT="${DEV_ROOT:-$(cd "${REPO_DIR}/.." && pwd)}"
GO_BIN_DIR="${GO_BIN_DIR:-}"
if [ -n "${GO_BIN_DIR}" ]; then
  export PATH="${GO_BIN_DIR}:${PATH}"
fi
GO_BIN="${GO_BIN:-go}"
GO_MOD_VERSION="$(awk '/^go[[:space:]]+/ { print $2; exit }' "${REPO_DIR}/go.mod")"
if [ -z "${GO_MOD_VERSION}" ]; then
  echo "[run_celestia] ERROR: failed to read Go version from ${REPO_DIR}/go.mod" >&2
  exit 1
fi
DEFAULT_GOTOOLCHAIN="go${GO_MOD_VERSION}"

# Keep the same defaults used by the existing home-level launcher.
export CELESTIA_APPD_BIN="${CELESTIA_APPD_BIN:-${REPO_DIR}/build/celestia-appd}"
export DB_BACKEND="${DB_BACKEND:-treedb}"
export APP_DB_BACKEND="${APP_DB_BACKEND:-${DB_BACKEND}}"
export TREEDB_OPEN_PROFILE="${TREEDB_OPEN_PROFILE:-command_wal_durable}"
export TREEDB_FORCE_CHECKPOINT_ON_WRITE="${TREEDB_FORCE_CHECKPOINT_ON_WRITE:-0}"
if [ "${APP_DB_BACKEND}" = "treedb" ]; then
  export TREEDB_ENABLE_LEAF_GENERATION_PACK_MAINTENANCE="${TREEDB_ENABLE_LEAF_GENERATION_PACK_MAINTENANCE:-1}"
fi
# TreeDB no longer guarantees a stable "mode=" field in the open banner. Leave
# this empty unless you are intentionally testing a build that logs mode=.
export TREEDB_REQUIRED_OUTER_LEAF_MODE="${TREEDB_REQUIRED_OUTER_LEAF_MODE:-}"

# Optional local-module override for gomap to ensure celestia-appd is built
# against the active local TreeDB branch under development.
USE_LOCAL_GOMAP="${USE_LOCAL_GOMAP:-1}"
LOCAL_GOMAP_DIR="${LOCAL_GOMAP_DIR:-${DEV_ROOT}/gomap}"
LOCAL_COSMOS_DB_DIR="${LOCAL_COSMOS_DB_DIR:-${DEV_ROOT}/cosmos-db}"
LOCAL_COMET_DB_DIR="${LOCAL_COMET_DB_DIR:-${DEV_ROOT}/cometbft-db}"
LOCAL_COSMOS_STORE_DIR="${LOCAL_COSMOS_STORE_DIR:-${DEV_ROOT}/celestia-cosmos-sdk/store}"
LOCAL_COSMOS_LOG_DIR="${LOCAL_COSMOS_LOG_DIR:-${DEV_ROOT}/celestia-cosmos-sdk/log}"
LOCAL_COSMOS_CORE_DIR="${LOCAL_COSMOS_CORE_DIR:-${DEV_ROOT}/celestia-cosmos-sdk/core}"
LOCAL_IAVL_DIR="${LOCAL_IAVL_DIR:-${DEV_ROOT}/iavl}"
USE_LOCAL_IAVL="${USE_LOCAL_IAVL:-0}"
USE_LOCAL_COSMOS_STORE="${USE_LOCAL_COSMOS_STORE:-1}"

# Preferred mode for local forensics: use full local TreeDB stack
# (gomap + cosmos-db + cometbft-db) via a temporary absolute go.work.
USE_LOCAL_TREE_STACK="${USE_LOCAL_TREE_STACK:-1}"

printf '%s\n' "$(date)"
echo "[run_celestia] Building celestia-appd..."
(
  set -eu
  cd "${REPO_DIR}"

  if [ "${USE_LOCAL_TREE_STACK}" = "1" ]; then
    if [ ! -d "${LOCAL_GOMAP_DIR}" ] || [ ! -f "${LOCAL_GOMAP_DIR}/go.mod" ]; then
      echo "[run_celestia] ERROR: USE_LOCAL_TREE_STACK=1 but LOCAL_GOMAP_DIR is invalid: ${LOCAL_GOMAP_DIR}" >&2
      exit 1
    fi
    if [ ! -d "${LOCAL_COSMOS_DB_DIR}" ] || [ ! -f "${LOCAL_COSMOS_DB_DIR}/go.mod" ]; then
      echo "[run_celestia] ERROR: USE_LOCAL_TREE_STACK=1 but LOCAL_COSMOS_DB_DIR is invalid: ${LOCAL_COSMOS_DB_DIR}" >&2
      exit 1
    fi
    if [ ! -d "${LOCAL_COMET_DB_DIR}" ] || [ ! -f "${LOCAL_COMET_DB_DIR}/go.mod" ]; then
      echo "[run_celestia] ERROR: USE_LOCAL_TREE_STACK=1 but LOCAL_COMET_DB_DIR is invalid: ${LOCAL_COMET_DB_DIR}" >&2
      exit 1
    fi
    if [ "${USE_LOCAL_COSMOS_STORE}" = "1" ]; then
      if [ ! -d "${LOCAL_COSMOS_STORE_DIR}" ] || [ ! -f "${LOCAL_COSMOS_STORE_DIR}/go.mod" ]; then
        echo "[run_celestia] ERROR: USE_LOCAL_COSMOS_STORE=1 but LOCAL_COSMOS_STORE_DIR is invalid: ${LOCAL_COSMOS_STORE_DIR}" >&2
        exit 1
      fi
      if [ ! -d "${LOCAL_COSMOS_LOG_DIR}" ] || [ ! -f "${LOCAL_COSMOS_LOG_DIR}/go.mod" ]; then
        echo "[run_celestia] ERROR: USE_LOCAL_COSMOS_STORE=1 but LOCAL_COSMOS_LOG_DIR is invalid: ${LOCAL_COSMOS_LOG_DIR}" >&2
        exit 1
      fi
      if [ ! -d "${LOCAL_COSMOS_CORE_DIR}" ] || [ ! -f "${LOCAL_COSMOS_CORE_DIR}/go.mod" ]; then
        echo "[run_celestia] ERROR: USE_LOCAL_COSMOS_STORE=1 but LOCAL_COSMOS_CORE_DIR is invalid: ${LOCAL_COSMOS_CORE_DIR}" >&2
        exit 1
      fi
    fi
    if [ "${USE_LOCAL_IAVL}" = "1" ]; then
      if [ ! -d "${LOCAL_IAVL_DIR}" ] || [ ! -f "${LOCAL_IAVL_DIR}/go.mod" ]; then
        echo "[run_celestia] ERROR: USE_LOCAL_IAVL=1 but LOCAL_IAVL_DIR is invalid: ${LOCAL_IAVL_DIR}" >&2
        exit 1
      fi
    fi

    tmp_work="$(mktemp /tmp/run_celestia.XXXXXX.work)"
    cleanup() { rm -f "${tmp_work}"; }
    trap cleanup EXIT

    cat > "${tmp_work}" <<EOF
go ${GO_MOD_VERSION}

use (
  ${REPO_DIR}
  ${LOCAL_GOMAP_DIR}
  ${LOCAL_COSMOS_DB_DIR}
  ${LOCAL_COMET_DB_DIR}
EOF
    if [ "${USE_LOCAL_COSMOS_STORE}" = "1" ]; then
      cat >> "${tmp_work}" <<EOF
  ${LOCAL_COSMOS_STORE_DIR}
EOF
    fi
    cat >> "${tmp_work}" <<EOF
)

EOF
    if [ "${USE_LOCAL_IAVL}" = "1" ]; then
      cat >> "${tmp_work}" <<EOF
replace github.com/cosmos/iavl => ${LOCAL_IAVL_DIR}
EOF
    fi
    if [ "${USE_LOCAL_COSMOS_STORE}" = "1" ]; then
      cat >> "${tmp_work}" <<EOF
replace cosmossdk.io/log => ${LOCAL_COSMOS_LOG_DIR}
replace cosmossdk.io/core => ${LOCAL_COSMOS_CORE_DIR}
EOF
    fi
    "${GO_BIN}" work edit -fmt -workfile="${tmp_work}" >/dev/null 2>&1 || true
    GOTOOLCHAIN="${GOTOOLCHAIN:-${DEFAULT_GOTOOLCHAIN}}" \
      GOWORK="${tmp_work}" \
      "${GO_BIN}" build -o build/celestia-appd ./cmd/celestia-appd
  elif [ "${USE_LOCAL_GOMAP}" = "1" ]; then
    if [ ! -d "${LOCAL_GOMAP_DIR}" ] || [ ! -f "${LOCAL_GOMAP_DIR}/go.mod" ]; then
      echo "[run_celestia] ERROR: USE_LOCAL_GOMAP=1 but LOCAL_GOMAP_DIR is invalid: ${LOCAL_GOMAP_DIR}" >&2
      exit 1
    fi

    tmp_mod="$(mktemp "${REPO_DIR}/.run_celestia.mod.XXXXXX.mod")"
    tmp_sum="${tmp_mod%.mod}.sum"
    cleanup() { rm -f "${tmp_mod}" "${tmp_sum}"; }
    trap cleanup EXIT

    cp go.mod "${tmp_mod}"
    cp go.sum "${tmp_sum}"
    {
      echo ""
      echo "replace github.com/snissn/gomap => ${LOCAL_GOMAP_DIR}"
    } >> "${tmp_mod}"

    GOTOOLCHAIN="${GOTOOLCHAIN:-${DEFAULT_GOTOOLCHAIN}}" \
      GOWORK=off \
      "${GO_BIN}" build -modfile="${tmp_mod}" -o build/celestia-appd ./cmd/celestia-appd
  else
    GOTOOLCHAIN="${GOTOOLCHAIN:-${DEFAULT_GOTOOLCHAIN}}" \
      GOWORK=off \
      "${GO_BIN}" build -o build/celestia-appd ./cmd/celestia-appd
  fi
)

echo "[run_celestia] Build info (selected modules):"
"${GO_BIN}" version -m "${CELESTIA_APPD_BIN}" | rg -n "github.com/snissn/gomap|github.com/cosmos/cosmos-db|github.com/cometbft/cometbft-db|github.com/cosmos/iavl|=>"

if [ "${USE_LOCAL_TREE_STACK}" = "1" ]; then
  if ! "${GO_BIN}" version -m "${CELESTIA_APPD_BIN}" | grep -Fq $'dep\tgithub.com/snissn/gomap\t(devel)'; then
    echo "[run_celestia] ERROR: local gomap workspace override not active." >&2
    exit 1
  fi
  if ! "${GO_BIN}" version -m "${CELESTIA_APPD_BIN}" | grep -Fq $'dep\tgithub.com/cosmos/cosmos-db\t(devel)'; then
    echo "[run_celestia] ERROR: local cosmos-db workspace override not active." >&2
    exit 1
  fi
  if ! "${GO_BIN}" version -m "${CELESTIA_APPD_BIN}" | grep -Fq $'dep\tgithub.com/cometbft/cometbft-db\t(devel)'; then
    echo "[run_celestia] ERROR: local cometbft-db workspace override not active." >&2
    exit 1
  fi
  if [ "${USE_LOCAL_COSMOS_STORE}" = "1" ]; then
    if ! "${GO_BIN}" version -m "${CELESTIA_APPD_BIN}" | grep -Fq $'dep\tcosmossdk.io/store\t(devel)'; then
      echo "[run_celestia] ERROR: local cosmossdk.io/store workspace override not active." >&2
      exit 1
    fi
  fi
  if [ "${USE_LOCAL_IAVL}" = "1" ]; then
    if ! "${GO_BIN}" version -m "${CELESTIA_APPD_BIN}" | grep -Fq "${LOCAL_IAVL_DIR}"; then
      echo "[run_celestia] ERROR: local iavl override not active in build info." >&2
      exit 1
    fi
  fi
elif [ "${USE_LOCAL_GOMAP}" = "1" ]; then
  build_info="$("${GO_BIN}" version -m "${CELESTIA_APPD_BIN}")"
  if ! grep -Fq "${LOCAL_GOMAP_DIR}" <<<"${build_info}"; then
    if grep -Fq "github.com/snissn/gomap" <<<"${build_info}"; then
      echo "[run_celestia] ERROR: local gomap override not active in build info." >&2
      exit 1
    fi
    echo "[run_celestia] WARN: celestia-appd build metadata does not include github.com/snissn/gomap; USE_LOCAL_GOMAP has no app-binary effect in this module graph." >&2
  fi
fi

if [ "${APP_DB_BACKEND}" = "treedb" ]; then
  if [ ! -d "${LOCAL_GOMAP_DIR}" ] || [ ! -f "${LOCAL_GOMAP_DIR}/go.mod" ]; then
    echo "[run_celestia] ERROR: APP_DB_BACKEND=treedb requires LOCAL_GOMAP_DIR to build treemap: ${LOCAL_GOMAP_DIR}" >&2
    exit 1
  fi
  TREEMAP_BIN="${TREEMAP_BIN:-${REPO_DIR}/build/treemap-local}"
  echo "[run_celestia] Building treemap from local gomap: ${LOCAL_GOMAP_DIR}"
  (
    set -eu
    cd "${LOCAL_GOMAP_DIR}"
    treemap_pkg="./TreeDB/cmd/treemap"
    if [ ! -d "${LOCAL_GOMAP_DIR}/TreeDB/cmd/treemap" ] && [ -d "${LOCAL_GOMAP_DIR}/cmd/treemap" ]; then
      treemap_pkg="./cmd/treemap"
    fi
    GOTOOLCHAIN="${GOTOOLCHAIN:-${DEFAULT_GOTOOLCHAIN}}" \
      GOWORK=off \
      "${GO_BIN}" build -o "${TREEMAP_BIN}" "${treemap_pkg}"
  )
  export TREEMAP_BIN
  echo "[run_celestia] treemap binary: ${TREEMAP_BIN}"
  "${GO_BIN}" version -m "${TREEMAP_BIN}" | rg -n "github.com/snissn/gomap|=>"
fi

if [ "${RUN_CELESTIA_BUILD_ONLY:-0}" = "1" ]; then
  echo "[run_celestia] Build-only validation complete."
  exit 0
fi

echo "[run_celestia] Starting monitored sync..."
exec "${REPO_DIR}/scripts/mainnet-treedb-fast-sync-forensics.sh" "$@"
