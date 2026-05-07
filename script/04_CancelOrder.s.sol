// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FFIHelper} from "./FFIHelper.sol";
import {Router} from "@async-swap/Router.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {console} from "forge-std/Script.sol";

/// @notice Cancels the most-recently-submitted async order (loaded from the
///         deployments sidecar). Caller must equal `order.owner` — the Router
///         enforces this in `cancelOrder`. The maker reclaims `amountIn` of
///         their input currency as real tokens delivered to their wallet.
contract CancelAsyncOrderScript is FFIHelper {
    Router router;
    AsyncOrder order;

    function setUp() public {
        (, address r) = _getDeployedHook();
        router = Router(r);
        order = _loadOrder();
    }

    function run() public {
        vm.startBroadcast(OWNER);
        router.cancelOrder(order);
        vm.stopBroadcast();

        console.log("Async order cancelled. nonce:", uint256(order.nonce));
        console.log("Owner reclaimed amountIn:", order.amountIn);
    }
}
