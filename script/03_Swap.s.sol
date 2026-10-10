// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FFIHelper} from "./FFIHelper.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {Router} from "@async-swap/Router.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Submits an async swap order via the Router. The hook now auto-assigns a salt on
///         create, so the script passes `order.salt = bytes32(0)` and parses the actual salt
///         out of the `AsyncOrderCreated` event log post-broadcast (so 04_Cancel / 05_Execute
///         can reference the same order via the persisted salt).
contract SwapScript is FFIHelper {
    Router router;
    PoolKey key;

    // Amounts are supplied explicitly in each token's base units: USDC uses six
    // decimals while the paired asset may use a different scale.

    function setUp() public {
        (, address r) = _getDeployedHook();
        router = Router(r);
        key = _loadPoolKey();
    }

    function run() public {
        uint160 sqrtPrice = 2 ** 96;

        AsyncOrder memory order = AsyncOrder({
            key: key,
            owner: OWNER,
            zeroForOne: vm.envOr("ZERO_FOR_ONE", true),
            amountIn: vm.envUint("AMOUNT_IN"),
            amountOutMin: vm.envUint("AMOUNT_OUT_MIN"),
            sqrtPrice: sqrtPrice,
            // Initial submit: ignored by the hook, which assigns its own salt.
            salt: bytes32(0)
        });

        Currency input = order.zeroForOne ? key.currency0 : key.currency1;

        // Record logs so we can pluck the assigned salt out of AsyncOrderCreated
        // after the broadcast completes.
        vm.recordLogs();
        vm.startBroadcast(OWNER);
        IERC20Minimal(Currency.unwrap(input)).approve(address(router), order.amountIn);
        router.swap(
            order,
            abi.encode(AsyncSwap.UserParams({user: OWNER, executor: address(router), amountOutMin: order.amountOutMin}))
        );
        vm.stopBroadcast();

        bytes32 salt = _extractSalt();

        _saveOrder(
            OrderRecord({
                owner: OWNER,
                zeroForOne: order.zeroForOne,
                amountIn: order.amountIn,
                amountOutMin: order.amountOutMin,
                sqrtPrice: sqrtPrice,
                salt: salt
            })
        );

        console.log("Async order submitted.");
        console.logBytes32(salt);
    }

    /// @dev Find the `AsyncOrderCreated` log in the broadcast and return the salt
    ///      from its data field. Layout matches the event signature in AsyncFiller.
    function _extractSalt() private returns (bytes32) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = AsyncFiller.AsyncOrderCreated.selector;
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory log = logs[i - 1];
            if (log.topics.length > 0 && log.topics[0] == sig) {
                // Non-indexed data layout: (bool zeroForOne, uint256 amountIn,
                // uint256 amountOutMin, bytes32 salt). Salt is the 4th word.
                (,,, bytes32 salt) = abi.decode(log.data, (bool, uint256, uint256, bytes32));
                return salt;
            }
        }
        revert("AsyncOrderCreated event not found in broadcast logs");
    }
}
