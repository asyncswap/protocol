// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ISignatureTransfer} from "@async-swap/interfaces/ISignatureTransfer.sol";
import {OrderSignatures} from "@async-swap/libraries/OrderSignatures.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {CurrencySettler} from "@async-swap/libraries/CurrencySettler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager, SwapParams} from "v4-core/interfaces/IPoolManager.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {AsyncSwap} from "src/AsyncSwap.sol";

/// @title Router
/// @author @msakiart
/// @notice Thin entrypoint for makers (`swap`), fillers (`fillOrder`), and makers cancelling orders
///         (`cancelOrder`). All three actions go through `IPoolManager.unlock` so the hook can
///         operate on PM debts.
///
///         Gasless variants (`swapWithSig`, `cancelWithSig`) take the maker's EIP-712 signature so a
///         relayer can submit. Signed creates pull input through Permit2 with the order as witness,
///         so the wallet shows the full order (tokens, amounts, pool) in one readable message.
contract Router is EIP712 {
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using SafeCast for *;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    IPoolManager immutable POOLMANAGER;
    AsyncSwap immutable HOOK;
    ISignatureTransfer public immutable PERMIT2;

    /// keccak256("Router.ActionType") - 1
    bytes32 constant ACTION_LOCATION = 0xf3b150ebf41dad0872df6788629edb438733cb4a5c9ea779b1b1f3614faffc69;
    /// keccak256("Router.User") - 1
    bytes32 constant USER_LOCATION = 0x3dde20d9bf5cc25a9f487c6d6b54d3c19e3fa4738b91a7a509d4fc4180a72356;
    /// keccak256("Router.AsyncFiller") - 1
    bytes32 constant ASYNC_FILLER_LOCATION = 0xd972a937b59dc5cb8c692dd9f211e85afa8def4caee6e05b31db0f53e16d02e0;
    /// @dev keccak256("asyncswap.router.maxPrice") - 1
    bytes32 constant MAX_PRICE_LOCATION = 0x6b4f8e2c9d5a0b7e1f3c2a8d4e9f0b6c5a1d8e7f2b3c4d5e6a7f8b9c0d1e2f30;

    enum ActionType {
        Swap,
        FillOrder,
        Cancel,
        SwapWithSig
    }

    struct SwapCallback {
        ActionType action;
        AsyncOrder order;
    }

    /// @notice Permit2 signature + nonce/deadline for a signed create.
    struct PermitData {
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    /// @notice Optional signed `SetExecutor` grant, submitted to the hook ahead of the maker's first
    ///         gasless order on a pool. Leave `signature` empty when the Router is already authorized.
    struct ExecutorGrant {
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    /// @notice Unordered nonces consumed by signed cancels (`cancelWithSig`).
    mapping(address maker => mapping(uint256 nonce => bool)) public cancelNonceUsed;

    error SignatureExpired();
    error InvalidSignature();
    error NonceAlreadyUsed();

    constructor(IPoolManager _poolManager, AsyncSwap _hook, ISignatureTransfer _permit2)
        EIP712("AsyncSwap Router", "1")
    {
        POOLMANAGER = _poolManager;
        HOOK = _hook;
        PERMIT2 = _permit2;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(POOLMANAGER), "Caller is not PoolManager");
        _;
    }

    /// @notice Maker submits a new async order. `userData` must encode `AsyncSwap.UserParams`
    ///         with `executor == address(this)` so the router is authorized to fill later.
    ///         `userData.amountOutMin` MUST equal `order.amountOutMin` — the router enforces
    ///         this so the limit price the maker signs in `order` is exactly what beforeSwap
    ///         stores via hookData.
    ///
    ///         The hook auto-assigns a salt on create and emits it in `AsyncOrderCreated`.
    ///         Submitters can pass `order.salt = bytes32(0)` on initial submission; the
    ///         field is only read on cancel / updatePrice / fill paths (where the maker
    ///         supplies the salt fetched from the indexer or event log).
    ///
    ///         Native input (currency0 = address(0) and zeroForOne = true, OR currency1 =
    ///         address(0) and zeroForOne = false) requires `msg.value == order.amountIn` —
    ///         the router holds the ETH and settles it to PM during unlock. For ERC20 input
    ///         the maker must approve the router for `amountIn` of the input token.
    function swap(AsyncOrder calldata order, bytes memory userData) external payable {
        require(order.owner == msg.sender, "Only owner can swap");
        address onBehalf = address(this);
        AsyncSwap.UserParams memory userParams = abi.decode(userData, (AsyncSwap.UserParams));
        require(userParams.user == order.owner, "user mismatch");
        require(userParams.executor == address(this), "Use router as your executor!");
        require(userParams.amountOutMin == order.amountOutMin, "amountOutMin mismatch");

        // msg.value invariant: native input requires exact deposit, ERC20 input forbids overpay.
        // Without this an attacker can sweep ETH stranded from prior overpays in this contract.
        Currency input = order.zeroForOne ? order.key.currency0 : order.key.currency1;
        if (input.isAddressZero()) {
            require(msg.value == order.amountIn, "msg.value != order.amountIn");
        } else {
            require(msg.value == 0, "msg.value forbidden for ERC20 input");
        }
        assembly ("memory-safe") {
            tstore(USER_LOCATION, caller())
            tstore(ASYNC_FILLER_LOCATION, onBehalf)
        }
        POOLMANAGER.unlock(abi.encode(SwapCallback({action: ActionType.Swap, order: order})));
    }

    /// @notice Filler completes an open order, paying the maker's net minimum plus the protocol fee.
    ///         For ERC20 output, approve the router for that gross amount. For native output,
    ///         `msg.value` must equal the live net price plus the protocol fee;
    ///         a stale or excessive deposit reverts rather than stranding the difference.
    ///         Native output is currency1 for zeroForOne, otherwise currency0.
    ///
    ///         `maxPrice` caps total output paid, including the fee —
    ///         it protects fillers from a maker who front-runs them with `updatePrice` to
    ///         bump the order's stored price. Pass `type(uint256).max` to disable the check.
    function fillOrder(AsyncOrder calldata order, uint256 maxPrice, bytes calldata) external payable {
        address onBehalf = address(this);
        assembly ("memory-safe") {
            tstore(USER_LOCATION, caller())
            tstore(ASYNC_FILLER_LOCATION, onBehalf)
            tstore(MAX_PRICE_LOCATION, maxPrice)
        }
        // For native output, forward msg.value to the hook here — the hook will
        // settle it inside fill() during the unlock. Doing this before unlock
        // (rather than from unlockCallback) keeps the payable-only msg.value
        // read out of the non-payable callback.
        Currency output = order.zeroForOne ? order.key.currency1 : order.key.currency0;
        if (output.isAddressZero()) {
            // The caller's struct price may be stale after a maker reprices. Match the
            // total amount settled: maker net output plus protocol fee.
            (, uint256 livePrice) = HOOK.asyncOrderInfo(order.key.toId(), _orderId(order));
            livePrice += HOOK.calculatePoolFee(order.key.fee, livePrice);
            require(msg.value == livePrice, "msg.value != livePrice");
            (bool ok,) = address(HOOK).call{value: msg.value}("");
            require(ok, "Native output transfer to hook failed");
        } else {
            require(msg.value == 0, "msg.value forbidden for ERC20 output");
        }
        POOLMANAGER.unlock(abi.encode(SwapCallback({action: ActionType.FillOrder, order: order})));
    }

    /// @notice Relayer submits a maker's signed order. The maker signs a Permit2
    ///         `PermitWitnessTransferFrom` for `amountIn` of the input token with `spender = Router`
    ///         and the `AsyncOrder` witness (see `OrderSignatures`), so one signature both approves
    ///         the transfer and commits to the order. Input then lands in the hook escrow exactly as
    ///         in `swap`. Requires a prior Permit2 approval of the input token; native input is not
    ///         supported (use `swap`).
    function swapWithSig(AsyncOrder calldata order, PermitData calldata permit, ExecutorGrant calldata grant) external {
        Currency input = order.zeroForOne ? order.key.currency0 : order.key.currency1;
        require(!input.isAddressZero(), "Native input needs swap()");
        if (grant.signature.length != 0 && !HOOK.isExecutor(order.key.toId(), order.owner, address(this))) {
            HOOK.setExecutorWithSig(
                order.key, order.owner, address(this), true, grant.nonce, grant.deadline, grant.signature
            );
        }
        address onBehalf = address(this);
        address maker = order.owner;
        assembly ("memory-safe") {
            tstore(USER_LOCATION, maker)
            tstore(ASYNC_FILLER_LOCATION, onBehalf)
        }
        POOLMANAGER.unlock(abi.encode(SwapCallback({action: ActionType.SwapWithSig, order: order}), permit));
    }

    /// @notice Relayer submits a maker's signed EIP-712 `CancelOrder`. Input returns to the maker.
    function cancelWithSig(AsyncOrder calldata order, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
    {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (cancelNonceUsed[order.owner][nonce]) revert NonceAlreadyUsed();
        cancelNonceUsed[order.owner][nonce] = true;
        bytes32 id = _orderId(order);
        (uint256 amountIn,) = HOOK.asyncOrderInfo(order.key.toId(), id);
        bytes32 digest = _hashTypedDataV4(OrderSignatures.hashCancel(order, id, amountIn, nonce, deadline));
        if (!SignatureChecker.isValidSignatureNow(order.owner, digest, signature)) revert InvalidSignature();
        POOLMANAGER.unlock(abi.encode(SwapCallback({action: ActionType.Cancel, order: order})));
    }

    /// @notice EIP-712 domain separator for Router-verified signatures (`CancelOrder`).
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
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

        if (action == uint8(ActionType.Swap) || action == uint8(ActionType.SwapWithSig)) {
            // Trigger the hook via PM.swap; hook.beforeSwap pulls the maker's input as 6909.
            POOLMANAGER.swap(
                orderData.order.key,
                SwapParams(orderData.order.zeroForOne, -orderData.order.amountIn.toInt256(), orderData.order.sqrtPrice),
                abi.encode(
                    AsyncSwap.UserParams({
                        user: user, executor: asyncFiller, amountOutMin: orderData.order.amountOutMin
                    })
                )
            );
            // Maker pays their input to PM (settling the swap). For native input the
            // router itself holds the ETH (forwarded via msg.value on swap()), and the
            // CurrencySettler.settle native branch sends from address(this) regardless
            // of the `payer` argument, so we still pass `user` for symmetry/logging.
            Currency input = orderData.order.zeroForOne ? orderData.order.key.currency0 : orderData.order.key.currency1;
            if (action == uint8(ActionType.SwapWithSig)) {
                (, PermitData memory permit) = abi.decode(data, (SwapCallback, PermitData));
                _settleWithPermit(input, orderData.order, permit);
            } else {
                input.settle(POOLMANAGER, user, orderData.order.amountIn, false);
            }
        } else if (action == uint8(ActionType.FillOrder)) {
            // Read the LIVE price from hook storage — the caller's `order.amountOutMin` may be
            // stale if the maker called updatePrice after submitting.
            Currency output = orderData.order.zeroForOne ? orderData.order.key.currency1 : orderData.order.key.currency0;
            bytes32 id = _orderId(orderData.order);
            (, uint256 livePrice) = HOOK.asyncOrderInfo(orderData.order.key.toId(), id);
            livePrice += HOOK.calculatePoolFee(orderData.order.key.fee, livePrice);
            uint256 maxPrice;
            assembly ("memory-safe") {
                maxPrice := tload(MAX_PRICE_LOCATION)
            }
            require(livePrice <= maxPrice, "Price exceeds maxPrice");
            // For ERC20 output, pay `livePrice` from the filler straight into the PM and credit
            // it to the hook (filler must have approved this router for that amount); the hook
            // never spends its own token balance. For native output the ETH was already
            // forwarded in fillOrder() above.
            if (!output.isAddressZero()) {
                POOLMANAGER.sync(output);
                IERC20(Currency.unwrap(output)).safeTransferFrom(user, address(POOLMANAGER), livePrice);
                POOLMANAGER.settleFor(address(HOOK));
            }
            HOOK.executeOrder(orderData.order, abi.encode(user));
        } else if (action == uint8(ActionType.Cancel)) {
            HOOK.cancelOrder(orderData.order);
        }

        return "";
    }

    /// @dev Pays the maker's input into the PoolManager via Permit2. Permit2 verifies the maker's
    ///      signature over the transfer AND the order witness, so a relayer cannot alter the order.
    function _settleWithPermit(Currency input, AsyncOrder memory order, PermitData memory permit) private {
        POOLMANAGER.sync(input);
        PERMIT2.permitWitnessTransferFrom(
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({token: Currency.unwrap(input), amount: order.amountIn}),
                nonce: permit.nonce,
                deadline: permit.deadline
            }),
            ISignatureTransfer.SignatureTransferDetails({to: address(POOLMANAGER), requestedAmount: order.amountIn}),
            order.owner,
            OrderSignatures.hashOrder(order),
            OrderSignatures.PERMIT2_WITNESS_TYPE,
            permit.signature
        );
        POOLMANAGER.settle();
    }

    /// @dev MUST match AsyncOrderLibrary.orderId exactly: (chainId, poolId, owner, zeroForOne, salt).
    function _orderId(AsyncOrder memory order) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, order.key.toId(), order.owner, order.zeroForOne, order.salt));
    }
}
