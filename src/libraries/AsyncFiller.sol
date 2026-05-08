// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @title AsyncFiller
/// @author @msakiart
/// @notice Stores open async orders and settles fills against them.
///
/// @dev    Authorization model: the maker authorizes a Router/executor at order-creation time
///         (`setExecutor[owner][executor] = true`). All subsequent fill / cancel / updatePrice
///         calls on the hook must come from that registered executor. The hook forwards its
///         immediate caller (`msg.sender`) and the resolved end-actor address (filler / canceller)
///         into this library; the executor is checked here, and PM settlement targets the actor.
library AsyncFiller {
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;

    /// @notice Open-order record. v1 is full-fill only — partials are not supported and
    ///         a successful fill deletes the record entirely.
    struct OrderInfo {
        uint256 amountIn;
        uint256 amountOutMin;
    }

    struct State {
        IPoolManager poolManager;
        mapping(bytes32 orderId => OrderInfo) orders;
        mapping(address owner => mapping(address executor => bool)) setExecutor;
    }

    event AsyncOrderCreated(
        PoolId indexed poolId,
        bytes32 indexed orderId,
        address indexed owner,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        uint64 nonce
    );

    event AsyncOrderPriceUpdated(
        PoolId indexed poolId, bytes32 indexed orderId, uint256 oldAmountOutMin, uint256 newAmountOutMin
    );

    event AsyncOrderFilled(
        PoolId indexed poolId, bytes32 indexed orderId, address indexed filler, uint256 amountIn, uint256 amountOutMin
    );

    event AsyncOrderCancelled(PoolId indexed poolId, bytes32 indexed orderId, address indexed owner, uint256 amountIn);

    error OrderAlreadyExists();
    error OrderNotFound();
    error NotOrderOwner();
    error NotAuthorizedExecutor();
    error ZeroAmount();

    function isExecutor(AsyncOrder calldata order, State storage self, address executor) internal view returns (bool) {
        return self.setExecutor[order.owner][executor];
    }

    /// @notice Maker-only price update. The executor (router) is required to be authorized by
    ///         the maker, AND `caller` must equal `order.owner` — both checked here.
    function updatePrice(
        State storage self,
        AsyncOrder calldata order,
        bytes32 id,
        uint256 newAmountOutMin,
        address caller
    ) internal {
        if (caller != order.owner) revert NotOrderOwner();
        if (newAmountOutMin == 0) revert ZeroAmount();
        OrderInfo storage info = self.orders[id];
        if (info.amountIn == 0) revert OrderNotFound();
        uint256 old = info.amountOutMin;
        info.amountOutMin = newAmountOutMin;
        emit AsyncOrderPriceUpdated(order.key.toId(), id, old, newAmountOutMin);
    }

    /// @notice Full-fill. The caller (the hook contract) must be an authorized executor of the
    ///         order owner; `filler` is the actual end-user paying the output and receiving the
    ///         input. Must be invoked from inside an `IPoolManager.unlock` context.
    ///
    /// @dev    PM operations net to zero on both currencies:
    ///           - output already settled by router from filler (see Router.unlockCallback)
    ///           - hook mints 6909 of output to the maker      → -outputDelta on locker
    ///           - hook burns its 6909 of input                → -inputDelta on locker
    ///           - filler `take`s real input                   → +inputDelta on locker
    function fill(
        State storage self,
        AsyncOrder calldata order,
        bytes32 id,
        address hook,
        address executor,
        address filler
    ) internal {
        if (!self.setExecutor[order.owner][executor]) revert NotAuthorizedExecutor();
        OrderInfo storage info = self.orders[id];
        uint256 amountIn = info.amountIn;
        uint256 amountOutMin = info.amountOutMin;
        if (amountIn == 0) revert OrderNotFound();

        Currency input = order.zeroForOne ? order.key.currency0 : order.key.currency1;
        Currency output = order.zeroForOne ? order.key.currency1 : order.key.currency0;

        delete self.orders[id];

        // Output side: hook holds the filler's tokens (router transferred them in). Settle them
        // to PM, then take real tokens straight to the maker — no 6909 withdrawal step needed
        // post-fill. Both attribute to the hook → net zero on output delta.
        output.settle(self.poolManager, hook, amountOutMin, false);
        output.take(self.poolManager, order.owner, amountOutMin, false);

        // Input side: burn the hook's 6909 input claim and pay the filler real input tokens.
        input.settle(self.poolManager, hook, amountIn, true);
        input.take(self.poolManager, filler, amountIn, false);

        emit AsyncOrderFilled(order.key.toId(), id, filler, amountIn, amountOutMin);
    }

    /// @notice Cancel an unfilled order. Must be called inside an unlock context. Auth: `executor`
    ///         must be either the order owner themselves (smart-contract makers calling the hook
    ///         directly from their own unlock) or an executor the maker authorised via
    ///         `setExecutor`. Funds always return to `order.owner`.
    function cancel(State storage self, AsyncOrder calldata order, bytes32 id, address hook, address executor)
        internal
    {
        if (executor != order.owner && !self.setExecutor[order.owner][executor]) {
            revert NotAuthorizedExecutor();
        }
        OrderInfo storage info = self.orders[id];
        uint256 amountIn = info.amountIn;
        if (amountIn == 0) revert OrderNotFound();

        Currency input = order.zeroForOne ? order.key.currency0 : order.key.currency1;
        delete self.orders[id];

        // Burn the hook's 6909 input claim, then return real input tokens to the maker
        // directly — no separate withdrawal step required.
        input.settle(self.poolManager, hook, amountIn, true);
        input.take(self.poolManager, order.owner, amountIn, false);

        emit AsyncOrderCancelled(order.key.toId(), id, order.owner, amountIn);
    }
}
