#!/usr/bin/env bash
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for this script."
  exit 1
fi

APPD_BIN="${CELESTIA_APPD_BIN:-celestia-appd}"
if ! command -v "${APPD_BIN}" >/dev/null 2>&1; then
  echo "celestia-appd not found; run 'make install-standalone' or set CELESTIA_APPD_BIN."
  exit 1
fi

CHAIN_ID="mocha-4"
RPC1="https://rpc-mocha.pops.one"
RPC2="https://celestia-testnet-rpc.itrocket.net"
LOCAL_RPC="http://127.0.0.1:27657"
P2P_LADDR="tcp://0.0.0.0:27656"
RPC_LADDR="tcp://127.0.0.1:27657"
PPROF_LADDR="localhost:6061"

TS="$(date +%Y%m%d%H%M%S)"
HOME_DIR="${HOME}/.celestia-app-mocha-treedb-${TS}"
LOG_DIR="${HOME_DIR}/sync"
NODE_LOG="${LOG_DIR}/node.log"
TIME_LOG="${LOG_DIR}/sync-time.log"

mkdir -p "${LOG_DIR}"

echo "Using home: ${HOME_DIR}"
echo "Logs: ${LOG_DIR}"

"${APPD_BIN}" init treedb-mocha --chain-id "${CHAIN_ID}" --home "${HOME_DIR}" >/dev/null

curl -fsSL https://raw.githubusercontent.com/celestiaorg/networks/master/mocha-4/genesis.json \
  -o "${HOME_DIR}/config/genesis.json"
curl -fsSL https://raw.githubusercontent.com/celestiaorg/networks/master/mocha-4/peers.txt \
  -o "${HOME_DIR}/config/peers.txt"
curl -fsSL https://raw.githubusercontent.com/celestiaorg/networks/master/mocha-4/seeds.txt \
  -o "${HOME_DIR}/config/seeds.txt"

SEEDS="$(grep -Ev '^\s*$|aviaone' "${HOME_DIR}/config/seeds.txt" | paste -sd, -)"
PEERS="$(grep -Ev '^\s*$' "${HOME_DIR}/config/peers.txt" | paste -sd, -)"

NET_INFO_JSON="$(curl -fsSL "${RPC1}/net_info" 2>/dev/null || curl -fsSL "${RPC2}/net_info" 2>/dev/null || true)"
if [ -n "${NET_INFO_JSON}" ]; then
  NET_INFO_PEERS="$(echo "${NET_INFO_JSON}" | jq -r '.result.peers[] | .node_info.id + "@" + .remote_ip + ":" + (.node_info.listen_addr | split(":") | last)' | head -n 20 | paste -sd, -)"
  if [ -n "${NET_INFO_PEERS}" ]; then
    PEERS="${NET_INFO_PEERS}"
  fi
fi

export HOME_DIR SEEDS PEERS P2P_LADDR RPC_LADDR PPROF_LADDR
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
if pprof_count == 0 or seeds_count == 0 or peers_count == 0 or rpc_count == 0 or p2p_count == 0:
    raise SystemExit("Failed to update config.toml (ports/peers/seeds/pprof).")
cfg_path.write_text(data)
PY
perl -pi -e 's/^db_backend.*/db_backend = "treedb"/' "${HOME_DIR}/config/config.toml"
perl -pi -e 's/^app-db-backend.*/app-db-backend = "treedb"/' "${HOME_DIR}/config/app.toml"

LATEST="$(curl -fsSL "${RPC1}/status" 2>/dev/null | jq -r .result.sync_info.latest_block_height || curl -fsSL "${RPC2}/status" 2>/dev/null | jq -r .result.sync_info.latest_block_height)"
TRUST_HEIGHT=$((LATEST-2000))
TRUST_HASH="$(curl -fsSL "${RPC1}/block?height=${TRUST_HEIGHT}" 2>/dev/null | jq -r .result.block_id.hash || curl -fsSL "${RPC2}/block?height=${TRUST_HEIGHT}" 2>/dev/null | jq -r .result.block_id.hash)"

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
data, count = re.subn(r"\[statesync\][\s\S]*?(?=\n\[blocksync\])", block, data, count=1)
if count == 0:
    raise SystemExit("Failed to update statesync config block.")
cfg_path.write_text(data)
PY

START_EPOCH="$(date +%s)"
START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  echo "start_utc=${START_TS}"
  echo "rpc1=${RPC1}"
  echo "rpc2=${RPC2}"
  echo "trust_height=${TRUST_HEIGHT}"
  echo "trust_hash=${TRUST_HASH}"
  echo "home=${HOME_DIR}"
} >> "${TIME_LOG}"

echo "Starting node..."
"${APPD_BIN}" start --home "${HOME_DIR}" --force-no-bbr >"${NODE_LOG}" 2>&1 &
NODE_PID=$!

echo "Waiting for local RPC..."
until curl -fsSL "${LOCAL_RPC}/status" >/dev/null 2>&1; do
  sleep 2
done

echo "Monitoring sync..."
while true; do
  LOCAL_STATUS="$(curl -fsSL "${LOCAL_RPC}/status" 2>/dev/null || true)"
  if [ -z "${LOCAL_STATUS}" ]; then
    echo "local RPC unavailable; stopping."
    break
  fi
  LOCAL_HEIGHT="$(echo "${LOCAL_STATUS}" | jq -r .result.sync_info.latest_block_height)"
  CATCHING_UP="$(echo "${LOCAL_STATUS}" | jq -r .result.sync_info.catching_up)"

  REMOTE_STATUS="$(curl -fsSL "${RPC1}/status" 2>/dev/null || curl -fsSL "${RPC2}/status" 2>/dev/null || true)"
  if [ -z "${REMOTE_STATUS}" ]; then
    echo "remote RPC unavailable; retrying."
    sleep 10
    continue
  fi
  REMOTE_HEIGHT="$(echo "${REMOTE_STATUS}" | jq -r .result.sync_info.latest_block_height)"
  REMOTE_TARGET=$((REMOTE_HEIGHT-2))
  if [ "${REMOTE_TARGET}" -lt 0 ]; then
    REMOTE_TARGET=0
  fi

  echo "local=${LOCAL_HEIGHT} catching_up=${CATCHING_UP} remote=${REMOTE_HEIGHT}"

  if [ "${CATCHING_UP}" = "false" ] && [ "${LOCAL_HEIGHT}" -ge "${REMOTE_TARGET}" ]; then
    break
  fi
  sleep 10
done

END_EPOCH="$(date +%s)"
END_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DURATION=$((END_EPOCH-START_EPOCH))

{
  echo "end_utc=${END_TS}"
  echo "duration_seconds=${DURATION}"
  echo "final_local_height=${LOCAL_HEIGHT}"
  echo "final_remote_height=${REMOTE_HEIGHT}"
  echo "---"
} >> "${TIME_LOG}"

echo "Caught up. Stopping node..."
kill -INT "${NODE_PID}" >/dev/null 2>&1 || true
wait "${NODE_PID}" >/dev/null 2>&1 || true

echo "Sync complete. Time log: ${TIME_LOG}"
