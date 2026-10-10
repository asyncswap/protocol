// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";

contract H04_NatspecMismatchTest is SetupHook {
    address alice = makeAddr("alice"); // maker (follows NatSpec)
    address bob = makeAddr("bob"); // any filler

    function setUp() public override {
        super.setUp();
        topUp(alice, 100 ether);
        topUp(bob, 100 ether);
    }

    function test_RevertWhen_H04_UserDataDivergesFromOrder() public {
        uint256 amountIn = 1 ether;
        uint256 placeholder = 1;
        uint256 realLimit = 1000 ether;

        AsyncOrder memory order = AsyncOrder({
            key: key,
            owner: alice,
            zeroForOne: true,
            amountIn: amountIn,
            amountOutMin: placeholder,
            sqrtPrice: 2 ** 96,
            salt: bytes32(0)
        });

        vm.startPrank(alice);
        token0.approve(address(router), amountIn);
        vm.expectRevert();
        router.swap(
            order, abi.encode(AsyncSwap.UserParams({user: alice, executor: address(router), amountOutMin: realLimit}))
        );
        vm.stopPrank();
    }
}
