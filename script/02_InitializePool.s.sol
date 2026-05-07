// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FFIHelper} from "./FFIHelper.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {console} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Deploys two MockERC20 tokens, initializes a pool with the AsyncSwap hook, and persists
///         the resulting PoolKey to the deployments sidecar so subsequent scripts can rebuild it.
contract InitializePool is FFIHelper {
    IPoolManager manager;
    AsyncSwap hook;
    PoolKey key;

    uint24 internal constant FEE = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 internal constant TICK_SPACING = 60;

    function setUp() public {
        manager = IPoolManager(_getDeployedPoolManager());
        (address h,) = _getDeployedHook();
        hook = AsyncSwap(payable(h));
    }

    function run() public {
        vm.startBroadcast();
        _initialize();
        vm.stopBroadcast();
        _savePoolKey(key);
        console.log("Pool initialized.");
        console.log("currency0:", Currency.unwrap(key.currency0));
        console.log("currency1:", Currency.unwrap(key.currency1));
    }

    function _initialize() internal {
        MockERC20 a = new MockERC20("Async USDC", "aUSDC", 18);
        MockERC20 b = new MockERC20("Test USDC", "tUSDC", 18);
        a.mint(OWNER, 1_000_000 ether);
        b.mint(OWNER, 1_000_000 ether);

        Currency c0;
        Currency c1;
        if (address(a) < address(b)) {
            c0 = Currency.wrap(address(a));
            c1 = Currency.wrap(address(b));
        } else {
            c0 = Currency.wrap(address(b));
            c1 = Currency.wrap(address(a));
        }

        key = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: TICK_SPACING, hooks: hook});
        manager.initialize(key, 2 ** 96);
    }
}
