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

contract C01_CommingledEscrowTest is Test {
    using PoolIdLibrary for PoolKey;

    address owner = makeAddr("deployer");
    address attacker = makeAddr("attacker");
    IPoolManager manager;
    AsyncSwap hook;
    Router router;
    MockERC20 erc20;
    Currency currency0; // native
    Currency currency1; // ERC20
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

        vm.deal(attacker, 1 ether);
        erc20.mint(attacker, 1);
        vm.prank(attacker);
        hook.setExecutor(poolId, address(router), true);
    }

    function _order(address ownerAddr, bool zeroForOne, uint256 amountIn, uint256 amountOutMin, uint64 nonce)
        internal
        view
        returns (AsyncOrder memory)
    {
        return AsyncOrder({
            key: key,
            owner: ownerAddr,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            sqrtPrice: 2 ** 96,
            nonce: nonce
        });
    }

    function test_RevertWhen_C01_FillerDoesNotDepositNativeOutput() public {
        uint256 STRANDED = 10 ether;
        vm.deal(address(hook), STRANDED);

        AsyncOrder memory order =
            _order({ownerAddr: attacker, zeroForOne: false, amountIn: 1, amountOutMin: STRANDED, nonce: 0});

        vm.startPrank(attacker);
        erc20.approve(address(router), 1);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({user: attacker, executor: address(router), amountOutMin: STRANDED, nonce: 0})
            )
        );
        vm.stopPrank();

        vm.prank(attacker);
        vm.expectRevert();
        router.fillOrder{value: 0}(order, type(uint256).max, "");
    }
}
