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

/// @notice H06 (secondary): native-transfer reentrancy in fill/cancel is MITIGATED.
///
/// AsyncFiller.fill/cancel perform the PoolManager `take` of native currency (a raw call with
/// all remaining gas) to `order.owner` / `filler` AFTER `delete self.orders[id]` (CEI). When the
/// recipient is a malicious contract, its receive() fires mid-settlement and attempts to re-enter:
///   - router.swap / fillOrder / cancelOrder -> POOLMANAGER.unlock -> reverts (already unlocked)
///   - hook.executeOrder directly            -> reverts (order deleted / PENDING ledger short)
///
/// The malicious recipient swallows the failed re-entry (low-level call) so the outer settlement
/// still succeeds; we then assert no double-spend occurred and every re-entry attempt failed.
contract MaliciousActor {
    Router public router;
    AsyncSwap public hook;
    PoolKey public key;
    PoolId public poolId;
    MockERC20 public erc20;

    AsyncOrder public reentryOrder;
    bool public armed;
    uint256 public reentryAttempts;
    uint256 public reentrySuccesses;

    constructor(Router _router, AsyncSwap _hook, PoolKey memory _key, MockERC20 _erc20) {
        router = _router;
        hook = _hook;
        key = _key;
        poolId = PoolIdLibrary.toId(_key);
        erc20 = _erc20;
        hook.setExecutor(poolId, address(_router), true);
    }

    function approveRouter(uint256 amt) external {
        erc20.approve(address(router), type(uint256).max);
    }

    /// Submit a native-INPUT order (zeroForOne=true): deposit `amountIn` ETH, ask `amountOutMin` TST.
    function submitNativeInput(uint256 amountIn, uint256 amountOutMin) external {
        AsyncOrder memory o = _order(true, amountIn, amountOutMin);
        router.swap{value: amountIn}(
            o,
            abi.encode(
                AsyncSwap.UserParams({user: address(this), executor: address(router), amountOutMin: amountOutMin})
            )
        );
    }

    /// Submit a native-OUTPUT order (zeroForOne=false): deposit `amountIn` TST, ask `amountOutMin` ETH.
    function submitNativeOutput(uint256 amountIn, uint256 amountOutMin) external {
        AsyncOrder memory o = _order(false, amountIn, amountOutMin);
        router.swap(
            o,
            abi.encode(
                AsyncSwap.UserParams({user: address(this), executor: address(router), amountOutMin: amountOutMin})
            )
        );
    }

    function arm(AsyncOrder calldata o) external {
        reentryOrder = o;
        armed = true;
    }

    function cancel(AsyncOrder calldata o) external {
        router.cancelOrder(o);
    }

    function _order(bool zeroForOne, uint256 amountIn, uint256 amountOutMin) internal view returns (AsyncOrder memory) {
        return AsyncOrder({
            key: key,
            owner: address(this),
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            sqrtPrice: 2 ** 96,
            salt: bytes32(0)
        });
    }

    /// Fires when the hook pays this contract native ETH mid fill/cancel. Attempts to re-enter
    /// and double-spend. All attempts are expected to fail; we record and swallow them.
    receive() external payable {
        if (!armed) return;
        armed = false; // single-shot to avoid unbounded recursion

        AsyncOrder memory o = reentryOrder;

        // 1) Re-enter cancel of the same (now-deleted) order to reclaim input again.
        reentryAttempts++;
        (bool ok1,) = address(router).call(abi.encodeWithSelector(Router.cancelOrder.selector, o));
        if (ok1) reentrySuccesses++;

        // 2) Re-enter fillOrder while PM is still unlocked.
        reentryAttempts++;
        (bool ok2,) =
            address(router).call(abi.encodeWithSelector(Router.fillOrder.selector, o, type(uint256).max, bytes("")));
        if (ok2) reentrySuccesses++;

        // 3) Re-enter executeOrder directly on the hook.
        reentryAttempts++;
        (bool ok3,) =
            address(hook).call(abi.encodeWithSelector(AsyncSwap.executeOrder.selector, o, abi.encode(address(this))));
        if (ok3) reentrySuccesses++;
    }
}

contract H06_NativeReentrancyDefenseTest is Test {
    using PoolIdLibrary for PoolKey;

    address owner = makeAddr("deployer");
    address bob = makeAddr("bob"); // honest filler
    IPoolManager manager;
    AsyncSwap hook;
    Router router;
    MockERC20 erc20;
    Currency currency0;
    Currency currency1;
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
        deployCodeTo("AsyncSwap.sol", abi.encode(manager, currency1, address(this)), address(flags));
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

        vm.deal(bob, 100 ether);
        erc20.mint(bob, 100 ether);
    }

    function _expectedSalt(address user, uint256 amountIn, uint256 amountOutMin) internal view returns (bytes32) {
        return keccak256(abi.encode(block.timestamp, block.number, address(manager), user, amountIn, amountOutMin));
    }

    /* ------------------------------------------------------------------ *
     *  Reentrancy on native-OUTPUT fill (maker receives ETH)             *
     * ------------------------------------------------------------------ */

    function test_H06_reentrancyOnFill_blocked() public {
        MaliciousActor maker = new MaliciousActor(router, hook, key, erc20);
        erc20.mint(address(maker), 10 ether);
        vm.prank(address(maker));
        maker.approveRouter(10 ether);

        uint256 amountIn = 1 ether; // TST in
        uint256 amountOutMin = 0.9 ether; // ETH out

        vm.prank(address(maker));
        maker.submitNativeOutput(amountIn, amountOutMin);

        AsyncOrder memory order = AsyncOrder({
            key: key,
            owner: address(maker),
            zeroForOne: false,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            sqrtPrice: 2 ** 96,
            salt: _expectedSalt(address(maker), amountIn, amountOutMin)
        });
        maker.arm(order);

        uint256 makerEthBefore = address(maker).balance;
        uint256 fee = hook.calculatePoolFee(order.key.fee, amountOutMin);

        // Honest fill; the malicious maker's receive() will try to re-enter.
        vm.prank(bob);
        router.fillOrder{value: amountOutMin + fee}(order, type(uint256).max, "");

        emit log_named_uint("reentry attempts", maker.reentryAttempts());
        emit log_named_uint("reentry successes", maker.reentrySuccesses());
        emit log_named_uint("maker ETH received", address(maker).balance - makerEthBefore);

        // Defense holds: every re-entry attempt failed, maker paid out exactly once.
        assertGt(maker.reentryAttempts(), 0, "receive() ran and attempted re-entry");
        assertEq(maker.reentrySuccesses(), 0, "all re-entries reverted");
        assertEq(address(maker).balance - makerEthBefore, amountOutMin, "maker paid exactly once, no double-spend");

        // Order is gone.
        bytes32 id = keccak256(abi.encode(block.chainid, poolId, address(maker), false, order.salt));
        (uint256 leftIn,) = hook.asyncOrderInfo(poolId, id);
        assertEq(leftIn, 0, "order consumed exactly once");
    }

    /* ------------------------------------------------------------------ *
     *  Reentrancy on native-INPUT cancel (maker receives ETH back)       *
     * ------------------------------------------------------------------ */

    function test_H06_reentrancyOnCancel_blocked() public {
        MaliciousActor maker = new MaliciousActor(router, hook, key, erc20);
        vm.deal(address(maker), 5 ether);

        uint256 amountIn = 1 ether; // ETH in
        uint256 amountOutMin = 0.9 ether; // TST out (unused; we cancel)

        vm.prank(address(maker));
        maker.submitNativeInput(amountIn, amountOutMin);

        AsyncOrder memory order = AsyncOrder({
            key: key,
            owner: address(maker),
            zeroForOne: true,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            sqrtPrice: 2 ** 96,
            salt: _expectedSalt(address(maker), amountIn, amountOutMin)
        });
        maker.arm(order);

        uint256 makerEthBefore = address(maker).balance;

        // Cancel returns the 1 ETH input to the maker; receive() attempts to re-enter.
        vm.prank(address(maker));
        maker.cancel(order);

        emit log_named_uint("reentry attempts", maker.reentryAttempts());
        emit log_named_uint("reentry successes", maker.reentrySuccesses());
        emit log_named_uint("maker ETH reclaimed", address(maker).balance - makerEthBefore);

        assertGt(maker.reentryAttempts(), 0, "receive() ran and attempted re-entry");
        assertEq(maker.reentrySuccesses(), 0, "all re-entries reverted");
        assertEq(address(maker).balance - makerEthBefore, amountIn, "reclaimed input exactly once, no double-spend");

        bytes32 id = keccak256(abi.encode(block.chainid, poolId, address(maker), true, order.salt));
        (uint256 leftIn,) = hook.asyncOrderInfo(poolId, id);
        assertEq(leftIn, 0, "order cancelled exactly once");
    }

    /* ------------------------------------------------------------------ *
     *  CONTROL: honest maker (EOA) fills/cancels with no re-entry         *
     * ------------------------------------------------------------------ */

    function test_H06_control_honestFill_succeeds() public {
        address alice = makeAddr("alice");
        vm.deal(alice, 100 ether);
        erc20.mint(alice, 100 ether);
        vm.prank(alice);
        hook.setExecutor(poolId, address(router), true);

        uint256 amountIn = 1 ether;
        uint256 amountOutMin = 0.9 ether;

        AsyncOrder memory order = AsyncOrder({
            key: key,
            owner: alice,
            zeroForOne: false,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            sqrtPrice: 2 ** 96,
            salt: bytes32(0)
        });

        vm.startPrank(alice);
        erc20.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: amountOutMin}))
        );
        vm.stopPrank();
        order.salt = _expectedSalt(alice, amountIn, amountOutMin);

        uint256 aliceEthBefore = alice.balance;
        uint256 fee = hook.calculatePoolFee(order.key.fee, amountOutMin);
        vm.prank(bob);
        router.fillOrder{value: amountOutMin + fee}(order, type(uint256).max, "");

        emit log_named_uint("maker ETH received", alice.balance - aliceEthBefore);
        assertEq(alice.balance - aliceEthBefore, amountOutMin, "honest fill pays maker exactly the live price");
        assertEq(address(hook).balance, 0, "no stranded ETH on fair honest fill");
    }
}
