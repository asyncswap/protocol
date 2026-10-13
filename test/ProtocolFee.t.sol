// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;
import {AsyncOrder} from "src/types/AsyncOrder.sol";
import {AsyncSwap} from "src/AsyncSwap.sol";
import {SetupHook} from "./SetupHook.t.sol";

contract ProtocolFeeTest is SetupHook {
    function test_fillSplitsHundredUsdcAndPaysFullInput() public {
        address maker = makeAddr("maker");
        address filler = makeAddr("filler");
        topUp(maker, 1 ether);
        topUp(filler, 100_000_000);
        AsyncOrder memory order = AsyncOrder(key, maker, true, 1 ether, 99_700_000, 2 ** 96, bytes32(0));
        vm.startPrank(maker);
        token0.approve(address(router), 1 ether);
        router.swap(order, abi.encode(AsyncSwap.UserParams(maker, address(router), 99_700_000)));
        vm.stopPrank();
        order.salt = _expectedSalt(maker, 1 ether, 99_700_000);
        uint256 makerBefore = token1.balanceOf(maker);
        uint256 fillerBefore = token0.balanceOf(filler);
        vm.startPrank(filler);
        token1.approve(address(router), 100_000_000);
        vm.expectRevert("Price exceeds maxPrice");
        router.fillOrder(order, 99_700_000, "");
        assertEq(token1.balanceOf(filler), 100_000_000);
        router.fillOrder(order, 100_000_000, "");
        vm.stopPrank();
        assertEq(token1.balanceOf(maker) - makerBefore, 99_700_000);
        assertEq(token0.balanceOf(filler) - fillerBefore, 1 ether);
        assertEq(token1.balanceOf(filler), 0);
        assertEq(manager.balanceOf(address(hook.feeVault()), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook.feeVault()), currency1.toId()), 300_000);
    }

    function test_feeIsPointThreePercent() public view {
        assertEq(hook.calculatePoolFee(0x800000, 0.997 ether), 0.003 ether);
        assertEq(hook.calculatePoolFee(0x800000, 997_000), 3_000);
    }

    function test_feeRoundsDownAtSmallestUnit() public view {
        assertEq(hook.calculatePoolFee(0x800000, 332), 0);
        assertEq(hook.calculatePoolFee(0x800000, 333), 1);
        assertEq(hook.calculatePoolFee(0x800000, 664), 1);
    }

    function testFuzz_feeIsPointThreePercentOfGross(uint128 net) public view {
        uint256 fee = hook.calculatePoolFee(0x800000, net);
        uint256 gross = uint256(net) + fee;
        assertEq(fee, (gross * 3) / 1_000);
        assertEq(gross - fee, net);
    }

    function testFuzz_feeCannotOverflow(uint256 amount) public view {
        uint256 fee = hook.calculatePoolFee(0x800000, amount);
        assertEq(fee, (amount / 997) * 3 + ((amount % 997) * 3) / 997);
        assertLe(fee, amount);
    }
}
