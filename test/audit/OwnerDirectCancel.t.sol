// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Router} from "@async-swap/Router.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {MockERC20} from "../utils/MockERC20.sol";

/// @notice A smart-contract maker that creates an order through the Router, can
///         later revoke the Router's executor grant, and still cancel its own
///         order by calling `hook.cancelOrder` directly from inside its own
///         PoolManager unlock — `msg.sender == order.owner` bypasses setExecutor.
contract SmartMaker is IUnlockCallback {
    IPoolManager public immutable manager;
    AsyncSwap public immutable hook;
    Router public immutable router;
    AsyncOrder pending;

    constructor(IPoolManager _manager, AsyncSwap _hook, Router _router) {
        manager = _manager;
        hook = _hook;
        router = _router;
    }

    function authorizeRouter(PoolId poolId, bool allow) external {
        hook.setExecutor(poolId, address(router), allow);
    }

    function submitOrder(AsyncOrder calldata order, MockERC20 inputToken) external {
        inputToken.approve(address(router), order.amountIn);
        router.swap(
            order,
            abi.encode(
                AsyncSwap.UserParams({
                    user: address(this), executor: address(router), amountOutMin: order.amountOutMin, nonce: order.nonce
                })
            )
        );
    }

    function cancelDirectly(AsyncOrder calldata order) external {
        pending = order;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "PM only");
        hook.cancelOrder(pending);
        return "";
    }
}

contract OwnerDirectCancelTest is SetupHook {
    function test_owner_can_cancel_directly_after_revoking_executor() public {
        SmartMaker maker = new SmartMaker(manager, hook, router);
        topUp(address(maker), 100 ether);

        // Re-grant authorisation explicitly through the contract (topUp's own
        // grant was made on behalf of `maker` as msg.sender during a vm.prank,
        // so it's already in place — but we make the test self-contained).
        maker.authorizeRouter(poolId, true);

        AsyncOrder memory order = AsyncOrder({
            key: key,
            owner: address(maker),
            zeroForOne: true,
            amountIn: 1 ether,
            amountOutMin: 0.9 ether,
            sqrtPrice: 2 ** 96,
            nonce: 0
        });

        uint256 makerToken0Before = token0.balanceOf(address(maker));
        maker.submitOrder(order, token0);
        assertEq(token0.balanceOf(address(maker)), makerToken0Before - 1 ether, "maker locked input");

        // Maker revokes Router as executor — open order remains.
        maker.authorizeRouter(poolId, false);
        assertFalse(hook.isExecutor(poolId, address(maker), address(router)), "router revoked");

        // Direct cancel through the maker's own unlock — msg.sender to hook is
        // the maker contract itself, so the executor==owner branch kicks in
        // and the cancel succeeds without re-granting.
        maker.cancelDirectly(order);
        assertEq(token0.balanceOf(address(maker)), makerToken0Before, "input refunded");
        (uint256 amountIn,) =
            hook.asyncOrderInfo(poolId, keccak256(abi.encode(poolId, address(maker), true, uint64(0))));
        assertEq(amountIn, 0, "order deleted");
    }
}
