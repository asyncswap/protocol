// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @title CurrencySettler
/// @notice Production copy of v4-core's test-only `CurrencySettler`, using safe transfers so tokens
///         that return no data from `transfer` / `transferFrom` (e.g. USDT) settle correctly.
library CurrencySettler {
    using SafeERC20 for IERC20;

    /// @notice Settle (pay) a currency to the PoolManager.
    /// @param burn If true, burn the payer's ERC-6909 claims instead of transferring tokens.
    function settle(Currency currency, IPoolManager manager, address payer, uint256 amount, bool burn) internal {
        if (burn) {
            manager.burn(payer, currency.toId(), amount);
        } else if (currency.isAddressZero()) {
            manager.settle{value: amount}();
        } else {
            manager.sync(currency);
            if (payer != address(this)) {
                IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), amount);
            } else {
                currency.transfer(address(manager), amount);
            }
            manager.settle();
        }
    }

    /// @notice Take (receive) a currency from the PoolManager.
    /// @param claims If true, mint ERC-6909 claims instead of transferring tokens.
    function take(Currency currency, IPoolManager manager, address recipient, uint256 amount, bool claims) internal {
        claims ? manager.mint(recipient, currency.toId(), amount) : manager.take(currency, recipient, amount);
    }
}
