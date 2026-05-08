// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

contract Attacker is IUnlockCallback {
    using CurrencySettler for Currency;
    IPoolManager public immutable manager;
    AsyncSwap public immutable hook;
    address public victim;
    PoolKey public poolKey;
    AsyncOrder public victimOrder;
    uint64 public forgedNonce;

    constructor(IPoolManager _manager, AsyncSwap _hook) {
        manager = _manager;
        hook = _hook;
    }

    function attack(address _victim, PoolKey calldata _key, AsyncOrder calldata _victimOrder, uint64 _forgedNonce)
        external
    {
        victim = _victim;
        poolKey = _key;
        victimOrder = _victimOrder;
        forgedNonce = _forgedNonce;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "only PM");
        bool zeroForOne = victimOrder.zeroForOne;
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -1,
            sqrtPriceLimitX96: zeroForOne
                ? uint160(4295128740)
                : uint160(1461446703485210103287273052203988822378723970341)
        });
        manager.swap(
            poolKey,
            sp,
            abi.encode(
                AsyncSwap.UserParams({user: victim, executor: address(this), amountOutMin: 1, nonce: forgedNonce})
            )
        );
        Currency input = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        input.settle(manager, address(this), 1, false);

        Currency output = victimOrder.zeroForOne ? poolKey.currency1 : poolKey.currency0;
        IERC20Minimal(Currency.unwrap(output)).transfer(address(hook), victimOrder.amountOutMin);
        hook.executeOrder(victimOrder, abi.encode(address(this)));
        return "";
    }
}

contract H02_ExecutorForgeryTest is SetupHook {
    address victim = makeAddr("victim");

    function setUp() public override {
        super.setUp();
        topUp(victim, 100 ether);
    }

    function test_RevertWhen_H02_HookDataForgedFromUntrustedUnlock() public {
        uint256 amountIn = 5 ether;
        uint256 amountOutMin = 4.5 ether;
        AsyncOrder memory victimOrder = AsyncOrder({
            key: key,
            owner: victim,
            zeroForOne: true,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            sqrtPrice: 2 ** 96,
            nonce: 0
        });

        vm.startPrank(victim);
        token0.approve(address(router), amountIn);
        router.swap(
            victimOrder,
            abi.encode(
                AsyncSwap.UserParams({user: victim, executor: address(router), amountOutMin: amountOutMin, nonce: 0})
            )
        );
        vm.stopPrank();

        Attacker attacker = new Attacker(manager, hook);
        topUp(address(attacker), amountOutMin + 1);

        vm.expectRevert();
        attacker.attack(
            victim,
            key,
            victimOrder,
            /* forgedNonce */
            99
        );
    }
}
