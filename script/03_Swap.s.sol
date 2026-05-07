// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FFIHelper} from "./FFIHelper.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {console} from "forge-std/Script.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Submits an async swap order via the Router. The order's amountOutMin (the maker's
///         limit price) and a fresh nonce are encoded into hookData so the hook can record them.
contract SwapScript is FFIHelper {
    Router router;
    PoolKey key;

    // 100 *whole tokens* — both pool currencies are 18-decimals in the deploy
    // pipeline. The previous default (100 wei) rendered as "0" in the frontend
    // since it's 1e-16 of a normal token.
    uint256 internal constant DEFAULT_AMOUNT_IN = 100 ether;
    uint256 internal constant DEFAULT_AMOUNT_OUT_MIN = 100 ether;
    bool internal constant DEFAULT_ZERO_FOR_ONE = true;

    function setUp() public {
        (, address r) = _getDeployedHook();
        router = Router(r);
        key = _loadPoolKey();
    }

    function run() public {
        uint64 nonce = uint64(block.timestamp);
        uint160 sqrtPrice = 2 ** 96;

        AsyncOrder memory order = AsyncOrder({
            key: key,
            owner: OWNER,
            zeroForOne: DEFAULT_ZERO_FOR_ONE,
            amountIn: DEFAULT_AMOUNT_IN,
            amountOutMin: DEFAULT_AMOUNT_OUT_MIN,
            sqrtPrice: sqrtPrice,
            nonce: nonce
        });

        Currency input = order.zeroForOne ? key.currency0 : key.currency1;

        vm.startBroadcast(OWNER);
        IERC20Minimal(Currency.unwrap(input)).approve(address(router), order.amountIn);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: OWNER, executor: address(router), amountOutMin: order.amountOutMin, nonce: nonce
                })
            )
        );
        vm.stopBroadcast();

        _saveOrder(
            OrderRecord({
                owner: OWNER,
                zeroForOne: order.zeroForOne,
                amountIn: order.amountIn,
                amountOutMin: order.amountOutMin,
                sqrtPrice: sqrtPrice,
                nonce: nonce
            })
        );

        console.log("Async order submitted.");
        console.log("nonce:", uint256(nonce));
    }
}
