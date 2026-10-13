// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "./SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencyLibrary} from "v4-core/types/Currency.sol";

contract AsyncSwapTest is SetupHook {
    using CurrencyLibrary for Currency;

    address alice = makeAddr("alice"); // maker
    address bob = makeAddr("bob"); // filler

    function setUp() public override {
        super.setUp();
        topUp(alice, 100 ether);
        topUp(bob, 100 ether);
    }

    function _orderFromMaker(address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        internal
        view
        returns (AsyncOrder memory)
    {
        // Submitters pass `salt = bytes32(0)`; the hook assigns the real salt in `_createOrder`.
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

    /// @dev After router.swap, patch `order.salt` to the hook-assigned salt so cancel/fill/updatePrice
    ///      compute the same orderId the hook stored under.
    function _withAssignedSalt(AsyncOrder memory order) internal view returns (AsyncOrder memory) {
        order.salt = _expectedSalt(order.owner, order.amountIn, order.amountOutMin);
        return order;
    }

    /* ------------------------- executor authorization ------------------------- */

    function test_setExecutor_emitsGrant() public {
        address executor = makeAddr("executor");

        vm.expectEmit(true, true, true, true, address(hook));
        emit AsyncSwap.ExecutorSet(poolId, alice, executor, true);
        vm.prank(alice);
        hook.setExecutor(poolId, executor, true);

        assertTrue(hook.isExecutor(poolId, alice, executor), "executor authorized");
    }

    function test_setExecutor_emitsRevocation() public {
        // topUp authorizes the Router for alice during setup.
        vm.expectEmit(true, true, true, true, address(hook));
        emit AsyncSwap.ExecutorSet(poolId, alice, address(router), false);
        vm.prank(alice);
        hook.setExecutor(poolId, address(router), false);

        assertFalse(hook.isExecutor(poolId, alice, address(router)), "executor revoked");
    }

    /* --------------------------------- create --------------------------------- */

    function test_swap_createsOrderWithPrice() public {
        uint256 amountIn = 1 ether;
        uint256 amountOutMin = 0.95 ether;

        AsyncOrder memory order = _orderFromMaker(alice, true, amountIn, amountOutMin);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: amountOutMin}))
        );
        vm.stopPrank();

        bytes32 id = _orderIdFor(alice, true, _expectedSalt(alice, amountIn, amountOutMin));
        (uint256 storedIn, uint256 storedOutMin) = hook.asyncOrderInfo(poolId, id);
        assertEq(storedIn, amountIn, "amountIn stored");
        assertEq(storedOutMin, amountOutMin, "amountOutMin stored");
        assertTrue(hook.isExecutor(poolId, alice, address(router)), "router authorized");
    }

    /* ----------------------------------- fill ---------------------------------- */

    function test_fill_makerReceivesPricedOutput_fillerReceivesInput() public {
        uint256 amountIn = 1 ether;
        uint256 amountOutMin = 0.95 ether;

        AsyncOrder memory order = _orderFromMaker(alice, true, amountIn, amountOutMin);

        // Maker submits.
        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: amountOutMin}))
        );
        vm.stopPrank();

        // Patch salt for the fill leg.
        order = _withAssignedSalt(order);

        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 aliceToken1Before = token1.balanceOf(alice);
        uint256 bobToken0Before = token0.balanceOf(bob);
        uint256 bobToken1Before = token1.balanceOf(bob);

        // Bob fills — must pay amountOutMin of token1 (the maker's output side).
        vm.startPrank(bob);
        token1.approve(address(router), type(uint256).max);
        router.fillOrder(order, type(uint256).max, "");
        vm.stopPrank();

        // Order is gone.
        bytes32 id = _orderIdFor(alice, true, order.salt);
        (uint256 leftIn,) = hook.asyncOrderInfo(poolId, id);
        assertEq(leftIn, 0, "order cleared after full fill");

        // Maker received amountOutMin of REAL token1 — no 6909 withdrawal step needed.
        assertEq(token1.balanceOf(alice) - aliceToken1Before, amountOutMin, "maker received real token1");
        assertEq(manager.balanceOf(alice, currency1.toId()), 0, "maker has no leftover 6909 of currency1");
        // Filler received amountIn of real token0 in exchange.
        assertEq(token0.balanceOf(bob) - bobToken0Before, amountIn, "filler got real token0");
        assertEq(
            bobToken1Before - token1.balanceOf(bob),
            amountOutMin + hook.calculatePoolFee(key.fee, amountOutMin),
            "filler paid token1"
        );
        assertEq(aliceToken0Before, token0.balanceOf(alice), "maker token0 unchanged post-fill");
    }

    function test_fill_revertsWhenOrderMissing() public {
        AsyncOrder memory order = _orderFromMaker(alice, true, 1 ether, 1 ether);
        vm.startPrank(bob);
        token1.approve(address(router), type(uint256).max);
        // Router is alice's executor (topUp grants it), but the order itself
        // was never created — fall through to OrderNotFound.
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        router.fillOrder(order, type(uint256).max, "");
        vm.stopPrank();
    }

    /* ----------------------------- update price ----------------------------- */

    function test_updatePrice_makerCanRaisePrice() public {
        uint256 amountIn = 1 ether;
        AsyncOrder memory order = _orderFromMaker(alice, true, amountIn, 0.9 ether);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order, abi.encode(AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.9 ether}))
        );
        // Patch salt before updatePrice.
        order = _withAssignedSalt(order);
        // Now raise the limit price — filler must pay more.
        hook.updatePrice(order, 1.2 ether);
        vm.stopPrank();

        bytes32 id = _orderIdFor(alice, true, order.salt);
        (, uint256 outMin) = hook.asyncOrderInfo(poolId, id);
        assertEq(outMin, 1.2 ether);
    }

    function test_updatePrice_revertsForNonOwner() public {
        uint256 amountIn = 1 ether;
        AsyncOrder memory order = _orderFromMaker(alice, true, amountIn, 0.9 ether);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order, abi.encode(AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.9 ether}))
        );
        vm.stopPrank();

        order = _withAssignedSalt(order);

        vm.prank(bob);
        vm.expectRevert(AsyncFiller.NotOrderOwner.selector);
        hook.updatePrice(order, 1.2 ether);
    }

    /* -------------------------------- cancel -------------------------------- */

    function test_cancel_makerReclaimsInput() public {
        uint256 amountIn = 1 ether;
        AsyncOrder memory order = _orderFromMaker(alice, true, amountIn, 0.9 ether);

        uint256 aliceToken0Before = token0.balanceOf(alice);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order, abi.encode(AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.9 ether}))
        );
        order = _withAssignedSalt(order);
        router.cancelOrder(order);
        vm.stopPrank();

        bytes32 id = _orderIdFor(alice, true, order.salt);
        (uint256 leftIn,) = hook.asyncOrderInfo(poolId, id);
        assertEq(leftIn, 0, "order deleted");
        // Maker reclaimed REAL input tokens — net zero on token0 balance, no 6909 left over.
        assertEq(token0.balanceOf(alice), aliceToken0Before, "maker reclaimed real input");
        assertEq(manager.balanceOf(alice, currency0.toId()), 0, "no leftover 6909 of currency0");
    }

    function test_cancel_revertsForNonOwner() public {
        AsyncOrder memory order = _orderFromMaker(alice, true, 1 ether, 0.9 ether);
        vm.prank(bob);
        vm.expectRevert("Only owner can cancel");
        router.cancelOrder(order);
    }

    /* ----------------------------- reverse direction ----------------------------- */

    function test_fill_reverseDirection_token1ForToken0() public {
        uint256 amountIn = 2 ether;
        uint256 amountOutMin = 1.8 ether;

        AsyncOrder memory order = _orderFromMaker(alice, false, amountIn, amountOutMin);

        vm.startPrank(alice);
        token1.approve(address(router), type(uint256).max);
        router.swap(
            order,
            abi.encode(AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: amountOutMin}))
        );
        vm.stopPrank();

        order = _withAssignedSalt(order);

        uint256 bobToken0Before = token0.balanceOf(bob);
        uint256 bobToken1Before = token1.balanceOf(bob);
        uint256 aliceToken0Before = token0.balanceOf(alice);

        vm.startPrank(bob);
        token0.approve(address(router), type(uint256).max);
        router.fillOrder(order, type(uint256).max, "");
        vm.stopPrank();

        // Maker received real currency0 (the maker's chosen output); filler paid currency0 and
        // received currency1 (the maker's input).
        assertEq(token0.balanceOf(alice) - aliceToken0Before, amountOutMin, "maker received real token0");
        assertEq(
            bobToken0Before - token0.balanceOf(bob),
            amountOutMin + hook.calculatePoolFee(key.fee, amountOutMin),
            "filler paid token0"
        );
        assertEq(token1.balanceOf(bob) - bobToken1Before, amountIn, "filler received token1");
    }

    /* ------------------------- multiple orders per maker ------------------------- */

    function test_swap_twoOrdersSameMaker_distinctSalts() public {
        // Distinct (amountIn, amountOutMin) tuples => distinct salts => distinct orderIds.
        AsyncOrder memory o1 = _orderFromMaker(alice, true, 1 ether, 0.9 ether);
        AsyncOrder memory o2 = _orderFromMaker(alice, true, 0.5 ether, 0.45 ether);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            o1, abi.encode(AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.9 ether}))
        );
        token0.approve(address(router), type(uint256).max);
        router.swap(
            o2, abi.encode(AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.45 ether}))
        );
        vm.stopPrank();

        bytes32 id1 = _orderIdFor(alice, true, _expectedSalt(alice, 1 ether, 0.9 ether));
        bytes32 id2 = _orderIdFor(alice, true, _expectedSalt(alice, 0.5 ether, 0.45 ether));
        (uint256 in1,) = hook.asyncOrderInfo(poolId, id1);
        (uint256 in2,) = hook.asyncOrderInfo(poolId, id2);
        assertEq(in1, 1 ether, "order 1 stored");
        assertEq(in2, 0.5 ether, "order 2 stored");
    }

    /// @notice With contract-assigned salts, duplicate (user, amountIn, amountOutMin) tuples in the
    ///         same block trigger the in-contract salt-walk: the second order lands on a re-hashed
    ///         salt rather than colliding. Both submissions must succeed and produce distinct ids.
    function test_swap_duplicateParamsTriggerSaltWalk() public {
        AsyncOrder memory order = _orderFromMaker(alice, true, 1 ether, 0.9 ether);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order, abi.encode(AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.9 ether}))
        );
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order, abi.encode(AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.9 ether}))
        );
        vm.stopPrank();

        // First salt = base prediction; second salt = keccak256(firstSalt) per the walk.
        bytes32 firstSalt = _expectedSalt(alice, 1 ether, 0.9 ether);
        bytes32 secondSalt = keccak256(abi.encode(firstSalt));
        bytes32 id1 = _orderIdFor(alice, true, firstSalt);
        bytes32 id2 = _orderIdFor(alice, true, secondSalt);
        assertTrue(id1 != id2, "salt-walk produced distinct ids");
        (uint256 in1,) = hook.asyncOrderInfo(poolId, id1);
        (uint256 in2,) = hook.asyncOrderInfo(poolId, id2);
        assertEq(in1, 1 ether, "first order stored");
        assertEq(in2, 1 ether, "second order stored after salt walk");
    }

    /* ----------------------- updated price affects fill ----------------------- */

    function test_fill_usesUpdatedPrice() public {
        uint256 amountIn = 1 ether;
        AsyncOrder memory order = _orderFromMaker(alice, true, amountIn, 0.8 ether);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order, abi.encode(AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.8 ether}))
        );
        order = _withAssignedSalt(order);
        // Maker raises price after submission.
        hook.updatePrice(order, 1.1 ether);
        vm.stopPrank();

        uint256 bobToken1Before = token1.balanceOf(bob);
        uint256 aliceToken1Before = token1.balanceOf(alice);
        vm.startPrank(bob);
        token1.approve(address(router), type(uint256).max);
        router.fillOrder(order, type(uint256).max, "");
        vm.stopPrank();

        // Filler paid the *updated* 1.1 ether, not the original 0.8 ether.
        assertEq(
            bobToken1Before - token1.balanceOf(bob),
            1.1 ether + hook.calculatePoolFee(key.fee, 1.1 ether),
            "filler paid updated price"
        );
        assertEq(token1.balanceOf(alice) - aliceToken1Before, 1.1 ether, "maker received updated price");
    }

    /* -------------------- ordering invariants after cancel -------------------- */

    function test_fill_revertsAfterCancel() public {
        uint256 amountIn = 1 ether;
        AsyncOrder memory order = _orderFromMaker(alice, true, amountIn, 0.9 ether);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order, abi.encode(AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.9 ether}))
        );
        order = _withAssignedSalt(order);
        router.cancelOrder(order);
        vm.stopPrank();

        // Now Bob tries to fill — order is gone.
        vm.startPrank(bob);
        token1.approve(address(router), type(uint256).max);
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        router.fillOrder(order, type(uint256).max, "");
        vm.stopPrank();
    }

    function test_cancel_revertsAfterFill() public {
        uint256 amountIn = 1 ether;
        AsyncOrder memory order = _orderFromMaker(alice, true, amountIn, 0.9 ether);

        vm.startPrank(alice);
        token0.approve(address(router), type(uint256).max);
        router.swap(
            order, abi.encode(AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: 0.9 ether}))
        );
        vm.stopPrank();

        order = _withAssignedSalt(order);

        vm.startPrank(bob);
        token1.approve(address(router), type(uint256).max);
        router.fillOrder(order, type(uint256).max, "");
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(AsyncFiller.OrderNotFound.selector);
        router.cancelOrder(order);
    }
}
