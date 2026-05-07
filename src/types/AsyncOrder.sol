// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

using AsyncFiller for AsyncOrder global;
using AsyncOrderLibrary for AsyncOrder global;

/// @notice Represents an async order for a swap in the Uniswap V4 pool.
/// @param key          The Uniswap V4 PoolKey identifying the pool the order is placed against.
/// @param owner        The maker who supplied `amountIn` of the input currency at order submission.
/// @param zeroForOne   Direction of the order. true => input is currency0, output is currency1.
/// @param amountIn     Amount of input currency the maker is offering. v1 is exact-input, full-fill only.
/// @param amountOutMin Minimum amount of output currency the maker accepts. The implicit limit price is
///                     `amountOutMin / amountIn`. A filler MUST deliver at least this much output to claim
///                     the maker's input.
/// @param sqrtPrice    Pool sqrt-price the maker is willing to settle at if they cancel into a regular
///                     Uniswap swap. Used as the limit for the cancel-into-swap fallback.
/// @param nonce        Per-maker monotonically-increasing nonce. Together with (key, owner, zeroForOne)
///                     it uniquely identifies an order so it can be updated or cancelled.
struct AsyncOrder {
    PoolKey key;
    address owner;
    bool zeroForOne;
    uint256 amountIn;
    uint256 amountOutMin;
    uint160 sqrtPrice;
    uint64 nonce;
}

/// @title AsyncOrderLibrary
/// @notice Helpers attached to AsyncOrder for identity and pricing.
library AsyncOrderLibrary {
    using PoolIdLibrary for PoolKey;

    /// @notice Stable identifier for an order, derived from its addressing fields.
    /// @dev    (poolId, owner, zeroForOne, nonce) uniquely identifies one open order in v1
    ///         and is the key used by cancel and updatePrice.
    function orderId(AsyncOrder calldata order) internal pure returns (bytes32) {
        return keccak256(abi.encode(order.key.toId(), order.owner, order.zeroForOne, order.nonce));
    }

    /// @notice The maker's limit price expressed as 1e18-scaled output per input.
    /// @dev    Reverts on `amountIn == 0`; callers should guard before constructing an order.
    function priceWad(AsyncOrder calldata order) internal pure returns (uint256) {
        return (order.amountOutMin * 1e18) / order.amountIn;
    }
}
