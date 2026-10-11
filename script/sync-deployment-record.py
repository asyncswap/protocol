#!/usr/bin/env python3
"""Copy confirmed Foundry deployment receipts into the per-chain registry."""

import argparse
import json
import os
import tempfile
from pathlib import Path


def parse_quantity(value):
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return int(value, 16) if value.startswith("0x") else int(value)
    raise ValueError(f"invalid JSON-RPC quantity: {value!r}")


def sync(registry_path: Path, broadcast_path: Path, chain_id: int):
    registry = json.loads(registry_path.read_text())
    run = json.loads(broadcast_path.read_text())

    if parse_quantity(run.get("chain", run.get("chainId"))) != chain_id:
        raise ValueError("Foundry broadcast chain ID does not match requested chain")
    if parse_quantity(registry["chainId"]) != chain_id:
        raise ValueError("deployment registry chain ID does not match requested chain")

    receipts_by_address = {}
    for receipt in run.get("receipts", []):
        address = receipt.get("contractAddress")
        tx_hash = receipt.get("transactionHash")
        status = receipt.get("status")
        if not address or not tx_hash:
            continue
        if status is not None and parse_quantity(status) != 1:
            continue
        receipts_by_address[address.lower()] = {
            "txHash": tx_hash,
            "startBlock": parse_quantity(receipt["blockNumber"]),
        }

    contracts = registry["contracts"]
    synced = []
    for name in ("AsyncSwap", "Router"):
        entry = contracts.get(name)
        if not entry:
            raise ValueError(f"deployment registry has no {name} entry")
        address = entry["address"].lower()
        receipt = receipts_by_address.get(address)
        if receipt is None:
            raise ValueError(f"no successful Foundry receipt found for {name} at {address}")
        entry.update(receipt)
        synced.append(name)

    # FeeVault is created by the AsyncSwap constructor, so its deployment
    # transaction and block are the hook's transaction and block.
    if "FeeVault" in contracts:
        contracts["FeeVault"].update(
            {
                "txHash": contracts["AsyncSwap"]["txHash"],
                "startBlock": contracts["AsyncSwap"]["startBlock"],
            }
        )
        synced.append("FeeVault")

    if run.get("timestamp") is not None:
        timestamp = parse_quantity(run["timestamp"])
        registry["updatedAt"] = timestamp // 1000 if timestamp >= 1_000_000_000_000 else timestamp

    payload = json.dumps(registry, indent=2) + "\n"
    fd, temp_name = tempfile.mkstemp(prefix=f".{registry_path.name}.", dir=registry_path.parent)
    try:
        with os.fdopen(fd, "w") as temp_file:
            temp_file.write(payload)
            temp_file.flush()
            os.fsync(temp_file.fileno())
        os.replace(temp_name, registry_path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)

    return synced


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chain-id", type=int, required=True)
    parser.add_argument("--registry", type=Path, required=True)
    parser.add_argument("--broadcast", type=Path, required=True)
    args = parser.parse_args()

    synced = sync(args.registry, args.broadcast, args.chain_id)
    print(f"Updated receipt hashes and blocks for: {', '.join(synced)}")


if __name__ == "__main__":
    main()
