// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {OrderSignatures} from "@async-swap/libraries/OrderSignatures.sol";
import {AsyncOrder, AsyncOrderLibrary} from "@async-swap/types/AsyncOrder.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {CurrencySettler} from "@async-swap/libraries/CurrencySettler.sol";
import {IPoolManager, ModifyLiquidityParams, SwapParams} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {FeeVault} from "src/FeeVault.sol";
import {BaseHook} from "src/BaseHook.sol";

/// @title AsyncSwap
/// @author @msakiart
/// @notice Uniswap v4 hook that converts an exact-input swap into an open async order: the maker
///         deposits their input via `_beforeSwap`, and a filler later settles by paying the maker's
///         limit-priced output. v1 is full-fill only.
///
///         Makers can also act by EIP-712 signature (`setExecutorWithSig`, `updatePriceWithSig`) so a
///         relayer pays gas and the wallet shows a readable message. See `OrderSignatures` for types.
contract AsyncSwap is BaseHook, EIP712 {
    using SafeCast for *;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using AsyncFiller for AsyncFiller.State;
    using AsyncOrderLibrary for AsyncOrder;

    /// @notice Per-pool order book.
    mapping(PoolId poolId => AsyncFiller.State) public asyncOrders;

    /// @notice Protocol owner authorized to collect vault fees and sweep stranded balances.
    address public owner;

    /// @notice Address nominated by `transferOwnership`; becomes owner on `acceptOwnership`.
    address public pendingOwner;

    /// @notice Holds fee claims separately from open-order escrow.
    FeeVault public immutable feeVault;

    /// @notice Chain-specific USDC address. Every pool must include this exact currency.
    Currency public immutable numeraire;

    /// @notice Unordered nonces consumed by signed maker actions (`setExecutorWithSig`, `updatePriceWithSig`).
    mapping(address maker => mapping(uint256 nonce => bool)) public nonceUsed;

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
    error NotOwner();
    error ZeroAddress();
    error SignatureExpired();
    error InvalidSignature();
    error NonceAlreadyUsed();
    error InvalidNumeraire();
    error NumeraireRequired();
    error DynamicFeeRequired();

    /// @notice Emitted when ownership is transferred.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when the owner nominates a new owner.
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when the owner sweeps an accumulated balance.
    event Swept(Currency indexed currency, address indexed to, uint256 amount);

    /// @notice Emitted when a maker burns a nonce, consumed or revoked.
    event NonceInvalidated(address indexed maker, uint256 nonce);

    /// @notice Emitted after each successful direct or signed executor authorization update.
    /// @dev `allow` is the resulting permission, including when the value is unchanged.
    event ExecutorSet(PoolId indexed poolId, address indexed maker, address indexed executor, bool allow);

    /// @notice Restricts a call to the protocol owner.
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Transient slot — keccak256("asyncswap.hook.pendingNativeDeposit") - 1.
    ///      Tracks ETH deposited to this contract within the current tx via
    ///      `receive()`, so `executeOrder` can settle native output only out of
    ///      the filler's just-received deposit rather than the contract's
    ///      accumulated balance (which may include donations, stranded ETH,
    ///      or in-flight native-input escrow). Cleared after each settle.
    bytes32 constant PENDING_NATIVE_DEPOSIT_SLOT = 0x9c2a7e4f3b1d8a5c6e0f2d4b7a9c1e3d5f8b6a0c2e4d7b9f1a3c5e7d9b1f3a50;

    /// @notice Hook params decoded from the `hookData` of `IPoolManager.swap`. The maker sets
    ///         `amountOutMin` (their limit price); `executor` is the address authorized to call fill.
    ///         Salt is contract-assigned at create time (see `_createOrder`) and emitted in
    ///         `AsyncOrderCreated` — the maker fetches it from the event log to reference the
    ///         order in cancel / updatePrice later.
    struct UserParams {
        address user;
        address executor;
        uint256 amountOutMin;
    }

    /// @param _owner Explicit protocol owner. Not `msg.sender`: CREATE2 deployments run the
    ///               constructor from the deterministic deployer, which could never act as owner.
    constructor(IPoolManager _poolManager, Currency _numeraire, address _owner)
        BaseHook(_poolManager)
        EIP712("AsyncSwap", "1")
    {
        if (Currency.unwrap(_numeraire).code.length == 0) revert InvalidNumeraire();
        if (_owner == address(0)) revert ZeroAddress();
        numeraire = _numeraire;
        owner = _owner;
        feeVault = new FeeVault(_poolManager);
        emit OwnershipTransferred(address(0), _owner);
    }

    /// @notice Start a two-step ownership transfer. The deployer (or a factory) should call this after
    ///         deployment to hand control to the intended fee recipient / governance address, which
    ///         then calls `acceptOwnership`.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Complete a two-step ownership transfer. Only the nominated `pendingOwner` may call.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Sweep an accumulated balance of `currency` held by this hook to `to`.
    /// @dev    Between transactions the hook's raw balance holds only stranded funds or donations;
    ///         fees belong to feeVault. Maker input is escrowed as ERC-6909
    ///         claims in the PoolManager, and the transient native-deposit ledger is cleared at the
    ///         end of every tx, so no per-order escrow lives in the hook's balance across calls.
    function sweep(Currency currency, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = currency.balanceOfSelf();
        currency.transfer(to, amount);
        emit Swept(currency, to, amount);
    }

    /// @inheritdoc BaseHook
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
        if (!(key.currency0 == numeraire || key.currency1 == numeraire)) revert NumeraireRequired();
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert DynamicFeeRequired();
        asyncOrders[key.toId()].poolManager = poolManager;
        return this.beforeInitialize.selector;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // true
            afterInitialize: false,
            beforeAddLiquidity: true, // true
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // true
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // true
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @inheritdoc BaseHook
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
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

    function isExecutor(PoolId poolId, address maker, address executor) external view returns (bool) {
        return asyncOrders[poolId].isExecutor[maker][executor];
    }

    function calculateHookFee(uint256) public pure returns (uint256) {
        return 0;
    }

    /// @notice Fee added to the maker's net output: 0.3% of gross output, rounded down.
    function calculatePoolFee(uint24, uint256 amount) public pure virtual returns (uint256) {
        // net * 3 / 997 is equivalent to 30 bps of gross (net + fee), rounded down.
        // Split the calculation to avoid overflowing for large uint256 amounts.
        return (amount / 997) * 3 + ((amount % 997) * 3) / 997;
    }

    /// @notice Fill `order` in full. Must be called from an authorized executor (router) that has
    ///         already paid the filler's gross output within the same unlock: for ERC20 output via
    ///         `PoolManager.settleFor(hook)`, for native output by sending ETH to this hook.
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
            amountOutMin += calculatePoolFee(order.key.fee, amountOutMin);
            if (pending < amountOutMin) revert UnaccountedNativeOutput();
            assembly ("memory-safe") {
                tstore(PENDING_NATIVE_DEPOSIT_SLOT, sub(pending, amountOutMin))
            }
        }
        AsyncFiller.State storage state = asyncOrders[order.key.toId()];
        uint256 fee = calculatePoolFee(order.key.fee, state.orders[id].amountOutMin);
        state.fill(order, id, address(this), msg.sender, filler, address(feeVault), fee);
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
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookParams)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified > 0) revert ExactInputOnly();

        PoolId poolId = key.toId();
        uint256 amountTaken = uint256(-params.amountSpecified);
        UserParams memory hookData = abi.decode(hookParams, (UserParams));
        // Bind the declared executor to the actual swap caller so nobody can open orders
        // attributed to a maker through an executor they do not control.
        if (sender != hookData.executor) revert AsyncFiller.NotAuthorizedExecutor();

        Currency specified = params.zeroForOne ? key.currency0 : key.currency1;

        // Escrow the entire deposit; fees are earned only on successful fill.
        specified.take(poolManager, address(this), amountTaken, true);
        _createOrder(poolId, params.zeroForOne, amountTaken, hookData);

        if (specified == key.currency0) {
            emit HookSwap(PoolId.unwrap(poolId), sender, amountTaken.toInt128(), 0, 0, 0);
        } else {
            emit HookSwap(PoolId.unwrap(poolId), sender, 0, amountTaken.toInt128(), 0, 0);
        }

        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(int128(-params.amountSpecified), 0);
        return (BaseHook.beforeSwap.selector, beforeSwapDelta, 0);
    }

    /// @dev Extracted to keep `_beforeSwap` stack-shallow.
    function _createOrder(PoolId poolId, bool zeroForOne, uint256 amountIn, UserParams memory hookData) private {
        AsyncFiller.State storage state = asyncOrders[poolId];

        // executor must already be authorised by the user — no implicit grant via hookData.
        if (!state.isExecutor[hookData.user][hookData.executor]) revert AsyncFiller.NotAuthorizedExecutor();
        if (amountIn == 0 || hookData.amountOutMin == 0) revert AsyncFiller.ZeroAmount();

        // Contract-assigned salt — derived from immutable order params + block context
        // so the maker doesn't need to pick a nonce. The orderId preimage MUST match
        // `AsyncOrderLibrary.orderId` (chainId, poolId, owner, zeroForOne, salt), since
        // the cancel/updatePrice/fill paths recompute the id via the library.
        bytes32 salt = keccak256(
            abi.encode(block.timestamp, block.number, msg.sender, hookData.user, amountIn, hookData.amountOutMin)
        );
        bytes32 id = keccak256(abi.encode(block.chainid, poolId, hookData.user, zeroForOne, salt));
        // Collision walk: same maker submitting identical (amountIn, amountOutMin) twice
        // in the same block would land on the same salt. Re-hash with an attempt counter
        // until the slot is free. The caller pays the extra gas, so no griefing surface.
        while (state.orders[id].amountIn != 0) {
            salt = keccak256(abi.encode(salt));
            id = keccak256(abi.encode(block.chainid, poolId, hookData.user, zeroForOne, salt));
        }

        state.orders[id] = AsyncFiller.OrderInfo({amountIn: amountIn, amountOutMin: hookData.amountOutMin});
        emit AsyncFiller.AsyncOrderCreated(poolId, id, hookData.user, zeroForOne, amountIn, hookData.amountOutMin, salt);
    }

    /// @notice Maker explicitly authorises an executor (typically the Router) to submit
    ///         and fill orders on their behalf. Without this grant, `_createOrder` reverts
    ///         on the maker's first swap. Pass `allow = false` to revoke an executor.
    function setExecutor(PoolId poolId, address executor, bool allow) external {
        asyncOrders[poolId].isExecutor[msg.sender][executor] = allow;
        emit ExecutorSet(poolId, msg.sender, executor, allow);
    }

    /// @notice Signed `setExecutor`: anyone may submit the maker's EIP-712 `SetExecutor` grant.
    ///         Lets a relayer authorize the Router before the maker's first gasless order on a pool.
    function setExecutorWithSig(
        PoolKey calldata key,
        address maker,
        address executor,
        bool allow,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verify(
            maker,
            OrderSignatures.hashSetExecutor(key, maker, executor, allow, nonce, deadline),
            nonce,
            deadline,
            signature
        );
        PoolId poolId = key.toId();
        asyncOrders[poolId].isExecutor[maker][executor] = allow;
        emit ExecutorSet(poolId, maker, executor, allow);
    }

    /// @notice Signed `updatePrice`: anyone may submit the maker's EIP-712 `UpdatePrice` message.
    function updatePriceWithSig(
        AsyncOrder calldata order,
        uint256 newAmountOutMin,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        PoolId poolId = order.key.toId();
        bytes32 id = order.orderId();
        uint256 amountIn = asyncOrders[poolId].orders[id].amountIn;
        _verify(
            order.owner,
            OrderSignatures.hashUpdatePrice(order, id, amountIn, newAmountOutMin, nonce, deadline),
            nonce,
            deadline,
            signature
        );
        asyncOrders[poolId].updatePrice(order, id, newAmountOutMin, order.owner);
    }

    /// @notice Revoke a signed action before a relayer submits it.
    function invalidateNonce(uint256 nonce) external {
        if (nonceUsed[msg.sender][nonce]) revert NonceAlreadyUsed();
        nonceUsed[msg.sender][nonce] = true;
        emit NonceInvalidated(msg.sender, nonce);
    }

    /// @notice EIP-712 domain separator for this hook's signed actions.
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @dev Checks deadline, burns the nonce, then validates an EOA or ERC-1271 signature.
    function _verify(address maker, bytes32 structHash, uint256 nonce, uint256 deadline, bytes calldata signature)
        private
    {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (nonceUsed[maker][nonce]) revert NonceAlreadyUsed();
        nonceUsed[maker][nonce] = true;
        emit NonceInvalidated(maker, nonce);
        if (!SignatureChecker.isValidSignatureNow(maker, _hashTypedDataV4(structHash), signature)) {
            revert InvalidSignature();
        }
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
