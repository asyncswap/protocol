// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";

contract H04_NatspecMismatchTest is SetupHook {
    address alice = makeAddr("alice"); // maker (follows NatSpec)
    address bob = makeAddr("bob");     // any filler

    function setUp() public override {
        super.setUp();
        topUp(alice, 100 ether);
        topUp(bob, 100 ether);
    }

    function _orderId(address maker, bool zeroForOne, uint64 nonce) internal view returns (bytes32) {
        return keccak256(abi.encode(poolId, maker, zeroForOne, nonce));
    }

    function test_RevertWhen_H04_UserDataDivergesFromOrder() public {
        uint256 amountIn = 1 ether;
        uint256 placeholder = 1;
        uint256 realLimit = 1000 ether;

        AsyncOrder memory order = AsyncOrder({
            key: key, owner: alice, zeroForOne: true,
            amountIn: amountIn, amountOutMin: placeholder,
            sqrtPrice: 2 ** 96, nonce: 0
        });

        vm.startPrank(alice);
        token0.approve(address(router), amountIn);
        vm.expectRevert();
        router.swap(order, abi.encode(AsyncSwap.UserParams({
            user: alice, executor: address(router),
            amountOutMin: realLimit, nonce: 0
        })));
        vm.stopPrank();
    }
}
