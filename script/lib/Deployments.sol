// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";

/// @title DeploymentsRegistry
/// @notice Per-chain deployment registry written by deploy scripts and read by the indexer.
///         Path: `deployments/<chainId>.json`. See contracts/script/lib/Deployments.sol for shape.
abstract contract DeploymentsRegistry is CommonBase {
    struct Entry {
        string name;
        address addr;
        uint256 startBlock;
        bytes32 txHash;
    }

    function _registryPath(uint256 chainId) internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments/", vm.toString(chainId), ".json");
    }

    function _historyPath(uint256 chainId, uint256 timestamp) internal view returns (string memory) {
        return string.concat(
            vm.projectRoot(), "/deployments/history/", vm.toString(chainId), "-", vm.toString(timestamp), ".json"
        );
    }

    function _registryExists(uint256 chainId) internal view returns (bool) {
        try vm.readFile(_registryPath(chainId)) returns (string memory) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Upsert a single entry, preserving every other entry in the file.
    function _upsertEntry(uint256 chainId, Entry memory entry) internal {
        require(bytes(entry.name).length > 0, "DeploymentsRegistry: empty entry name");
        require(entry.addr != address(0), "DeploymentsRegistry: zero address");

        _ensureRegistry(chainId);
        _snapshotHistory(chainId);

        string memory objKey = string.concat("entry_", entry.name);
        vm.serializeAddress(objKey, "address", entry.addr);
        vm.serializeUint(objKey, "startBlock", entry.startBlock);
        string memory entryJson = vm.serializeBytes32(objKey, "txHash", entry.txHash);

        string memory path = _registryPath(chainId);
        vm.writeJson(entryJson, path, string.concat(".contracts.", entry.name));
        vm.writeJson(vm.toString(block.timestamp), path, ".updatedAt");
    }

    function _ensureRegistry(uint256 chainId) internal {
        if (_registryExists(chainId)) return;

        string memory rootKey = "deployments_root_init";
        vm.serializeUint(rootKey, "chainId", chainId);
        vm.serializeUint(rootKey, "updatedAt", block.timestamp);
        string memory rootJson = vm.serializeString(rootKey, "contracts", "{}");
        vm.writeJson(rootJson, _registryPath(chainId));
    }

    function _snapshotHistory(uint256 chainId) internal {
        if (!_registryExists(chainId)) return;
        string memory current = vm.readFile(_registryPath(chainId));
        vm.writeFile(_historyPath(chainId, block.timestamp), current);
    }

    function _readEntry(uint256 chainId, string memory name) internal view returns (Entry memory e) {
        e.name = name;
        if (!_registryExists(chainId)) return e;

        string memory json = vm.readFile(_registryPath(chainId));
        string memory base = string.concat(".contracts.", name);

        try vm.parseJsonAddress(json, string.concat(base, ".address")) returns (address a) {
            e.addr = a;
        } catch {
            return e;
        }
        try vm.parseJsonUint(json, string.concat(base, ".startBlock")) returns (uint256 b) {
            e.startBlock = b;
        } catch {}
        try vm.parseJsonBytes32(json, string.concat(base, ".txHash")) returns (bytes32 h) {
            e.txHash = h;
        } catch {}
    }
}
