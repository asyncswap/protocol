// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

interface IFeeOwner {
    function owner() external view returns (address);
}

/// @notice Holds and redeems protocol fee claims, never maker escrow.
contract FeeVault {
    IPoolManager public immutable poolManager;
    IFeeOwner public immutable hook;

    error Unauthorized();
    error ZeroAddress();

    event FeesCollected(Currency indexed currency, address indexed recipient, uint256 amount);

    constructor(IPoolManager manager) {
        poolManager = manager;
        hook = IFeeOwner(msg.sender);
    }

    /// @notice The current protocol owner may redeem all fees of one currency.
    function collect(Currency currency, address recipient) external {
        if (msg.sender != hook.owner()) revert Unauthorized();
        if (recipient == address(0)) revert ZeroAddress();
        poolManager.unlock(abi.encode(currency, recipient));
    }

    /// @dev PoolManager only calls this vault back during its own collection unlock.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        (Currency currency, address recipient) = abi.decode(data, (Currency, address));
        uint256 id = currency.toId();
        uint256 amount = poolManager.balanceOf(address(this), id);
        if (amount != 0) {
            poolManager.burn(address(this), id, amount);
            poolManager.take(currency, recipient, amount);
        }
        emit FeesCollected(currency, recipient, amount);
        return "";
    }
}
