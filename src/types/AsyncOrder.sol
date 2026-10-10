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
/// @param salt         Contract-assigned salt that disambiguates orders. The hook computes this at create
///                     time from `keccak256(timestamp, block.number, msg.sender, owner, amountIn,
///                     amountOutMin)` and emits it in `AsyncOrderCreated` so the maker can reference the
///                     order in cancel / updatePrice. Submitters pass `bytes32(0)` on create — the value
///                     in this slot is only read on cancel / updatePrice / fill paths.
struct AsyncOrder {
    PoolKey key;
    address owner;
    bool zeroForOne;
    uint256 amountIn;
    uint256 amountOutMin;
    uint160 sqrtPrice;
    bytes32 salt;
}

/// @title AsyncOrderLibrary
/// @notice Helpers attached to AsyncOrder for identity and pricing.
library AsyncOrderLibrary {
    using PoolIdLibrary for PoolKey;

    /// @notice Stable identifier for an order, derived from its addressing fields.
    /// @dev    (chainId, poolId, owner, zeroForOne, salt) uniquely identifies one open order.
    ///         - `block.chainid` keeps ids unique across chains where the same PoolKey can be
    ///           deployed (Unichain mainnet + Sepolia, or future chains).
    ///         - `salt` is contract-assigned at create time and stored off-chain (in the event
    ///           log) so the maker can pass it back when calling cancel / updatePrice / fill.
    ///         `view` (not `pure`) because `block.chainid` reads EVM context.
    function orderId(AsyncOrder calldata order) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, order.key.toId(), order.owner, order.zeroForOne, order.salt));
    }

    /// @notice The maker's limit price expressed as 1e18-scaled output per input.
    /// @dev    Reverts on `amountIn == 0`; callers should guard before constructing an order.
    function priceWad(AsyncOrder calldata order) internal pure returns (uint256) {
        return (order.amountOutMin * 1e18) / order.amountIn;
    }
}
