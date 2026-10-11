// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @title OrderSignatures
/// @author @msakiart
/// @notice EIP-712 types for signed AsyncSwap actions. Every type spells out the maker, both tokens
///         and the amounts so wallets render a readable message instead of opaque calldata.
///
///         - `AsyncOrder` is the Permit2 witness for `Router.swapWithSig` (Permit2 domain).
///         - `SetExecutor` and `UpdatePrice` are verified by the hook (AsyncSwap domain).
///         - `CancelOrder` is verified by the Router (AsyncSwap Router domain).
library OrderSignatures {
    bytes internal constant POOL_KEY_TYPE =
        "PoolKey(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)";

    bytes internal constant ASYNC_ORDER_TYPE =
        "AsyncOrder(address maker,address tokenIn,address tokenOut,uint256 amountIn,uint256 amountOutMin,PoolKey pool)";

    bytes32 internal constant POOL_KEY_TYPEHASH = keccak256(POOL_KEY_TYPE);

    bytes32 internal constant ASYNC_ORDER_TYPEHASH = keccak256(abi.encodePacked(ASYNC_ORDER_TYPE, POOL_KEY_TYPE));

    /// @notice Witness type string appended by Permit2 to `PermitWitnessTransferFrom(...)`.
    ///         Referenced types are sorted alphabetically per EIP-712.
    string internal constant PERMIT2_WITNESS_TYPE = string(
        abi.encodePacked(
            "AsyncOrder witness)", ASYNC_ORDER_TYPE, POOL_KEY_TYPE, "TokenPermissions(address token,uint256 amount)"
        )
    );

    bytes32 internal constant SET_EXECUTOR_TYPEHASH = keccak256(
        abi.encodePacked(
            "SetExecutor(address maker,address executor,bool allow,PoolKey pool,uint256 nonce,uint256 deadline)",
            POOL_KEY_TYPE
        )
    );

    bytes32 internal constant UPDATE_PRICE_TYPEHASH = keccak256(
        "UpdatePrice(address maker,address tokenIn,address tokenOut,uint256 amountIn,uint256 newAmountOutMin,bytes32 orderId,uint256 nonce,uint256 deadline)"
    );

    bytes32 internal constant CANCEL_ORDER_TYPEHASH = keccak256(
        "CancelOrder(address maker,address tokenIn,address tokenOut,uint256 amountIn,bytes32 orderId,uint256 nonce,uint256 deadline)"
    );

    function tokens(AsyncOrder memory order) internal pure returns (address tokenIn, address tokenOut) {
        (Currency input, Currency output) =
            order.zeroForOne ? (order.key.currency0, order.key.currency1) : (order.key.currency1, order.key.currency0);
        return (Currency.unwrap(input), Currency.unwrap(output));
    }

    function hashPoolKey(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                POOL_KEY_TYPEHASH,
                Currency.unwrap(key.currency0),
                Currency.unwrap(key.currency1),
                key.fee,
                key.tickSpacing,
                address(key.hooks)
            )
        );
    }

    /// @notice Struct hash of the order a maker signs as the Permit2 witness. Covers everything that
    ///         defines the order; `sqrtPrice` is excluded (the hook consumes the whole swap, so v4
    ///         never reads the price limit) and `salt` is assigned by the hook at create time.
    function hashOrder(AsyncOrder memory order) internal pure returns (bytes32) {
        (address tokenIn, address tokenOut) = tokens(order);
        return keccak256(
            abi.encode(
                ASYNC_ORDER_TYPEHASH,
                order.owner,
                tokenIn,
                tokenOut,
                order.amountIn,
                order.amountOutMin,
                hashPoolKey(order.key)
            )
        );
    }

    function hashSetExecutor(
        PoolKey memory key,
        address maker,
        address executor,
        bool allow,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(SET_EXECUTOR_TYPEHASH, maker, executor, allow, hashPoolKey(key), nonce, deadline));
    }

    /// @param amountIn the order's stored input, so the maker sees the size of the order they reprice.
    function hashUpdatePrice(
        AsyncOrder memory order,
        bytes32 orderId,
        uint256 amountIn,
        uint256 newAmountOutMin,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        (address tokenIn, address tokenOut) = tokens(order);
        return keccak256(
            abi.encode(
                UPDATE_PRICE_TYPEHASH,
                order.owner,
                tokenIn,
                tokenOut,
                amountIn,
                newAmountOutMin,
                orderId,
                nonce,
                deadline
            )
        );
    }

    /// @dev Carries a nonce: order ids can recur (identical order re-placed in the same block after a
    ///      cancel), so order deletion alone does not stop a signed cancel from being replayed.
    function hashCancel(AsyncOrder memory order, bytes32 orderId, uint256 amountIn, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (bytes32)
    {
        (address tokenIn, address tokenOut) = tokens(order);
        return keccak256(
            abi.encode(CANCEL_ORDER_TYPEHASH, order.owner, tokenIn, tokenOut, amountIn, orderId, nonce, deadline)
        );
    }
}
