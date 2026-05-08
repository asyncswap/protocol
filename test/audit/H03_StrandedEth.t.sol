// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

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

contract H03_StrandedEthTest is Test {
    using PoolIdLibrary for PoolKey;

    address owner = makeAddr("deployer");
    address victim = makeAddr("victim");
    address attacker = makeAddr("attacker");
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
        router = new Router(manager, hook);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(1),
            hooks: hook
        });
        poolId = key.toId();
        manager.initialize(key, 2 ** 96);

        vm.deal(victim, 100 ether);
        vm.deal(attacker, 0); // attacker MUST start with no ETH
        vm.prank(victim);
        hook.setExecutor(poolId, address(router), true);
        vm.prank(attacker);
        hook.setExecutor(poolId, address(router), true);
    }

    function _order(address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin, uint64 nonce)
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
            nonce: nonce
        });
    }

    function test_RevertWhen_H03_NativeInputSwapWithMismatchedMsgValue() public {
        // Victim's overpay path is now itself blocked at the Router (the same
        // fix protects symmetrically), so we assert directly that an attacker
        // attempting a native-input swap with msg.value != amountIn reverts.
        AsyncOrder memory atkOrder = _order(attacker, true, 1 ether, 1 wei, 7);
        vm.startPrank(attacker);
        vm.expectRevert();
        router.swap{value: 0}(
            atkOrder,
            abi.encode(AsyncSwap.UserParams({user: attacker, executor: address(router), amountOutMin: 1 wei, nonce: 7}))
        );
        vm.stopPrank();
    }
}
