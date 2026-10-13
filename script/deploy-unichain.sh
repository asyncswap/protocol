#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/.env.deploy"
OWNER="0xb1F0982E02f9F71E60512fd47471d76610CcB556"
CHAIN_KEY="unichain"
CHAIN_CONFIG="$ROOT_DIR/script/config/chains.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing $CONFIG_FILE. Copy .env.deploy.example and set RPC_URL and DEPLOYER_ACCOUNT." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3 is required to read the per-chain deployment config." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

: "${RPC_URL:?Set RPC_URL in .env.deploy}"
chain_config_values="$(python3 - "$CHAIN_CONFIG" "$CHAIN_KEY" <<'PY'
import json
import re
import sys

config_path, chain_key = sys.argv[1:]
with open(config_path, encoding="utf-8") as config_file:
    config = json.load(config_file)
chain = config.get("chains", {}).get(chain_key)
if chain is None:
    raise SystemExit(f"Chain '{chain_key}' is missing from {config_path}.")
if chain.get("deployment", {}).get("status") != "prepared":
    raise SystemExit(f"{chain['name']} is not marked prepared for deployment.")
address = chain.get("contracts", {}).get("usdc")
if not isinstance(address, str) or not re.fullmatch(r"0x[0-9a-fA-F]{40}", address):
    raise SystemExit(f"{chain['name']} has no verified USDC address in {config_path}.")
print(chain["chainId"], address)
PY
 )"
read -r expected_chain_id DEPLOY_NUMERAIRE_ADDRESS <<< "$chain_config_values"
if [[ -z "${expected_chain_id:-}" || -z "${DEPLOY_NUMERAIRE_ADDRESS:-}" ]]; then
  echo "Refusing deployment: incomplete chain config for '$CHAIN_KEY'." >&2
  exit 1
fi
export DEPLOY_NUMERAIRE_ADDRESS

mode="${1:-dry-run}"
if [[ "$mode" != "dry-run" && "$mode" != "broadcast" ]]; then
  echo "Usage: $0 [dry-run|broadcast]" >&2
  exit 2
fi

if [[ "$mode" == "broadcast" ]] && ! command -v python3 >/dev/null 2>&1; then
  echo "Refusing deployment: python3 is required to sync confirmed receipts into the deployment registry." >&2
  exit 1
fi

chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$chain_id" != "$expected_chain_id" ]]; then
  echo "Refusing deployment: RPC returned chain ID $chain_id, expected configured chain $expected_chain_id." >&2
  exit 1
fi

usdc_code="$(cast code "$DEPLOY_NUMERAIRE_ADDRESS" --rpc-url "$RPC_URL")"
if [[ "$usdc_code" == "0x" || -z "$usdc_code" ]]; then
  echo "Refusing deployment: configured USDC $DEPLOY_NUMERAIRE_ADDRESS has no contract code on this RPC." >&2
  exit 1
fi

forge_args=(script "$ROOT_DIR/script/01_DeployHook.s.sol" --rpc-url "$RPC_URL" --ffi --sender "$OWNER")
if [[ "$mode" == "broadcast" ]]; then
  : "${DEPLOYER_ACCOUNT:?Set DEPLOYER_ACCOUNT to a Foundry keystore for $OWNER}"
  forge_args+=(--broadcast --account "$DEPLOYER_ACCOUNT")
  echo "Broadcasting AsyncSwap + Router on Unichain (130) from $OWNER."
else
  echo "Dry-run only: no transactions will be broadcast."
fi

forge "${forge_args[@]}"

if [[ "$mode" == "broadcast" ]]; then
  python3 "$ROOT_DIR/script/sync-deployment-record.py" \
    --chain-id "$chain_id" \
    --registry "$ROOT_DIR/deployments/$chain_id/$chain_id.json" \
    --broadcast "$ROOT_DIR/broadcast/01_DeployHook.s.sol/$chain_id/run-latest.json"
fi
