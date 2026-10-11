// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ISignatureTransfer} from "@async-swap/interfaces/ISignatureTransfer.sol";
import {Permit2Bytecode} from "./utils/Permit2Bytecode.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Currency, IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Shared deployment scaffold for protocol tests: PoolManager + AsyncSwap hook + Router +
///         a single `currency0/currency1` MockERC20 pair, with the maker pre-funded.
contract SetupHook is Test {
    using PoolIdLibrary for PoolKey;

    address owner = makeAddr("deployer");
    IPoolManager manager;
    AsyncSwap hook;
    Router router;
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolId poolId;

    function setUp() public virtual {
        _deployManager();
        _deployTokens();
        _deployHook();
        _deployRouter();
        _createKey();
        _initializePool();
        _mintToOwner();
    }

    modifier ownerAction() {
        vm.startPrank(owner);
        _;
        vm.stopPrank();
    }

    function _deployManager() internal {
        manager = new PoolManager(owner);
    }

    function _deployTokens() internal {
        vm.startPrank(owner);
        address tokenA = address(new MockERC20("Token A", "TKA", 18));
        address tokenB = address(new MockERC20("Token B", "TKB", 18));
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        currency0 = Currency.wrap(t0);
        currency1 = Currency.wrap(t1);
        token0 = MockERC20(t0);
        token1 = MockERC20(t1);
        vm.stopPrank();
        vm.label(t0, "token0");
        vm.label(t1, "token1");
    }

    function _deployHook() internal {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        deployCodeTo("AsyncSwap.sol", abi.encode(manager, currency1, address(this)), address(flags));
        hook = AsyncSwap(payable(address(flags)));
    }

    function _deployRouter() internal {
        router = new Router(manager, hook, ISignatureTransfer(Permit2Bytecode.PERMIT2));
    }

    function _createKey() internal {
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(1),
            hooks: hook
        });
        poolId = key.toId();
    }

    function _initializePool() internal {
        manager.initialize(key, 2 ** 96);
    }

    function _mintToOwner() internal {
        token0.mint(owner, 2 ** 128 - 1);
        token1.mint(owner, 2 ** 128 - 1);
    }

    function topUp(address user, uint256 amount) public ownerAction {
        token0.transfer(user, amount);
        token1.transfer(user, amount);
        vm.stopPrank();
        vm.prank(user);
        hook.setExecutor(poolId, address(router), true);
        vm.startPrank(owner);
    }

    /// @dev Predict the salt the hook assigns on a fresh `_createOrder`. Mirrors
    ///      `keccak256(abi.encode(block.timestamp, block.number, msg.sender, user, amountIn, amountOutMin))`
    ///      where `msg.sender` at the hook is the PoolManager (since `_beforeSwap` is invoked by PM).
    ///      Only valid when the (user, amountIn, amountOutMin) tuple is fresh in the current block —
    ///      a colliding tuple would trigger the in-contract salt-walk.
    function _expectedSalt(address user, uint256 amountIn, uint256 amountOutMin) internal view returns (bytes32) {
        return keccak256(abi.encode(block.timestamp, block.number, address(manager), user, amountIn, amountOutMin));
    }

    /// @dev Compute the orderId the hook will store under, for an order with the given assigned salt.
    function _orderIdFor(address user, bool zeroForOne, bytes32 salt) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, poolId, user, zeroForOne, salt));
    }
}
