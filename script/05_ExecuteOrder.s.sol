// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FFIHelper} from "./FFIHelper.sol";
import {Router} from "@async-swap/Router.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {console} from "forge-std/Script.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice Fills the most-recently-submitted async order (loaded from the deployments sidecar).
///         Approves the router for `amountOutMin` of the maker's output currency.
contract ExecuteAsyncOrderScript is FFIHelper {
    Router router;
    AsyncOrder order;

    function setUp() public {
        (, address r) = _getDeployedHook();
        router = Router(r);
        order = _loadOrder();
    }

    function run() public {
        Currency output = order.zeroForOne ? order.key.currency1 : order.key.currency0;

        vm.startBroadcast(OWNER);
        IERC20Minimal(Currency.unwrap(output)).approve(address(router), order.amountOutMin);
        router.fillOrder(order, order.amountOutMin, "");
        vm.stopBroadcast();

        console.log("Async order filled. nonce:", uint256(order.nonce));
    }
}
