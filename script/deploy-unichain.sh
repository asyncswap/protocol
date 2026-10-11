#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/.env.deploy"
OWNER="0xb1F0982E02f9F71E60512fd47471d76610CcB556"
EXPECTED_USDC="0x078D782b760474a361dDA0AF3839290b0EF57AD6"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing $CONFIG_FILE. Copy .env.deploy.example and set RPC_URL and DEPLOYER_ACCOUNT." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

: "${RPC_URL:?Set RPC_URL in .env.deploy}"
: "${USDC_ADDRESS:?Set USDC_ADDRESS in .env.deploy}"

mode="${1:-dry-run}"
if [[ "$mode" != "dry-run" && "$mode" != "broadcast" ]]; then
  echo "Usage: $0 [dry-run|broadcast]" >&2
  exit 2
fi

chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$chain_id" != "130" ]]; then
  echo "Refusing deployment: RPC returned chain ID $chain_id, expected Unichain 130." >&2
  exit 1
fi

if [[ "${USDC_ADDRESS,,}" != "${EXPECTED_USDC,,}" ]]; then
  echo "Refusing deployment: USDC_ADDRESS must be the verified Unichain USDC address $EXPECTED_USDC." >&2
  exit 1
fi

usdc_code="$(cast code "$USDC_ADDRESS" --rpc-url "$RPC_URL")"
if [[ "$usdc_code" == "0x" || -z "$usdc_code" ]]; then
  echo "Refusing deployment: USDC_ADDRESS has no contract code on this RPC." >&2
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
