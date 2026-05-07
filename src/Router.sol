// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {AsyncSwap} from "src/AsyncSwap.sol";

/// @title Router
/// @author Async Labs
/// @notice Thin entrypoint for makers (`swap`), fillers (`fillOrder`), and makers cancelling orders
///         (`cancelOrder`). All three actions go through `IPoolManager.unlock` so the hook can
///         operate on PM debts.
contract Router {
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using SafeCast for *;
    using PoolIdLibrary for PoolKey;

    IPoolManager immutable POOLMANAGER;
    AsyncSwap immutable HOOK;

    /// keccak256("Router.ActionType") - 1
    bytes32 constant ACTION_LOCATION = 0xf3b150ebf41dad0872df6788629edb438733cb4a5c9ea779b1b1f3614faffc69;
    /// keccak256("Router.User") - 1
    bytes32 constant USER_LOCATION = 0x3dde20d9bf5cc25a9f487c6d6b54d3c19e3fa4738b91a7a509d4fc4180a72356;
    /// keccak256("Router.AsyncFiller") - 1
    bytes32 constant ASYNC_FILLER_LOCATION = 0xd972a937b59dc5cb8c692dd9f211e85afa8def4caee6e05b31db0f53e16d02e0;

    enum ActionType {
        Swap,
        FillOrder,
        Cancel
    }

    struct SwapCallback {
        ActionType action;
        AsyncOrder order;
    }

    constructor(IPoolManager _poolManager, AsyncSwap _hook) {
        POOLMANAGER = _poolManager;
        HOOK = _hook;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(POOLMANAGER), "Caller is not PoolManager");
        _;
    }

    /// @notice Maker submits a new async order. `userData` must encode `AsyncSwap.UserParams`
    ///         with `executor == address(this)` so the router is authorized to fill later.
    ///         The maker's `amountOutMin` and `nonce` are read from `userData`, NOT `order`,
    ///         because beforeSwap rebuilds the order from hookData server-side.
    ///
    ///         Native input (currency0 = address(0) and zeroForOne = true, OR currency1 =
    ///         address(0) and zeroForOne = false) requires `msg.value == order.amountIn` —
    ///         the router holds the ETH and settles it to PM during unlock. For ERC20 input
    ///         the maker must approve the router for `amountIn` of the input token.
    function swap(AsyncOrder calldata order, bytes memory userData) external payable {
        address onBehalf = address(this);
        AsyncSwap.UserParams memory userParams = abi.decode(userData, (AsyncSwap.UserParams));
        require(userParams.executor == address(this), "Use router as your executor!");
        assembly ("memory-safe") {
            tstore(USER_LOCATION, caller())
            tstore(ASYNC_FILLER_LOCATION, onBehalf)
        }
        POOLMANAGER.unlock(abi.encode(SwapCallback({action: ActionType.Swap, order: order})));
    }

    /// @notice Filler completes an open order. Caller must hold sufficient `amountOutMin` of the
    ///         maker's output currency. For ERC20 output, the caller must approve the router for
    ///         that amount; for native output (currency0 = address(0) on a zeroForOne = true
    ///         order, or currency1 = address(0) on a zeroForOne = false order), the caller
    ///         forwards ETH via `msg.value`.
    function fillOrder(AsyncOrder calldata order, bytes calldata) external payable {
        address onBehalf = address(this);
        assembly ("memory-safe") {
            tstore(USER_LOCATION, caller())
            tstore(ASYNC_FILLER_LOCATION, onBehalf)
        }
        // For native output, forward msg.value to the hook here — the hook will
        // settle it inside fill() during the unlock. Doing this before unlock
        // (rather than from unlockCallback) keeps the payable-only msg.value
        // read out of the non-payable callback.
        Currency output = order.zeroForOne ? order.key.currency1 : order.key.currency0;
        if (output.isAddressZero() && msg.value > 0) {
            (bool ok,) = address(HOOK).call{value: msg.value}("");
            require(ok, "Native output transfer to hook failed");
        }
        POOLMANAGER.unlock(abi.encode(SwapCallback({action: ActionType.FillOrder, order: order})));
    }

    /// @notice Maker cancels an unfilled order and reclaims their reserved input.
    function cancelOrder(AsyncOrder calldata order) external {
        require(msg.sender == order.owner, "Only owner can cancel");
        assembly ("memory-safe") {
            tstore(USER_LOCATION, caller())
        }
        POOLMANAGER.unlock(abi.encode(SwapCallback({action: ActionType.Cancel, order: order})));
    }

    /// @notice PM unlock-callback dispatcher. The action enum is read from transient storage, set
    ///         by the externally-callable entry above. Each branch must leave PM deltas net-zero.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint8 action;
        address user;
        address asyncFiller;
        assembly ("memory-safe") {
            tstore(ACTION_LOCATION, calldataload(0x44))
            action := tload(ACTION_LOCATION)
            user := tload(USER_LOCATION)
            asyncFiller := tload(ASYNC_FILLER_LOCATION)
        }

        SwapCallback memory orderData = abi.decode(data, (SwapCallback));

        if (action == uint8(ActionType.Swap)) {
            // Trigger the hook via PM.swap; hook.beforeSwap pulls the maker's input as 6909.
            POOLMANAGER.swap(
                orderData.order.key,
                IPoolManager.SwapParams(
                    orderData.order.zeroForOne, -orderData.order.amountIn.toInt256(), orderData.order.sqrtPrice
                ),
                abi.encode(
                    AsyncSwap.UserParams({
                        user: user,
                        executor: asyncFiller,
                        amountOutMin: orderData.order.amountOutMin,
                        nonce: orderData.order.nonce
                    })
                )
            );
            // Maker pays their input to PM (settling the swap). For native input the
            // router itself holds the ETH (forwarded via msg.value on swap()), and the
            // CurrencySettler.settle native branch sends from address(this) regardless
            // of the `payer` argument, so we still pass `user` for symmetry/logging.
            Currency input =
                orderData.order.zeroForOne ? orderData.order.key.currency0 : orderData.order.key.currency1;
            input.settle(POOLMANAGER, user, orderData.order.amountIn, false);
        } else if (action == uint8(ActionType.FillOrder)) {
            // Read the LIVE price from hook storage — the caller's `order.amountOutMin` may be
            // stale if the maker called updatePrice after submitting.
            Currency output =
                orderData.order.zeroForOne ? orderData.order.key.currency1 : orderData.order.key.currency0;
            bytes32 id = keccak256(
                abi.encode(
                    orderData.order.key.toId(), orderData.order.owner, orderData.order.zeroForOne, orderData.order.nonce
                )
            );
            (, uint256 livePrice) = HOOK.asyncOrderInfo(orderData.order.key.toId(), id);
            // For ERC20 output, pull `livePrice` from the filler into the hook now (filler
            // must have approved this router for that amount). For native output the ETH
            // was already forwarded in fillOrder() above.
            if (!output.isAddressZero()) {
                assert(IERC20Minimal(Currency.unwrap(output)).transferFrom(user, address(HOOK), livePrice));
            }
            HOOK.executeOrder(orderData.order, abi.encode(user));
        } else if (action == uint8(ActionType.Cancel)) {
            HOOK.cancelOrder(orderData.order);
        }

        return "";
    }

}
