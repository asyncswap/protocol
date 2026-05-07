// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FFIHelper} from "./FFIHelper.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Initializes a v4 pool using **real** mainnet tokens (e.g. ETH/USDC) with the deployed
///         AsyncSwap hook. Distinct from 02_InitializePool.s.sol which deploys MockERC20s; this
///         one is for live deployments where the tokens already exist on-chain.
///
///         Env (all optional except for tokens via env or default ETH/USDC):
///           TOKEN_IN              symbol e.g. "ETH" / "USDC" — order doesn't matter, the script sorts
///           TOKEN_OUT             symbol
///           POOL_FEE              default LPFeeLibrary.DYNAMIC_FEE_FLAG (so the hook drives fee)
///           POOL_TICK_SPACING     default 60
///           INIT_SQRT_PRICE_X96   default 2**96 (= 1.0 between the sorted currencies)
///
///         Example:
///           TOKEN_IN=ETH TOKEN_OUT=USDC INIT_SQRT_PRICE_X96=... \
///           forge script script/InitPool.s.sol --rpc-url unichain --broadcast
///
///         The PoolKey is persisted to deployments/<chainId>-pool.json so subsequent scripts
///         can reload it without re-passing args.
contract InitPoolScript is FFIHelper {
    IPoolManager manager;
    AsyncSwap hook;

    function setUp() public {
        manager = IPoolManager(_getDeployedPoolManager());
        (address h,) = _getDeployedHook();
        hook = AsyncSwap(payable(h));
    }

    function run() public {
        string memory inSym = vm.envOr("TOKEN_IN", string("ETH"));
        string memory outSym = vm.envOr("TOKEN_OUT", string("USDC"));
        (address inAddr,) = _resolveToken(inSym);
        (address outAddr,) = _resolveToken(outSym);
        require(inAddr != outAddr, "TOKEN_IN must differ from TOKEN_OUT");

        Currency c0;
        Currency c1;
        if (inAddr < outAddr) {
            c0 = Currency.wrap(inAddr);
            c1 = Currency.wrap(outAddr);
        } else {
            c0 = Currency.wrap(outAddr);
            c1 = Currency.wrap(inAddr);
        }

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: uint24(vm.envOr("POOL_FEE", uint256(LPFeeLibrary.DYNAMIC_FEE_FLAG))),
            tickSpacing: int24(int256(vm.envOr("POOL_TICK_SPACING", uint256(60)))),
            hooks: hook
        });
        uint160 sqrtPriceX96 = uint160(vm.envOr("INIT_SQRT_PRICE_X96", uint256(2 ** 96)));

        console.log("Initializing pool:");
        console.log("  currency0:    ", Currency.unwrap(c0));
        console.log("  currency1:    ", Currency.unwrap(c1));
        console.log("  fee:          ", uint256(key.fee));
        console.log("  tickSpacing:  ", int256(key.tickSpacing));
        console.log("  sqrtPriceX96: ", uint256(sqrtPriceX96));
        console.log("  hook:         ", address(hook));

        vm.startBroadcast();
        manager.initialize(key, sqrtPriceX96);
        vm.stopBroadcast();

        _savePoolKey(key);
        console.log("Pool initialized + PoolKey saved.");
    }

    /// @dev Mirrors Trade.s.sol's token registry. Keep the two in sync as you add tokens.
    function _resolveToken(string memory sym) internal view returns (address, uint8) {
        require(block.chainid == 130, "InitPool.s.sol: only Unichain mainnet token map for now");
        bytes32 h = keccak256(bytes(sym));
        if (h == keccak256("ETH")) return (address(0), 18);
        if (h == keccak256("WETH")) return (0x4200000000000000000000000000000000000006, 18);
        if (h == keccak256("USDC")) return (0x078D782b760474a361dDA0AF3839290b0EF57AD6, 6);
        if (h == keccak256("USDT")) return (0x9151434b16b9763660705744891fA906F660EcC5, 6);
        revert(string.concat("InitPool.s.sol: unknown token symbol ", sym));
    }
}
