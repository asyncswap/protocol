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

/// @notice H05 regression: native fills must pay the live price exactly. Stale or
/// inflated deposits revert atomically, so the filler cannot strand an overpayment.
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
        erc20.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: amountOutMin}))
        );
        vm.stopPrank();
        order.salt = _expectedSalt(alice, amountIn, amountOutMin);
    }

    function _assertRejectedFill(AsyncOrder memory order, uint256 value) internal {
        uint256 fillerBefore = bob.balance;
        uint256 makerBefore = alice.balance;
        uint256 hookBefore = address(hook).balance;
        uint256 routerBefore = address(router).balance;
        bytes32 id = _orderIdFor(alice, false, order.salt);
        (uint256 inputBefore, uint256 priceBefore) = hook.asyncOrderInfo(poolId, id);
        vm.prank(bob);
        vm.expectRevert("msg.value != livePrice");
        router.fillOrder{value: value}(order, type(uint256).max, "");
        assertEq(bob.balance, fillerBefore, "filler keeps deposit");
        assertEq(alice.balance, makerBefore, "maker receives nothing");
        assertEq(address(hook).balance, hookBefore, "hook balance unchanged");
        assertEq(address(router).balance, routerBefore, "router balance unchanged");
        (uint256 inputAfter, uint256 priceAfter) = hook.asyncOrderInfo(poolId, id);
        assertEq(inputAfter, inputBefore, "order remains open");
        assertEq(priceAfter, priceBefore, "price unchanged");
    }

    function test_H05_loweredPrice_rejectsStaleDeposit() public {
        AsyncOrder memory order = _createNativeOutputOrder(1 ether, 1 ether);
        vm.prank(alice);
        hook.updatePrice(order, 0.6 ether);
        _assertRejectedFill(order, 1 ether);
    }

    function test_H05_inflatedStructPrice_rejectsOverpayment() public {
        AsyncOrder memory order = _createNativeOutputOrder(1 ether, 0.6 ether);
        order.amountOutMin = 1 ether;
        _assertRejectedFill(order, 1 ether);
    }

    function test_H05_underpayment_cannotConsumeDonatedEth() public {
        AsyncOrder memory order = _createNativeOutputOrder(1 ether, 1 ether);
        vm.deal(address(hook), 10 ether);
        _assertRejectedFill(order, 0.6 ether);
    }

    function testFuzz_H05_overpaymentReverts(uint96 excess) public {
        vm.assume(excess > 0);
        AsyncOrder memory order = _createNativeOutputOrder(1 ether, 0.6 ether);
        uint256 payment = 0.6 ether + uint256(excess);
        vm.deal(bob, payment);
        order.amountOutMin = payment;
        _assertRejectedFill(order, payment);
    }

    function test_H05_exactLivePrice_succeedsWithStaleStruct() public {
        AsyncOrder memory order = _createNativeOutputOrder(1 ether, 1 ether);
        vm.prank(alice);
        hook.updatePrice(order, 0.6 ether);
        uint256 fillerBefore = bob.balance;
        uint256 makerBefore = alice.balance;
        uint256 tokensBefore = erc20.balanceOf(bob);
        uint256 fee = hook.calculatePoolFee(order.key.fee, 0.6 ether);
        vm.prank(bob);
        router.fillOrder{value: 0.6 ether + fee}(order, 1 ether, "");
        assertEq(fillerBefore - bob.balance, 0.6 ether + fee, "filler pays live price");
        assertEq(alice.balance - makerBefore, 0.6 ether, "maker receives live price");
        assertEq(erc20.balanceOf(bob) - tokensBefore, 1 ether, "filler receives input");
        assertEq(address(hook).balance, 0, "no stranded ETH");
        assertEq(address(router).balance, 0, "no stranded ETH in router");
        (uint256 remaining,) = hook.asyncOrderInfo(poolId, _orderIdFor(alice, false, order.salt));
        assertEq(remaining, 0, "order consumed");
    }

    function test_H05_livePriceAboveMax_revertsAtomically() public {
        AsyncOrder memory order = _createNativeOutputOrder(1 ether, 1 ether);
        uint256 fillerBefore = bob.balance;
        uint256 fee = hook.calculatePoolFee(order.key.fee, 1 ether);
        vm.prank(bob);
        vm.expectRevert("Price exceeds maxPrice");
        router.fillOrder{value: 1 ether + fee}(order, 0.6 ether, "");
        assertEq(bob.balance, fillerBefore);
        assertEq(address(hook).balance, 0);
        (uint256 remaining,) = hook.asyncOrderInfo(poolId, _orderIdFor(alice, false, order.salt));
        assertEq(remaining, 1 ether);
    }

    function test_H05_control_fairFill_noStranding() public {
        AsyncOrder memory order = _createNativeOutputOrder(1 ether, 0.9 ether);
        uint256 makerBefore = alice.balance;
        uint256 fee = hook.calculatePoolFee(order.key.fee, 0.9 ether);
        vm.prank(bob);
        router.fillOrder{value: 0.9 ether + fee}(order, 0.9 ether + fee, "");
        assertEq(alice.balance - makerBefore, 0.9 ether);
        assertEq(address(hook).balance, 0);
        assertEq(address(router).balance, 0);
    }

    function test_ownerSweep_recoversDonationsWithoutTouchingOpenOrder() public {
        AsyncOrder memory order = _createNativeOutputOrder(1 ether, 0.9 ether);
        vm.deal(address(hook), 0.4 ether);
        address collector = makeAddr("collector");
        vm.prank(bob);
        vm.expectRevert(AsyncSwap.NotOwner.selector);
        hook.sweep(currency0, collector);
        vm.prank(hook.owner());
        hook.sweep(currency0, collector);
        assertEq(collector.balance, 0.4 ether);
        assertEq(address(hook).balance, 0);
        uint256 fee = hook.calculatePoolFee(order.key.fee, 0.9 ether);
        vm.prank(bob);
        router.fillOrder{value: 0.9 ether + fee}(order, 0.9 ether + fee, "");
    }

    function test_L02_nativeInput_rejectsMismatchedOwner() public {
        AsyncOrder memory order = _order(bob, true, 1 ether, 0.9 ether);
        uint256 makerBefore = alice.balance;
        vm.prank(alice);
        vm.expectRevert("Only owner can swap");
        router.swap{value: 1 ether}(
            order, abi.encode(AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.9 ether}))
        );
        assertEq(alice.balance, makerBefore);
        assertEq(address(router).balance, 0);
    }
}
