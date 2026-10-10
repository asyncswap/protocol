// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";

contract H01_MakerFrontrunTest is SetupHook {
    address alice = makeAddr("alice"); // maker (attacker)
    address bob = makeAddr("bob"); // filler (victim)

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

    function test_RevertWhen_H01_FillerProtectionViolated() public {
        uint256 amountIn = 1e18;
        uint256 originalOutMin = 0.8e18;
        uint256 frontrunOutMin = 1.1e18;

        AsyncOrder memory order = _orderFromMaker(alice, true, amountIn, originalOutMin);

        vm.startPrank(alice);
        token0.approve(address(router), amountIn);
        router.swap(
            order,
            abi.encode(AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: originalOutMin}))
        );
        vm.stopPrank();

        // Resolve the hook-assigned salt so subsequent updatePrice/fillOrder hit the right id.
        order.salt = _expectedSalt(alice, amountIn, originalOutMin);

        vm.prank(bob);
        token1.approve(address(router), 2e18);

        vm.prank(alice);
        hook.updatePrice(order, frontrunOutMin);

        vm.prank(bob);
        vm.expectRevert();
        router.fillOrder(order, originalOutMin, "");
    }
}
