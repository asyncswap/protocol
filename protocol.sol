// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncOrder, AsyncOrderLibrary} from "@async-swap/types/AsyncOrder.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IPoolManager, ModifyLiquidityParams, SwapParams} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {BaseHook} from "src/BaseHook.sol";

abstract contract Protocol is BaseHook {
    using SafeCast for *;

    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using AsyncFiller for AsyncFiller.State;
    using AsyncOrderLibrary for AsyncOrder;

    mapping(PoolId poolId => AsyncFiller.State) public orders;

    event AsyncSwap(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint128 hookFeeAmount0,
        uint128 hookFeeAmount1
    );

    error UnsupportedLiquidity();
    error ExactInputOnly();
    error UnaccounterNativeOutput();

    bytes32 constant PENDING_NATIVE_DEPOSIT_SLOT = 0;

    struct UserParams {
        address user;
        address fillerProxy;
        uint256 amountOut;
    }

    constructor(IPoolManager _pm) BaseHook(_pm) {}

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
        require(key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG, "Must use dynamic fee flag.");
        orders[key.toId()].poolManager = poolManager;
        return this.beforeInitialize.selector;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, //
            afterInitialize: false,
            beforeAddLiquidity: true, //
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, //
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, //
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert UnsupportedLiquidity();
    }

    function getAmountIn(PoolId poolId, bytes32 orderId) external view returns (uint256 amountIn) {
        return orders[poolId].orders[orderId].amountIn;
    }

    function orderInfo(PoolId poolId, bytes32 orderId) external view returns (uint256 amountIn, uint256 amountOut) {
        AsyncFiller.OrderInfo storage info = orders[poolId].orders[orderId];
        return (info.amountIn, info.amountOutMin);
    }

    function isFiller(PoolId poolId, address owner, address executor) external view returns (bool) {
        return orders[poolId].setExecutor[owner][executor];
    }
}
