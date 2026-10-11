// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {CurrencySettler} from "@async-swap/libraries/CurrencySettler.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Currency, IPoolManager, SwapParams} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @dev Acts as maker and its own executor, then fills its own order directly via the hook.
contract Drainer {
    using CurrencySettler for Currency;

    IPoolManager pm;
    AsyncSwap hook;
    PoolKey key;

    constructor(IPoolManager _pm, AsyncSwap _hook, PoolKey memory _key) {
        pm = _pm;
        hook = _hook;
        key = _key;
    }

    function go(uint256 amountOutMin) external {
        hook.setExecutor(PoolIdLibrary.toId(key), address(this), true);
        pm.unlock(abi.encode(amountOutMin));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        uint256 amountOutMin = abi.decode(data, (uint256));
        pm.swap(
            key,
            SwapParams(true, -1, 4295128740),
            abi.encode(AsyncSwap.UserParams({user: address(this), executor: address(this), amountOutMin: amountOutMin}))
        );
        key.currency0.settle(pm, address(this), 1, false);
        bytes32 salt =
            keccak256(abi.encode(block.timestamp, block.number, address(pm), address(this), uint256(1), amountOutMin));
        AsyncOrder memory o = AsyncOrder(key, address(this), true, 1, amountOutMin, 0, salt);
        // Without pre-settling output, the hook must not pay it from its own token balance.
        hook.executeOrder(o, abi.encode(address(this)));
        return "";
    }
}

/// @notice M-01 regression: a self-authorized executor must not drain ERC20 held by the hook.
contract SR_M01_ERC20StrandedDrainTest is Test {
    function test_RevertWhen_M01_SelfExecutorDrainsStrandedERC20() public {
        IPoolManager manager = new PoolManager(address(this));
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        deployCodeTo("AsyncSwap.sol", abi.encode(manager, Currency.wrap(address(t1)), address(this)), address(flags));
        AsyncSwap hook = AsyncSwap(payable(address(flags)));
        PoolKey memory key =
            PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, hook);
        manager.initialize(key, 2 ** 96);

        t1.mint(address(hook), 500 ether); // stranded / mistakenly sent tokens
        Drainer d = new Drainer(manager, hook, key);
        t0.mint(address(d), 1);

        vm.expectRevert();
        d.go(499 ether);

        assertEq(t1.balanceOf(address(hook)), 500 ether, "stranded balance untouched");
        assertEq(t1.balanceOf(address(d)), 0, "attacker gained nothing");
    }
}
