// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ISignatureTransfer} from "@async-swap/interfaces/ISignatureTransfer.sol";
import {Permit2Bytecode} from "../utils/Permit2Bytecode.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Router} from "@async-swap/Router.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Currency, IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice H05: Native-output fill overpayment is permanently stranded in the hook.
///
/// Root cause:
///   - Router.fillOrder requires `msg.value == order.amountOutMin`, where `order.amountOutMin`
///     is the CALLER-SUPPLIED struct field (not part of the orderId, and not validated against
///     the live stored price).
///   - The full msg.value is forwarded to the hook via receive() and credited to the transient
///     PENDING ledger.
///   - Settlement (executeOrder -> AsyncFiller.fill) uses the LIVE price read from storage.
///     Only `livePrice` worth of ETH is settled to the PoolManager and paid to the maker; the
///     PENDING ledger is decremented only by `livePrice`.
///   - The positive difference `msg.value - livePrice` stays in the hook's raw ETH balance,
///     and there is NO withdraw / sweep / recover function anywhere in src/.
///
/// Contrast: the ERC20-output branch (Router.sol:191) pulls EXACTLY `livePrice` via
/// transferFrom, so ERC20 fillers can never overpay.
///
/// Native pools always have currency0 = address(0) (ETH sorts first). Native OUTPUT therefore
/// requires zeroForOne = false: maker sells currency1 (TST) and is paid currency0 (ETH); the
/// filler forwards ETH via msg.value.
contract H05_NativeOverpayStrandedTest is Test {
    using PoolIdLibrary for PoolKey;

    address owner = makeAddr("deployer");
    address alice = makeAddr("alice"); // maker (sells TST, wants ETH)
    address bob = makeAddr("bob"); // filler (pays ETH)
    IPoolManager manager;
    AsyncSwap hook;
    Router router;
    MockERC20 erc20;
    Currency currency0; // native (address(0))
    Currency currency1; // erc20
    PoolKey key;
    PoolId poolId;

    function setUp() public {
        manager = new PoolManager(owner);
        erc20 = new MockERC20("Test Token", "TST", 18);

        currency0 = Currency.wrap(address(0));
        currency1 = Currency.wrap(address(erc20));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        deployCodeTo("AsyncSwap.sol", abi.encode(manager), address(flags));
        hook = AsyncSwap(payable(address(flags)));
        router = new Router(manager, hook, ISignatureTransfer(Permit2Bytecode.PERMIT2));

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(1),
            hooks: hook
        });
        poolId = key.toId();
        manager.initialize(key, 2 ** 96);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        erc20.mint(alice, 100 ether);
        erc20.mint(bob, 100 ether);
        vm.prank(alice);
        hook.setExecutor(poolId, address(router), true);
    }

    function _expectedSalt(address user, uint256 amountIn, uint256 amountOutMin) internal view returns (bytes32) {
        return keccak256(abi.encode(block.timestamp, block.number, address(manager), user, amountIn, amountOutMin));
    }

    function _orderIdFor(address maker, bool zeroForOne, bytes32 salt) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, poolId, maker, zeroForOne, salt));
    }

    function _order(address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        internal
        view
        returns (AsyncOrder memory)
    {
        return AsyncOrder({
            key: key,
            owner: maker,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            sqrtPrice: 2 ** 96,
            salt: bytes32(0)
        });
    }

    /// @dev Maker submits a native-OUTPUT order (zeroForOne=false): deposits `amountIn` TST,
    ///      asks `amountOutMin` ETH. Returns the order struct patched with the assigned salt.
    function _createNativeOutputOrder(uint256 amountIn, uint256 amountOutMin)
        internal
        returns (AsyncOrder memory order)
    {
        order = _order(alice, false, amountIn, amountOutMin);
        vm.startPrank(alice);
        erc20.approve(address(router), amountIn);
        router.swap(
            order,
            abi.encode(AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: amountOutMin}))
        );
        vm.stopPrank();
        order.salt = _expectedSalt(alice, amountIn, amountOutMin);
    }

    /* ------------------------------------------------------------------ *
     *  SCENARIO (b): maker front-runs with updatePrice LOWER              *
     * ------------------------------------------------------------------ */

    /// Maker creates an order asking 1 ETH for 1 TST, then front-runs the pending fill by
    /// calling updatePrice to LOWER the live price to 0.6 ETH. Bob's broadcast still carries
    /// the stale (higher) struct amountOutMin = 1 ETH, so his msg.value = 1 ETH. Settlement
    /// only pays the maker the live 0.6 ETH; the 0.4 ETH excess is stranded in the hook.
    function test_H05_frontrunUpdatePrice_excessStranded() public {
        uint256 amountIn = 1 ether;
        uint256 signedPrice = 1 ether; // price the filler saw / broadcast against
        uint256 livePrice = 0.6 ether; // maker's front-run lowered price

        AsyncOrder memory order = _createNativeOutputOrder(amountIn, signedPrice);

        // Maker front-runs: lower the live stored price to 0.6 ETH.
        vm.prank(alice);
        hook.updatePrice(order, livePrice);

        (, uint256 storedOutMin) = hook.asyncOrderInfo(poolId, _orderIdFor(alice, false, order.salt));
        assertEq(storedOutMin, livePrice, "live price lowered");

        uint256 hookBalBefore = address(hook).balance;
        uint256 bobEthBefore = bob.balance;
        uint256 aliceEthBefore = alice.balance;

        emit log_named_uint("hook ETH balance before fill", hookBalBefore);
        emit log_named_uint("filler-supplied price (msg.value)", signedPrice);
        emit log_named_uint("live stored price (settled to maker)", livePrice);

        // Bob broadcasts against the stale higher price; maxPrice disabled so the maker's
        // downward move does NOT trip the maxPrice guard (that guard only blocks UPWARD moves).
        vm.prank(bob);
        router.fillOrder{value: signedPrice}(order, type(uint256).max, "");

        uint256 hookBalAfter = address(hook).balance;
        uint256 excess = signedPrice - livePrice;

        emit log_named_uint("hook ETH balance after fill", hookBalAfter);
        emit log_named_uint("stranded excess in hook", hookBalAfter - hookBalBefore);
        emit log_named_uint("filler ETH spent", bobEthBefore - bob.balance);
        emit log_named_uint("maker ETH received", alice.balance - aliceEthBefore);

        // Filler paid the full stale price.
        assertEq(bobEthBefore - bob.balance, signedPrice, "filler paid full msg.value");
        // Maker received only the live price.
        assertEq(alice.balance - aliceEthBefore, livePrice, "maker received only live price");
        // The excess is now stranded in the hook's raw balance.
        assertEq(hookBalAfter - hookBalBefore, excess, "excess stranded in hook");
        assertGt(hookBalAfter, 0, "hook retains stranded ETH");

        // No recovery path exists: neither filler nor maker can pull the excess back.
        _assertNoRecovery(excess);
    }

    /* ------------------------------------------------------------------ *
     *  SCENARIO (a): filler supplies a struct price ABOVE the live price  *
     * ------------------------------------------------------------------ */

    /// No maker action at all. The order's live price is 0.6 ETH, but the filler broadcasts a
    /// struct whose amountOutMin = 1 ETH (e.g. a stale snapshot). msg.value is validated against
    /// the CALLER-SUPPLIED field, not the live price, so the filler overpays and 0.4 ETH strands.
    function test_H05_staleHigherStructPrice_excessStranded() public {
        uint256 amountIn = 1 ether;
        uint256 livePrice = 0.6 ether;
        uint256 staleHigher = 1 ether;

        // Create the order directly at the live price.
        AsyncOrder memory order = _createNativeOutputOrder(amountIn, livePrice);

        // Filler uses a struct carrying the stale, higher amountOutMin. The orderId does NOT
        // depend on amountOutMin, so the fill still targets the same live order.
        AsyncOrder memory staleOrder = order;
        staleOrder.amountOutMin = staleHigher;

        uint256 hookBalBefore = address(hook).balance;
        uint256 bobEthBefore = bob.balance;
        uint256 aliceEthBefore = alice.balance;

        emit log_named_uint("filler-supplied price (msg.value)", staleHigher);
        emit log_named_uint("live stored price (settled to maker)", livePrice);

        vm.prank(bob);
        router.fillOrder{value: staleHigher}(staleOrder, type(uint256).max, "");

        uint256 excess = staleHigher - livePrice;
        uint256 stranded = address(hook).balance - hookBalBefore;

        emit log_named_uint("stranded excess in hook", stranded);
        emit log_named_uint("filler ETH spent", bobEthBefore - bob.balance);
        emit log_named_uint("maker ETH received", alice.balance - aliceEthBefore);

        assertEq(bobEthBefore - bob.balance, staleHigher, "filler paid full msg.value");
        assertEq(alice.balance - aliceEthBefore, livePrice, "maker received only live price");
        assertEq(stranded, excess, "excess stranded in hook");
        // Filler lost >20% of what they paid to the black hole (0.4 / 1.0 = 40%).
        assertGt(stranded, staleHigher * 20 / 100, "stranded loss exceeds 20% of msg.value");

        _assertNoRecovery(excess);
    }

    /* ------------------------------------------------------------------ *
     *  CONTROL: fair fill, msg.value == live price, nothing stranded      *
     * ------------------------------------------------------------------ */

    function test_H05_control_fairFill_noStranding() public {
        uint256 amountIn = 1 ether;
        uint256 livePrice = 0.9 ether;

        AsyncOrder memory order = _createNativeOutputOrder(amountIn, livePrice);

        uint256 hookBalBefore = address(hook).balance;
        uint256 bobEthBefore = bob.balance;
        uint256 aliceEthBefore = alice.balance;

        emit log_named_uint("filler-supplied price (msg.value)", livePrice);
        emit log_named_uint("live stored price (settled to maker)", livePrice);

        // Fair filler: msg.value == struct amountOutMin == live price.
        vm.prank(bob);
        router.fillOrder{value: livePrice}(order, type(uint256).max, "");

        uint256 stranded = address(hook).balance - hookBalBefore;

        emit log_named_uint("hook ETH balance after fair fill", address(hook).balance);
        emit log_named_uint("stranded excess in hook", stranded);
        emit log_named_uint("filler ETH spent", bobEthBefore - bob.balance);
        emit log_named_uint("maker ETH received", alice.balance - aliceEthBefore);

        assertEq(stranded, 0, "no ETH stranded on a fair fill");
        assertEq(bobEthBefore - bob.balance, livePrice, "filler paid exactly live price");
        assertEq(alice.balance - aliceEthBefore, livePrice, "maker received exactly live price");
    }

    /* ------------------------------------------------------------------ *
     *  FIX: owner sweep recovers the stranded ETH as protocol fees        *
     * ------------------------------------------------------------------ */

    /// After a native-output overpayment strands ETH in the hook, the protocol owner can
    /// recover it via sweep(). msg.sender at deploy time (this test contract) is the owner.
    function test_H05_fix_ownerSweepsStrandedEth() public {
        uint256 amountIn = 1 ether;
        uint256 livePrice = 0.6 ether;
        uint256 staleHigher = 1 ether;

        AsyncOrder memory order = _createNativeOutputOrder(amountIn, livePrice);
        AsyncOrder memory staleOrder = order;
        staleOrder.amountOutMin = staleHigher;

        vm.prank(bob);
        router.fillOrder{value: staleHigher}(staleOrder, type(uint256).max, "");

        uint256 stranded = address(hook).balance;
        assertEq(stranded, staleHigher - livePrice, "0.4 ETH stranded before sweep");

        // Non-owner cannot sweep.
        vm.prank(bob);
        vm.expectRevert(AsyncSwap.NotOwner.selector);
        hook.sweep(currency0, bob);

        // Owner (this test contract, the deployer) sweeps the stranded ETH to a collector.
        address collector = makeAddr("collector");
        assertEq(hook.owner(), address(this), "test contract is owner");
        hook.sweep(currency0, collector);

        assertEq(collector.balance, stranded, "collector received the swept ETH");
        assertEq(address(hook).balance, 0, "hook balance fully swept");
    }

    /* ------------------------------------------------------------------ *
     *  helper: prove the stranded ETH cannot be recovered                 *
     * ------------------------------------------------------------------ */

    /// @dev There is no withdraw/sweep/recover selector in src/. We assert the hook keeps the
    ///      ETH across follow-up interactions and that a follow-up call carrying no value
    ///      cannot pull it out.
    function _assertNoRecovery(uint256 excess) internal {
        uint256 held = address(hook).balance;
        assertGe(held, excess, "hook still holds the stranded ETH");

        // Maker attempts a bare call to the hook to reclaim — no such function, ETH stays.
        vm.prank(alice);
        (bool okA,) = address(hook).call(abi.encodeWithSignature("withdraw()"));
        okA; // ignore
        // Filler attempts the same.
        vm.prank(bob);
        (bool okB,) = address(hook).call(abi.encodeWithSignature("sweep()"));
        okB; // ignore

        assertEq(address(hook).balance, held, "stranded ETH unchanged: no recovery path");
    }
}
