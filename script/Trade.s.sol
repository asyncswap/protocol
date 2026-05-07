// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FFIHelper} from "./FFIHelper.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Submit an AsyncSwap order with token symbols + amount provided via env, pricing
///         resolved through `script/price.ts` over `vm.ffi`. Use this for live testing on
///         the deployed hook (e.g. ETH/USDC on Unichain mainnet) without baking values into
///         the script.
///
///         Required env:
///           PRIVATE_KEY      maker's key (forge --broadcast picks this up)
///           TOKEN_IN         symbol, e.g. "ETH" / "USDC"
///           TOKEN_OUT        symbol
///           AMOUNT           input amount, human-readable, e.g. "0.005"
///
///         Optional env:
///           SLIPPAGE_BPS     default 100 (1%)
///           PRICE            tokenOut/tokenIn rate; bypasses Coinbase lookup in price.ts
///           POOL_FEE         default LPFeeLibrary.DYNAMIC_FEE_FLAG
///           POOL_TICK_SPACING default 60
///
///         Example:
///           TOKEN_IN=ETH TOKEN_OUT=USDC AMOUNT=0.005 \
///           forge script script/Trade.s.sol --rpc-url unichain --ffi --broadcast
contract TradeScript is FFIHelper {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    AsyncSwap hook;
    Router router;
    IPoolManager manager;

    function setUp() public {
        (address h, address r) = _getDeployedHook();
        hook = AsyncSwap(payable(h));
        router = Router(r);
        manager = IPoolManager(_getDeployedPoolManager());
    }

    function run() public {
        (address inAddr, address outAddr, uint256 amountIn, uint256 amountOutMin) = _resolveTrade();
        (PoolKey memory key, bool zeroForOne) = _buildPoolKey(inAddr, outAddr);

        // Auto-initialize the pool if it isn't yet. We read slot0 first because
        // wrapping `manager.initialize` in try/catch under vm.startBroadcast()
        // still records the call for the broadcast replay, which then reverts
        // outside the try frame with PoolAlreadyInitialized. Reading state up
        // front lets us conditionally broadcast.
        (uint160 currentSqrtPrice,,,) = manager.getSlot0(key.toId());
        if (currentSqrtPrice == 0) {
            uint160 initSqrtPrice = uint160(vm.envOr("INIT_SQRT_PRICE_X96", uint256(2 ** 96)));
            vm.startBroadcast(OWNER);
            manager.initialize(key, initSqrtPrice);
            vm.stopBroadcast();
            console.log("Pool initialized at sqrtPriceX96:", uint256(initSqrtPrice));
        }

        uint64 nonce = uint64(block.timestamp);

        AsyncOrder memory order = AsyncOrder({
            key: key,
            owner: OWNER,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            sqrtPrice: 2 ** 96,
            nonce: nonce
        });
        bytes memory userData = abi.encode(
            AsyncSwap.UserParams({user: OWNER, executor: address(router), amountOutMin: amountOutMin, nonce: nonce})
        );

        console.log("amountIn:    ", amountIn);
        console.log("amountOutMin:", amountOutMin);
        console.log("zeroForOne:  ", zeroForOne);

        vm.startBroadcast(OWNER);
        if (inAddr == address(0)) {
            router.swap{value: amountIn}(order, userData);
        } else {
            IERC20Minimal(inAddr).approve(address(router), amountIn);
            router.swap(order, userData);
        }
        vm.stopBroadcast();

        console.log("submitted; nonce:", uint256(nonce));
    }

    /// @dev FFIs `script/price.ts` and pulls the two amounts back into Solidity.
    function _resolveTrade()
        internal
        returns (address inAddr, address outAddr, uint256 amountIn, uint256 amountOutMin)
    {
        string memory inSym = vm.envOr("TOKEN_IN", string("ETH"));
        string memory outSym = vm.envOr("TOKEN_OUT", string("USDC"));
        string memory amountStr = vm.envOr("AMOUNT", string("0.0001"));
        uint256 slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(100));

        (inAddr,) = _resolveToken(inSym);
        (outAddr,) = _resolveToken(outSym);
        require(inAddr != outAddr, "TOKEN_IN must differ from TOKEN_OUT");

        string[] memory cmd = new string[](7);
        cmd[0] = "bun";
        cmd[1] = "run";
        cmd[2] = "script/price.ts";
        cmd[3] = inSym;
        cmd[4] = outSym;
        cmd[5] = amountStr;
        cmd[6] = vm.toString(slippageBps);
        bytes memory raw = vm.ffi(cmd);
        (amountIn, amountOutMin) = abi.decode(raw, (uint256, uint256));
    }

    /// @dev Sorts the in/out addresses into v4's `currency0 < currency1` order
    ///      and assembles the PoolKey using the deployed AsyncSwap hook.
    function _buildPoolKey(address inAddr, address outAddr)
        internal
        view
        returns (PoolKey memory key, bool zeroForOne)
    {
        Currency c0;
        Currency c1;
        if (inAddr < outAddr) {
            c0 = Currency.wrap(inAddr);
            c1 = Currency.wrap(outAddr);
            zeroForOne = true;
        } else {
            c0 = Currency.wrap(outAddr);
            c1 = Currency.wrap(inAddr);
            zeroForOne = false;
        }
        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: uint24(vm.envOr("POOL_FEE", uint256(LPFeeLibrary.DYNAMIC_FEE_FLAG))),
            tickSpacing: int24(int256(vm.envOr("POOL_TICK_SPACING", uint256(60)))),
            hooks: hook
        });
    }

    /* ------------------------------ token registry ----------------------------- */

    /// @dev Unichain mainnet (130) tokens. Extend per-chain as you add more.
    function _resolveToken(string memory sym) internal view returns (address, uint8) {
        require(block.chainid == 130, "Trade.s.sol: only Unichain mainnet token map for now");
        bytes32 h = keccak256(bytes(sym));
        if (h == keccak256("ETH")) return (address(0), 18);
        if (h == keccak256("WETH")) return (0x4200000000000000000000000000000000000006, 18);
        if (h == keccak256("USDC")) return (0x078D782b760474a361dDA0AF3839290b0EF57AD6, 6);
        if (h == keccak256("USDT")) return (0x9151434b16b9763660705744891fA906F660EcC5, 6);
        revert(string.concat("Trade.s.sol: unknown token symbol ", sym));
    }
}
