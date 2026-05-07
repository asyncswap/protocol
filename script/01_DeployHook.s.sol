// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FFIHelper} from "./FFIHelper.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

/// @notice Deploys the AsyncSwap hook (with the required permission flags + 0x91 prefix) and the
///         Router, then records both into the deployments registry. Salt mining is offline via FFI
///         to `script/mine-hook-salt.ts`.
contract DeployHookScript is FFIHelper {
    IPoolManager manager;
    AsyncSwap public hook;
    Router router;

    /// @dev Top-byte prefix used to visually identify our hook (0x91...).
    uint160 internal constant HOOK_PREFIX = uint160(0x91) << 152;
    uint160 internal constant HOOK_PREFIX_MASK = uint160(0xFF) << 152;

    function setUp() public {
        manager = IPoolManager(_getDeployedPoolManager());
    }

    function run() public {
        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory creationCode = type(AsyncSwap).creationCode;
        bytes memory constructorArgs = abi.encode(address(manager));
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));

        bytes32 salt = _readSaltEnv();
        if (salt == bytes32(0)) {
            salt = _mineSaltViaFfi(initCodeHash);
        }

        address predicted = _computeCreate2Address(0x4e59b44847b379578588920cA78FbF26c0B4956C, salt, initCodeHash);
        require((uint160(predicted) & Hooks.ALL_HOOK_MASK) == hookFlags, "salt does not produce required hook flags");
        require((uint160(predicted) & HOOK_PREFIX_MASK) == HOOK_PREFIX, "salt does not produce required 0x91 prefix");

        console.log("hook salt:");
        console.logBytes32(salt);
        console.log("predicted hook address:", predicted);

        vm.startBroadcast(OWNER);
        hook = new AsyncSwap{salt: salt}(manager);
        require(address(hook) == predicted, "deployed hook address mismatch");
        router = new Router(manager, hook);
        vm.stopBroadcast();

        _recordDeployments();
    }

    function _recordDeployments() internal {
        uint256 deployBlock = block.number;
        _upsertEntry(
            block.chainid,
            Entry({name: "PoolManager", addr: address(manager), startBlock: deployBlock, txHash: bytes32(0)})
        );
        _upsertEntry(
            block.chainid, Entry({name: "AsyncSwap", addr: address(hook), startBlock: deployBlock, txHash: bytes32(0)})
        );
        _upsertEntry(
            block.chainid, Entry({name: "Router", addr: address(router), startBlock: deployBlock, txHash: bytes32(0)})
        );
    }

    /// @dev Calls `bun run script/mine-hook-salt.ts --ffi --init-code-hash <hash>`.
    function _mineSaltViaFfi(bytes32 initCodeHash) internal returns (bytes32) {
        string[] memory cmd = new string[](6);
        cmd[0] = "bun";
        cmd[1] = "run";
        cmd[2] = "script/mine-hook-salt.ts";
        cmd[3] = "--ffi";
        cmd[4] = "--init-code-hash";
        cmd[5] = vm.toString(initCodeHash);

        bytes memory out = vm.ffi(cmd);
        require(out.length == 32, "miner returned unexpected output length");
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes32(out);
    }

    function _readSaltEnv() internal view returns (bytes32) {
        try vm.envBytes32("HOOK_SALT") returns (bytes32 s) {
            return s;
        } catch {
            return bytes32(0);
        }
    }

    function _computeCreate2Address(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, initCodeHash)))));
    }
}
