// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncOrder, AsyncOrderLibrary} from "@async-swap/types/AsyncOrder.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {BaseHook} from "src/BaseHook.sol";

/// @title AsyncSwap
/// @author Async Labs
/// @notice Uniswap v4 hook that converts an exact-input swap into an open async order: the maker
///         deposits their input via `_beforeSwap`, and a filler later settles by paying the maker's
///         limit-priced output. v1 is full-fill only.
contract AsyncSwap is BaseHook {
    using SafeCast for *;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using AsyncFiller for AsyncFiller.State;
    using AsyncOrderLibrary for AsyncOrder;

    /// @notice Per-pool order book.
    mapping(PoolId poolId => AsyncFiller.State) public asyncOrders;

    /// @notice Pool-level swap-event mirror; bytes32 poolId for indexer compatibility.
    /// @dev    See https://github.com/OpenZeppelin/uniswap-hooks BaseAsyncSwap for the source pattern.
    event HookSwap(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
    );

    error UnsupportedLiquidity();
    error ExactInputOnly();
    error UnaccountedNativeOutput();

    /// @dev Transient slot — keccak256("asyncswap.hook.pendingNativeDeposit") - 1.
    ///      Tracks ETH deposited to this contract within the current tx via
    ///      `receive()`, so `executeOrder` can settle native output only out of
    ///      the filler's just-received deposit rather than the contract's
    ///      accumulated balance (which may include donations, stranded ETH,
    ///      or in-flight native-input escrow). Cleared after each settle.
    bytes32 constant PENDING_NATIVE_DEPOSIT_SLOT =
        0x9c2a7e4f3b1d8a5c6e0f2d4b7a9c1e3d5f8b6a0c2e4d7b9f1a3c5e7d9b1f3a50;

    /// @notice Hook params decoded from the `hookData` of `IPoolManager.swap`. The maker sets
    ///         `amountOutMin` (their limit price) and `nonce` (so they can address this order
    ///         later for cancel / updatePrice). `executor` is the address authorized to call fill.
    struct UserParams {
        address user;
        address executor;
        uint256 amountOutMin;
        uint64 nonce;
    }

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// @inheritdoc BaseHook
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
        require(key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG, "Dude use dynamic fees flag");
        asyncOrders[key.toId()].poolManager = poolManager;
        return this.beforeInitialize.selector;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @inheritdoc BaseHook
    function _beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert UnsupportedLiquidity();
    }

    /// @notice Read an order's currently-open input amount. Returns 0 if the order does not exist.
    function asyncOrder(PoolId poolId, bytes32 orderId) external view returns (uint256 amountIn) {
        return asyncOrders[poolId].orders[orderId].amountIn;
    }

    /// @notice Read both legs of an open order. Returns (0, 0) if the order does not exist.
    function asyncOrderInfo(PoolId poolId, bytes32 orderId)
        external
        view
        returns (uint256 amountIn, uint256 amountOutMin)
    {
        AsyncFiller.OrderInfo storage info = asyncOrders[poolId].orders[orderId];
        return (info.amountIn, info.amountOutMin);
    }

    function isExecutor(PoolId poolId, address owner, address executor) external view returns (bool) {
        return asyncOrders[poolId].setExecutor[owner][executor];
    }

    function calculateHookFee(uint256) public pure returns (uint256) {
        return 0;
    }

    function calculatePoolFee(uint24, uint256) public pure returns (uint256) {
        return 0;
    }

    /// @notice Fill `order` in full. Must be called from an authorized executor (router) that has
    ///         already settled `amountOutMin` of output from the filler within the same unlock.
    /// @param  data abi.encode(filler) — the address that should receive the maker's input.
    function executeOrder(AsyncOrder calldata order, bytes calldata data) external {
        address filler = abi.decode(data, (address));
        bytes32 id = order.orderId();

        // Native-output settlement may only consume ETH that the filler deposited
        // in this tx (via the Router's pre-unlock forward). Stranded balance is
        // not drawable. Decrement the per-tx ledger to amountOutMin's worth.
        Currency output = order.zeroForOne ? order.key.currency1 : order.key.currency0;
        if (output.isAddressZero()) {
            uint256 pending;
            assembly ("memory-safe") { pending := tload(PENDING_NATIVE_DEPOSIT_SLOT) }
            (, uint256 amountOutMin) = (this.asyncOrderInfo(order.key.toId(), id));
            if (pending < amountOutMin) revert UnaccountedNativeOutput();
            assembly ("memory-safe") {
                tstore(PENDING_NATIVE_DEPOSIT_SLOT, sub(pending, amountOutMin))
            }
        }
        asyncOrders[order.key.toId()].fill(order, id, address(this), msg.sender, filler);
    }

    /// @notice Batch-fill. `data` = abi.encode(filler). Same authorization rules as executeOrder.
    function executeOrders(AsyncOrder[] calldata orders, bytes calldata data) external {
        address filler = abi.decode(data, (address));
        for (uint256 i = 0; i < orders.length; i++) {
            AsyncOrder calldata order = orders[i];
            bytes32 id = order.orderId();
            asyncOrders[order.key.toId()].fill(order, id, address(this), msg.sender, filler);
        }
    }

    /// @notice Maker updates the limit price of an unfilled order. Direct call from the maker —
    ///         pure state mutation, no PM interaction, so no unlock or router needed.
    function updatePrice(AsyncOrder calldata order, uint256 newAmountOutMin) external {
        bytes32 id = order.orderId();
        asyncOrders[order.key.toId()].updatePrice(order, id, newAmountOutMin, msg.sender);
    }

    /// @notice Maker cancels an unfilled order. Must be called via an authorized executor inside
    ///         an `IPoolManager.unlock` context. The executor must have asserted maker identity.
    function cancelOrder(AsyncOrder calldata order) external {
        bytes32 id = order.orderId();
        asyncOrders[order.key.toId()].cancel(order, id, address(this), msg.sender);
    }

    /// @inheritdoc BaseHook
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookParams
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (params.amountSpecified > 0) revert ExactInputOnly();

        PoolId poolId = key.toId();
        uint256 amountTaken = uint256(-params.amountSpecified);
        UserParams memory hookData = abi.decode(hookParams, (UserParams));

        Currency specified = params.zeroForOne ? key.currency0 : key.currency1;

        // Hook takes maker's input as a 6909 claim. The BeforeSwapDelta below offsets the swap.
        specified.take(poolManager, address(this), amountTaken, true);

        uint256 feeAmount = calculatePoolFee(key.fee, amountTaken);
        uint256 finalTaken = amountTaken - feeAmount;

        _createOrder(poolId, params.zeroForOne, finalTaken, hookData);

        if (specified == key.currency0) {
            emit HookSwap(PoolId.unwrap(poolId), sender, amountTaken.toInt128(), 0, feeAmount.toUint128(), 0);
        } else {
            emit HookSwap(PoolId.unwrap(poolId), sender, 0, amountTaken.toInt128(), 0, feeAmount.toUint128());
        }

        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(int128(-params.amountSpecified), 0);
        return (BaseHook.beforeSwap.selector, beforeSwapDelta, 0);
    }

    /// @dev Extracted to keep `_beforeSwap` stack-shallow.
    function _createOrder(PoolId poolId, bool zeroForOne, uint256 amountIn, UserParams memory hookData) private {
        AsyncFiller.State storage state = asyncOrders[poolId];

        // executor must already be authorised by the user — no implicit grant via hookData.
        if (!state.setExecutor[hookData.user][hookData.executor]) revert AsyncFiller.NotAuthorizedExecutor();

        bytes32 id = keccak256(abi.encode(poolId, hookData.user, zeroForOne, hookData.nonce));
        if (amountIn == 0 || hookData.amountOutMin == 0) revert AsyncFiller.ZeroAmount();
        if (state.orders[id].amountIn != 0) revert AsyncFiller.OrderAlreadyExists();
        state.orders[id] = AsyncFiller.OrderInfo({amountIn: amountIn, amountOutMin: hookData.amountOutMin});
        emit AsyncFiller.AsyncOrderCreated(
            poolId, id, hookData.user, zeroForOne, amountIn, hookData.amountOutMin, hookData.nonce
        );
    }

    /// @notice Maker explicitly authorises an executor (typically the Router) to submit
    ///         and fill orders on their behalf. Without this grant, `_createOrder` reverts
    ///         on the maker's first swap. Pairs with `revokeExecutor` for rotation.
    function setExecutor(PoolId poolId, address executor, bool allow) external {
        asyncOrders[poolId].setExecutor[msg.sender][executor] = allow;
    }

    /// @notice Accept ETH transfers. The Router (or any caller paying for a native-output
    /// fill) forwards `msg.value` to the hook before triggering `executeOrder`. The hook
    /// records the deposit on a transient slot so `executeOrder` can settle ONLY against
    /// the filler's freshly-deposited ETH — never against donated, stranded, or in-flight
    /// escrow balance. Plain transfers (no executeOrder follow-up) just sit in balance
    /// and can be returned by recovery flows; they cannot be drained via fillOrder.
    receive() external payable {
        assembly ("memory-safe") {
            let cur := tload(PENDING_NATIVE_DEPOSIT_SLOT)
            tstore(PENDING_NATIVE_DEPOSIT_SLOT, add(cur, callvalue()))
        }
    }
}
