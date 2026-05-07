// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UniswapAddresses} from "./config/UniswapAddresses.sol";
import {FFIHelper} from "./FFIHelper.sol";
import {console} from "forge-std/Script.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/// @notice Deploys (or records canonical) PoolManager and persists to the deployments registry.
contract DeployPoolManager is FFIHelper {
    IPoolManager manager;

    function run() public {
        if (UniswapAddresses.hasCanonicalPoolManager(block.chainid)) {
            address canonical = UniswapAddresses.poolManager(block.chainid);
            manager = IPoolManager(canonical);
            _upsertEntry(
                block.chainid,
                Entry({
                    name: "PoolManager",
                    addr: canonical,
                    startBlock: UniswapAddresses.poolManagerStartBlock(block.chainid),
                    txHash: bytes32(0)
                })
            );
            console.log("PoolManager (canonical):", canonical);
            return;
        }

        vm.startBroadcast();
        manager = new PoolManager(OWNER);
        vm.stopBroadcast();

        _upsertEntry(
            block.chainid,
            Entry({name: "PoolManager", addr: address(manager), startBlock: block.number, txHash: bytes32(0)})
        );
        console.log("PoolManager deployed:", address(manager));
    }
}
