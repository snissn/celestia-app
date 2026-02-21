#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if ! command -v jq >/dev/null 2>&1;
then
  echo "jq is required for this script."
  exit 1
fi

APPD_BIN="${CELESTIA_APPD_BIN:-${REPO_DIR}/build/celestia-appd}"
if [ ! -x "${APPD_BIN}" ];
then
  echo "celestia-appd not found; run 'make install-standalone' or set CELESTIA_APPD_BIN."
  exit 1
fi

CHAIN_ID="celestia"
RPC1="https://celestia.rpc.kjnodes.com"
RPC2="https://celestia-rpc.polkachu.com:443"
CURL_OPTS="--max-time 10 --connect-timeout 5 --retry 3 --retry-delay 2"
LOCAL_RPC="http://127.0.0.1:36657"
P2P_LADDR="tcp://0.0.0.0:36656"
RPC_LADDR="tcp://127.0.0.1:36657"
PPROF_LADDR="localhost:6062"
DB_BACKEND="${DB_BACKEND:-treedb}"
APP_DB_BACKEND="${APP_DB_BACKEND:-${DB_BACKEND}}"

TS="$(date +%Y%m%d%H%M%S)"
HOME_DIR="${HOME}/.celestia-app-mainnet-${DB_BACKEND}-${TS}"
LOG_DIR="${HOME_DIR}/sync"
NODE_LOG="${LOG_DIR}/node.log"
TIME_LOG="${LOG_DIR}/sync-time.log"

POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"
WAIT_RPC_TIMEOUT_SECONDS="${WAIT_RPC_TIMEOUT_SECONDS:-180}"
NO_PROGRESS_WARN_SECONDS="${NO_PROGRESS_WARN_SECONDS:-60}"
NO_PROGRESS_FAIL_SECONDS="${NO_PROGRESS_FAIL_SECONDS:-600}"
STUCK_REPORT_INTERVAL_SECONDS="${STUCK_REPORT_INTERVAL_SECONDS:-30}"
MAX_LOCAL_RPC_FAILURES="${MAX_LOCAL_RPC_FAILURES:-6}"
LOG_ERROR_SCAN_LINES="${LOG_ERROR_SCAN_LINES:-300}"

ERROR_PATTERNS='valuelog: corrupt record|state sync failed|state sync aborted|failed to restore snapshot|IAVL node import failed|IAVL commit failed|panic:|fatal'

log_info() {
  echo "[$(date +%H:%M:%S)] INFO  $*"
}

log_warn() {
  echo "[$(date +%H:%M:%S)] WARN  $*"
}

log_error() {
  echo "[$(date +%H:%M:%S)] ERROR $*" >&2
}

print_recent_log_excerpt() {
  if [ -f "${NODE_LOG}" ]; then
    log_info "Node log: ${NODE_LOG}"
    log_info "Last 30 node-log lines:"
    tail -n 30 "${NODE_LOG}" 2>/dev/null || true
  fi
}

mkdir -p "${LOG_DIR}"

fallback_home=""
for dir in "${HOME}"/.celestia-app-mainnet-*; do
  if [ -f "${dir}/config/genesis.json" ]; then
    fallback_home="${dir}"
    break
  fi
done

fetch_or_copy() {
  local url="$1"
  local dest="$2"
  local fallback="$3"
  if ! curl -fsSL ${CURL_OPTS} "${url}" -o "${dest}"; then
    if [ -n "${fallback}" ] && [ -f "${fallback}" ]; then
      cp "${fallback}" "${dest}"
      return 0
    fi
    return 1
  fi
}

log_info "Using home: ${HOME_DIR}"
log_info "Logs: ${LOG_DIR}"

"${APPD_BIN}" init treedb-mainnet --chain-id "${CHAIN_ID}" --home "${HOME_DIR}" >/dev/null 2>&1

fetch_or_copy \
  https://raw.githubusercontent.com/celestiaorg/networks/master/celestia/genesis.json \
  "${HOME_DIR}/config/genesis.json" \
  "${fallback_home}/config/genesis.json"
fetch_or_copy \
  https://raw.githubusercontent.com/celestiaorg/networks/master/celestia/peers.txt \
  "${HOME_DIR}/config/peers.txt" \
  "${fallback_home}/config/peers.txt"
fetch_or_copy \
  https://raw.githubusercontent.com/celestiaorg/networks/master/celestia/seeds.txt \
  "${HOME_DIR}/config/seeds.txt" \
  "${fallback_home}/config/seeds.txt"

SEEDS="$(grep -Ev '^\s*$' "${HOME_DIR}/config/seeds.txt" | paste -sd, -)"
PEERS="$(grep -Ev '^\s*$' "${HOME_DIR}/config/peers.txt" | paste -sd, -)"

normalize_peer_csv() {
  local raw="${1:-}"
  PEER_CSV_RAW="${raw}" python3 - <<'PY'
import os
import re

raw = os.environ.get("PEER_CSV_RAW", "")
seen = set()
out = []
for token in (part.strip() for part in raw.split(",")):
    if not token or "@" not in token:
        continue
    node_id, addr = token.split("@", 1)
    node_id = node_id.strip()
    addr = addr.strip()
    if not node_id or not addr:
        continue

    host = ""
    port = ""
    if addr.startswith("["):
        m = re.match(r"^\[([^\]]+)\]:(\d+)$", addr)
        if not m:
            continue
        host, port = m.group(1), m.group(2)
        normalized_addr = f"[{host}]:{port}"
    else:
        if ":" not in addr:
            continue
        host, port = addr.rsplit(":", 1)
        if not port.isdigit() or not host:
            continue
        if ":" in host:
            normalized_addr = f"[{host}]:{port}"
        else:
            normalized_addr = f"{host}:{port}"

    normalized = f"{node_id}@{normalized_addr}"
    if normalized not in seen:
        seen.add(normalized)
        out.append(normalized)

print(",".join(out))
PY
}

SEEDS="$(normalize_peer_csv "${SEEDS}")"
PEERS="$(normalize_peer_csv "${PEERS}")"

NET_INFO_JSON="$(curl -fsSL ${CURL_OPTS} "${RPC1}/net_info" 2>/dev/null || curl -fsSL ${CURL_OPTS} "${RPC2}/net_info" 2>/dev/null || true)"
if [ -n "${NET_INFO_JSON}" ]; then
  NET_INFO_PEERS="$(echo "${NET_INFO_JSON}" | jq -r '[(.result.peers // [])[] | .node_info.id + "@" + .remote_ip + ":" + (.node_info.listen_addr | split(":") | last)] | join(",")')"
  NET_INFO_PEERS="$(normalize_peer_csv "${NET_INFO_PEERS}")"
  if [ -n "${NET_INFO_PEERS}" ]; then
    PEERS="${NET_INFO_PEERS}"
  fi
fi

export HOME_DIR SEEDS PEERS P2P_LADDR RPC_LADDR PPROF_LADDR DB_BACKEND
python3 - <<'PY'
import os
import re
from pathlib import Path

cfg_path = Path(os.environ["HOME_DIR"]) / "config" / "config.toml"
data = cfg_path.read_text()
data, pprof_count = re.subn(
    r"(?m)^pprof_laddr\s*=.*$",
    f"pprof_laddr = \"{os.environ['PPROF_LADDR']}\"",
    data,
)
data, seeds_count = re.subn(
    r"(?m)^seeds\s*=.*$",
    f"seeds = \"{os.environ['SEEDS']}\"",
    data,
)
data, peers_count = re.subn(
    r"(?m)^persistent_peers\s*=.*$",
    f"persistent_peers = \"{os.environ['PEERS']}\"",
    data,
)
data, rpc_count = re.subn(
    r"(?m)^laddr\s*=\s*\"tcp://127.0.0.1:26657\"$",
    f"laddr = \"{os.environ['RPC_LADDR']}\"",
    data,
)
data, p2p_count = re.subn(
    r"(?m)^laddr\s*=\s*\"tcp://0.0.0.0:26656\"$",
    f"laddr = \"{os.environ['P2P_LADDR']}\"",
    data,
)
data, db_count = re.subn(
    r"(?m)^db_backend\s*=.*$",
    f"db_backend = \"{os.environ['DB_BACKEND']}\"",
    data,
)
if (
    pprof_count == 0
    or seeds_count == 0
    or peers_count == 0
    or rpc_count == 0
    or p2p_count == 0
    or db_count == 0
):
    raise SystemExit("Failed to update config.toml (ports/peers/seeds/pprof).")
cfg_path.write_text(data)
PY

export HOME_DIR APP_DB_BACKEND
python3 - <<'PY'
import os
import re
from pathlib import Path

app_path = Path(os.environ["HOME_DIR"]) / "config" / "app.toml"
data = app_path.read_text()
data, count = re.subn(
    r"(?m)^app-db-backend\s*=.*$",
    f"app-db-backend = \"{os.environ['APP_DB_BACKEND']}\"",
    data,
)
if count == 0:
    raise SystemExit("Failed to update app.toml (app-db-backend).")
app_path.write_text(data)
PY

LATEST="$(curl -fsSL ${CURL_OPTS} "${RPC1}/status" 2>/dev/null | jq -r .result.sync_info.latest_block_height || curl -fsSL ${CURL_OPTS} "${RPC2}/status" 2>/dev/null | jq -r .result.sync_info.latest_block_height)"
TRUST_HEIGHT=$((LATEST-2000))
TRUST_HASH="$(curl -fsSL ${CURL_OPTS} "${RPC1}/block?height=${TRUST_HEIGHT}" 2>/dev/null | jq -r .result.block_id.hash || curl -fsSL ${CURL_OPTS} "${RPC2}/block?height=${TRUST_HEIGHT}" 2>/dev/null | jq -r .result.block_id.hash)"

export HOME_DIR RPC1 RPC2 TRUST_HEIGHT TRUST_HASH
python3 - <<'PY'
import os
import re
from pathlib import Path

cfg_path = Path(os.environ["HOME_DIR"]) / "config" / "config.toml"
block = (
    "[statesync]\n"
    f"enable = true\n"
    f"rpc_servers = \"{os.environ['RPC1']},{os.environ['RPC2']}\"\n"
    f"trust_height = {os.environ['TRUST_HEIGHT']}\n"
    f"trust_hash = \"{os.environ['TRUST_HASH']}\"\n"
    "trust_period = \"168h\"\n\n"
)
data = cfg_path.read_text()
data, count = re.subn(r"(?ms)^\[statesync\][\s\S]*?(?=^\[blocksync\])", block, data, count=1)
if count == 0:
    raise SystemExit("Failed to update statesync config block.")
cfg_path.write_text(data)
PY


sed -e 's/max_open_connections = 3$/max_open_connections = 900/g' -i ${HOME_DIR}/config/config.toml 
sed -i "s/max_num_inbound_peers = .*/max_num_inbound_peers = 100/g" ${HOME_DIR}/config/config.toml
sed -i "s/max_num_outbound_peers = .*/max_num_outbound_peers = 150/g" ${HOME_DIR}/config/config.toml
sed -i "s/upnp = .*/upnp = true/g" ${HOME_DIR}/config/config.toml
sed -i "s/^external_address = .*/external_address = \\\"72.130.67.121:36656\\\"/g" ${HOME_DIR}/config/config.toml
sed -i "s/handshake_timeout = .*/handshake_timeout = \"20s\"/g" ${HOME_DIR}/config/config.toml
sed -i "s/dial_timeout = .*/dial_timeout = \"3s\"/g" ${HOME_DIR}/config/config.toml
sed -i "s/addr_book_strict = .*/addr_book_strict = true/g" ${HOME_DIR}/config/config.toml
sed -i "s/allow_duplicate_ip = .*/allow_duplicate_ip = false/g" ${HOME_DIR}/config/config.toml

START_EPOCH="$(date +%s)"
START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

safe_du_bytes() {
  local target="$1"
  if [ -e "${target}" ]; then
    if du -sb "${target}" >/dev/null 2>&1; then
      du -sb "${target}" 2>/dev/null | awk '{print $1}'
    else
      du -sk "${target}" 2>/dev/null | awk '{print $1 * 1024}'
    fi
  else
    echo 0
  fi
}

START_HOME_BYTES="$(safe_du_bytes "${HOME_DIR}")"
START_DATA_BYTES="$(safe_du_bytes "${HOME_DIR}/data")"
START_APP_BYTES="$(safe_du_bytes "${HOME_DIR}/data/app")"
START_BLOCKSTORE_BYTES="$(safe_du_bytes "${HOME_DIR}/data/blockstore")"
MAX_RSS_KB=0
MAX_APP_BYTES=0
MAX_INDEX_BYTES=0
MAX_HWM_KB=0
{
  echo "start_utc=${START_TS}"
  echo "rpc1=${RPC1}"
  echo "rpc2=${RPC2}"
  echo "trust_height=${TRUST_HEIGHT}"
  echo "trust_hash=${TRUST_HASH}"
  echo "home=${HOME_DIR}"
  echo "db_backend=${DB_BACKEND}"
  echo "app_db_backend=${APP_DB_BACKEND}"
  echo "start_home_bytes=${START_HOME_BYTES}"
  echo "start_data_bytes=${START_DATA_BYTES}"
  echo "start_app_bytes=${START_APP_BYTES}"
  echo "start_blockstore_bytes=${START_BLOCKSTORE_BYTES}"
} >> "${TIME_LOG}"

NODE_PID=""
cleanup_node() {
  if [ -n "${NODE_PID:-}" ] && kill -0 "${NODE_PID}" >/dev/null 2>&1; then
    kill -INT "${NODE_PID}" >/dev/null 2>&1 || true
    wait "${NODE_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup_node EXIT

fail_and_exit() {
  local reason="$1"
  log_error "${reason}"
  print_recent_log_excerpt
  exit 1
}

has_recent_node_error() {
  if [ ! -f "${NODE_LOG}" ]; then
    return 1
  fi
  rg -n -i -e "${ERROR_PATTERNS}" "${NODE_LOG}" >/dev/null 2>&1
}

print_recent_error_matches() {
  if [ ! -f "${NODE_LOG}" ]; then
    return
  fi
  rg -n -i -e "${ERROR_PATTERNS}" "${NODE_LOG}" | tail -n 10 || true
}

extract_sync_marker() {
  if [ ! -f "${NODE_LOG}" ]; then
    return
  fi
  tail -n "${LOG_ERROR_SCAN_LINES}" "${NODE_LOG}" \
    | grep -E "Applied snapshot chunk to ABCI app|Fetching snapshot chunk|executed block" \
    | tail -n 1 \
    | sed -r 's/\x1B\[[0-9;]*[mK]//g' || true
}

log_info "Starting node..."
"${APPD_BIN}" start --home "${HOME_DIR}" --force-no-bbr >"${NODE_LOG}" 2>&1 &
NODE_PID=$!

log_info "Waiting for local RPC (${LOCAL_RPC})..."
RPC_WAIT_START="$(date +%s)"
LAST_WAIT_REPORT=0
until curl -fsSL "${LOCAL_RPC}/status" >/dev/null 2>&1; do
  if ! kill -0 "${NODE_PID}" >/dev/null 2>&1; then
    fail_and_exit "Node exited before local RPC became ready."
  fi
  NOW_EPOCH="$(date +%s)"
  WAIT_ELAPSED=$((NOW_EPOCH-RPC_WAIT_START))
  if [ "${WAIT_ELAPSED}" -ge "${WAIT_RPC_TIMEOUT_SECONDS}" ]; then
    fail_and_exit "Local RPC was not ready after ${WAIT_RPC_TIMEOUT_SECONDS}s."
  fi
  if [ "${LAST_WAIT_REPORT}" -eq 0 ] || [ $((NOW_EPOCH - LAST_WAIT_REPORT)) -ge 20 ]; then
    log_info "Still waiting for local RPC (${WAIT_ELAPSED}s elapsed)..."
    LAST_WAIT_REPORT="${NOW_EPOCH}"
  fi
  sleep 2
done
log_info "Local RPC is ready."

LOCAL_HEIGHT=0
REMOTE_HEIGHT=0
CATCHING_UP=true
PREV_LOCAL_HEIGHT=-1
START_LOCAL_HEIGHT=0
PROGRESS_EPOCH="$(date +%s)"
LAST_STUCK_REPORT_EPOCH=0
LAST_SYNC_MARKER=""
LOCAL_RPC_FAILURES=0
SYNC_COMPLETE=0

log_info "Monitoring sync progress..."
while true; do
  if ! kill -0 "${NODE_PID}" >/dev/null 2>&1; then
    fail_and_exit "Node process exited while syncing."
  fi

  if has_recent_node_error; then
    log_error "Detected fatal node error in recent logs:"
    print_recent_error_matches
    fail_and_exit "Sync aborted by node error."
  fi

  LOCAL_STATUS="$(curl -fsSL "${LOCAL_RPC}/status" 2>/dev/null || true)"
  if [ -z "${LOCAL_STATUS}" ]; then
    LOCAL_RPC_FAILURES=$((LOCAL_RPC_FAILURES + 1))
    if [ "${LOCAL_RPC_FAILURES}" -ge "${MAX_LOCAL_RPC_FAILURES}" ]; then
      fail_and_exit "Local RPC unavailable for ${LOCAL_RPC_FAILURES} consecutive checks."
    fi
    log_warn "Local RPC unavailable (${LOCAL_RPC_FAILURES}/${MAX_LOCAL_RPC_FAILURES}); retrying..."
    sleep "${POLL_INTERVAL_SECONDS}"
    continue
  fi
  LOCAL_RPC_FAILURES=0

  LOCAL_HEIGHT="$(echo "${LOCAL_STATUS}" | jq -er '.result.sync_info.latest_block_height | tonumber' 2>/dev/null || true)"
  CATCHING_UP="$(echo "${LOCAL_STATUS}" | jq -er '.result.sync_info.catching_up | tostring' 2>/dev/null || true)"
  if [ -z "${LOCAL_HEIGHT}" ] || [ -z "${CATCHING_UP}" ]; then
    fail_and_exit "Failed to parse local RPC sync status."
  fi
  if [ "${PREV_LOCAL_HEIGHT}" -lt 0 ]; then
    PREV_LOCAL_HEIGHT="${LOCAL_HEIGHT}"
    START_LOCAL_HEIGHT="${LOCAL_HEIGHT}"
    PROGRESS_EPOCH="$(date +%s)"
  fi

  REMOTE_STATUS="$(curl -fsSL ${CURL_OPTS} "${RPC1}/status" 2>/dev/null || curl -fsSL ${CURL_OPTS} "${RPC2}/status" 2>/dev/null || true)"
  if [ -z "${REMOTE_STATUS}" ]; then
    log_warn "Remote RPC unavailable; retrying..."
    sleep "${POLL_INTERVAL_SECONDS}"
    continue
  fi
  REMOTE_HEIGHT="$(echo "${REMOTE_STATUS}" | jq -er '.result.sync_info.latest_block_height | tonumber' 2>/dev/null || true)"
  if [ -z "${REMOTE_HEIGHT}" ]; then
    log_warn "Failed to parse remote RPC height; retrying..."
    sleep "${POLL_INTERVAL_SECONDS}"
    continue
  fi
  REMOTE_TARGET=$((REMOTE_HEIGHT - 2))
  if [ "${REMOTE_TARGET}" -lt 0 ]; then
    REMOTE_TARGET=0
  fi

  NOW_EPOCH="$(date +%s)"

  RSS_KB=""
  if command -v ps >/dev/null 2>&1; then
    RSS_KB="$(ps -o rss= -p "${NODE_PID}" 2>/dev/null | awk '{print $1}' || true)"
  fi
  if [ -z "${RSS_KB}" ] && [ -r "/proc/${NODE_PID}/status" ]; then
    RSS_KB="$(awk '/VmRSS:/ {print $2}' "/proc/${NODE_PID}/status" 2>/dev/null || true)"
  fi
  if [ -r "/proc/${NODE_PID}/status" ]; then
    HWM_KB="$(awk '/VmHWM:/ {print $2}' "/proc/${NODE_PID}/status" 2>/dev/null || true)"
  else
    HWM_KB=""
  fi
  if [ -n "${RSS_KB}" ] && [ "${RSS_KB}" -gt "${MAX_RSS_KB}" ]; then
    MAX_RSS_KB="${RSS_KB}"
  fi
  if [ -n "${HWM_KB}" ] && [ "${HWM_KB}" -gt "${MAX_HWM_KB}" ]; then
    MAX_HWM_KB="${HWM_KB}"
  fi

  LAG=$((REMOTE_HEIGHT - LOCAL_HEIGHT))
  if [ "${LAG}" -lt 0 ]; then
    LAG=0
  fi

  if [ "${LOCAL_HEIGHT}" -gt "${PREV_LOCAL_HEIGHT}" ]; then
    DELTA=$((LOCAL_HEIGHT - PREV_LOCAL_HEIGHT))
    TOTAL_DELTA=$((LOCAL_HEIGHT - START_LOCAL_HEIGHT))
    ELAPSED=$((NOW_EPOCH - START_EPOCH))
    if [ "${ELAPSED}" -le 0 ]; then
      ELAPSED=1
    fi
    RATE="$(awk "BEGIN { printf \"%.2f\", ${TOTAL_DELTA}/${ELAPSED} }")"
    log_info "Progress: local=${LOCAL_HEIGHT} remote=${REMOTE_HEIGHT} lag=${LAG} catching_up=${CATCHING_UP} (+${DELTA}, avg=${RATE} blk/s, rss=${RSS_KB:-n/a}k)"
    PREV_LOCAL_HEIGHT="${LOCAL_HEIGHT}"
    PROGRESS_EPOCH="${NOW_EPOCH}"
    LAST_STUCK_REPORT_EPOCH=0
  fi

  SYNC_MARKER="$(extract_sync_marker)"
  if [ -n "${SYNC_MARKER}" ] && [ "${SYNC_MARKER}" != "${LAST_SYNC_MARKER}" ]; then
    LAST_SYNC_MARKER="${SYNC_MARKER}"
    PROGRESS_EPOCH="${NOW_EPOCH}"
    if [[ "${SYNC_MARKER}" =~ chunk=([0-9]+) ]]; then
      CHUNK_NUM="${BASH_REMATCH[1]}"
      CHUNK_TOTAL="?"
      SNAPSHOT_HEIGHT="?"
      if [[ "${SYNC_MARKER}" =~ total=([0-9]+) ]]; then
        CHUNK_TOTAL="${BASH_REMATCH[1]}"
      fi
      if [[ "${SYNC_MARKER}" =~ height=([0-9]+) ]]; then
        SNAPSHOT_HEIGHT="${BASH_REMATCH[1]}"
      fi
      log_info "State-sync activity: snapshot_height=${SNAPSHOT_HEIGHT} chunk=${CHUNK_NUM}/${CHUNK_TOTAL} local=${LOCAL_HEIGHT}"
    fi
  fi

  STALLED_FOR=$((NOW_EPOCH - PROGRESS_EPOCH))
  if [ "${STALLED_FOR}" -ge "${NO_PROGRESS_WARN_SECONDS}" ]; then
    if [ "${LAST_STUCK_REPORT_EPOCH}" -eq 0 ] || [ $((NOW_EPOCH - LAST_STUCK_REPORT_EPOCH)) -ge "${STUCK_REPORT_INTERVAL_SECONDS}" ]; then
      log_warn "Stuck: no sync progress for ${STALLED_FOR}s (local=${LOCAL_HEIGHT}, remote=${REMOTE_HEIGHT}, lag=${LAG}, catching_up=${CATCHING_UP})"
      LAST_STUCK_REPORT_EPOCH="${NOW_EPOCH}"
    fi
  fi
  if [ "${STALLED_FOR}" -ge "${NO_PROGRESS_FAIL_SECONDS}" ]; then
    fail_and_exit "No sync progress for ${STALLED_FOR}s (treating as stuck)."
  fi

  if [ "${CATCHING_UP}" = "false" ] && [ "${LOCAL_HEIGHT}" -ge "${REMOTE_TARGET}" ]; then
    SYNC_COMPLETE=1
    break
  fi
  sleep "${POLL_INTERVAL_SECONDS}"
done

if [ "${SYNC_COMPLETE}" -ne 1 ]; then
  fail_and_exit "Sync monitor exited without success."
fi

END_EPOCH="$(date +%s)"
END_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DURATION=$((END_EPOCH-START_EPOCH))
END_HOME_BYTES="$(safe_du_bytes "${HOME_DIR}")"
END_DATA_BYTES="$(safe_du_bytes "${HOME_DIR}/data")"
END_APP_BYTES="$(safe_du_bytes "${HOME_DIR}/data/app")"
END_BLOCKSTORE_BYTES="$(safe_du_bytes "${HOME_DIR}/data/blockstore")"

{
  echo "end_utc=${END_TS}"
  echo "duration_seconds=${DURATION}"
  echo "final_local_height=${LOCAL_HEIGHT}"
  echo "final_remote_height=${REMOTE_HEIGHT}"
  echo "max_rss_kb=${MAX_RSS_KB}"
  echo "max_hwm_kb=${MAX_HWM_KB}"
  echo "end_home_bytes=${END_HOME_BYTES}"
  echo "end_data_bytes=${END_DATA_BYTES}"
  echo "end_app_bytes=${END_APP_BYTES}"
  echo "end_blockstore_bytes=${END_BLOCKSTORE_BYTES}"
  echo "---"
} >> "${TIME_LOG}"

log_info "Sync complete: local=${LOCAL_HEIGHT} remote=${REMOTE_HEIGHT}. Stopping node..."
SHUTDOWN_START_EPOCH="$(date +%s)"
kill -INT "${NODE_PID}" >/dev/null 2>&1 || true
wait "${NODE_PID}" >/dev/null 2>&1 || true
SHUTDOWN_END_EPOCH="$(date +%s)"
SHUTDOWN_DURATION=$((SHUTDOWN_END_EPOCH-SHUTDOWN_START_EPOCH))
{
  echo "shutdown_seconds=${SHUTDOWN_DURATION}"
} >> "${TIME_LOG}"


APP_DB="${HOME_DIR}/data/application.db"
BREAKDOWN_LOG="${LOG_DIR}/disk-breakdown.log"
if [ -d "${APP_DB}" ]; then
  {
    echo "app_db=${APP_DB}"
    echo "du_human:"
    du -sh "${APP_DB}" "${APP_DB}"/* 2>/dev/null || true
    echo "du_bytes:"
    if du -sb "${APP_DB}" >/dev/null 2>&1; then
      du -sb "${APP_DB}" "${APP_DB}"/* 2>/dev/null || true
    else
      du -sk "${APP_DB}" "${APP_DB}"/* 2>/dev/null | awk '{print $1 * 1024 " " $2}'
    fi
    echo "top_files_bytes:"
    find "${APP_DB}" -type f -printf "%s %p\n" 2>/dev/null | sort -nr | sed -n '1,20p'
  } > "${BREAKDOWN_LOG}"
  log_info "Disk breakdown log: ${BREAKDOWN_LOG}"
fi

trap - EXIT
log_info "Run complete. Time log: ${TIME_LOG}"
