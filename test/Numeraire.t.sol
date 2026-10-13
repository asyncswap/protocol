// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AsyncSwap} from "src/AsyncSwap.sol";
import {BaseHook} from "src/BaseHook.sol";
import {Router} from "src/Router.sol";
import {AsyncOrder} from "src/types/AsyncOrder.sol";
import {ISignatureTransfer} from "src/interfaces/ISignatureTransfer.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {Permit2Bytecode} from "./utils/Permit2Bytecode.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";

/// @dev Only bypasses permission-address mining for constructor rejection tests.
contract NumeraireConstructorHarness is AsyncSwap {
    constructor(IPoolManager manager, Currency quote, address owner_) AsyncSwap(manager, quote, owner_) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract NumeraireTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager manager;
    AsyncSwap hook;
    Router router;
    MockERC20 usdc;
    MockERC20 asset;
    address maker = makeAddr("maker");
    address filler = makeAddr("filler");

    function setUp() public {
        manager = new PoolManager(address(this));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        asset = new MockERC20("Asset", "ASSET", 18);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        deployCodeTo("AsyncSwap.sol", abi.encode(manager, Currency.wrap(address(usdc)), address(this)), address(flags));
        hook = AsyncSwap(payable(address(flags)));
        router = new Router(manager, hook, ISignatureTransfer(Permit2Bytecode.PERMIT2));
    }

    function _key(address a, address b) internal view returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, hook);
    }

    function _expectMissingNumeraire() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(AsyncSwap.NumeraireRequired.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function test_numeraireIsConfiguredToken() public view {
        assertEq(Currency.unwrap(hook.numeraire()), address(usdc));
    }

    function test_rejectZeroNumeraire() public {
        vm.expectRevert(AsyncSwap.InvalidNumeraire.selector);
        new NumeraireConstructorHarness(manager, Currency.wrap(address(0)), address(this));
    }

    function test_rejectNonContractNumeraire() public {
        vm.expectRevert(AsyncSwap.InvalidNumeraire.selector);
        new NumeraireConstructorHarness(manager, Currency.wrap(makeAddr("not a token")), address(this));
    }

    /// @dev CREATE2 deployments run the constructor from the deterministic deployer, so the owner
    ///      must come from the argument, never from `msg.sender`.
    function test_ownerIsExplicitArgumentNotDeployer() public {
        address protocolOwner = makeAddr("protocol owner");
        AsyncSwap h = new NumeraireConstructorHarness(manager, Currency.wrap(address(usdc)), protocolOwner);
        assertEq(h.owner(), protocolOwner);
        assertTrue(h.owner() != address(this));
    }

    function test_rejectZeroOwner() public {
        vm.expectRevert(AsyncSwap.ZeroAddress.selector);
        new NumeraireConstructorHarness(manager, Currency.wrap(address(usdc)), address(0));
    }

    function test_acceptNumeraireOnEitherSortedSide() public {
        PoolKey memory low = _key(address(1), address(usdc));
        PoolKey memory high = _key(address(usdc), address(type(uint160).max));
        assertEq(Currency.unwrap(low.currency1), address(usdc));
        assertEq(Currency.unwrap(high.currency0), address(usdc));
        manager.initialize(low, 2 ** 96);
        manager.initialize(high, 2 ** 96);
    }

    function test_acceptNativeUsdcPool() public {
        manager.initialize(_key(address(0), address(usdc)), 2 ** 96);
    }

    function test_rejectNativeNonUsdcPool() public {
        PoolKey memory invalid = _key(address(0), address(asset));
        _expectMissingNumeraire();
        manager.initialize(invalid, 2 ** 96);
    }

    function test_rejectTokenWithUsdcSymbolButWrongAddress() public {
        MockERC20 impostor = new MockERC20("USD Coin", "USDC", 6);
        PoolKey memory invalid = _key(address(asset), address(impostor));
        _expectMissingNumeraire();
        manager.initialize(invalid, 2 ** 96);
    }

    function testFuzz_rejectPairsWithoutNumeraire(address a, address b) public {
        vm.assume(a != b && a != address(usdc) && b != address(usdc));
        PoolKey memory invalid = _key(a, b);
        _expectMissingNumeraire();
        manager.initialize(invalid, 2 ** 96);
    }

    function test_sellAssetForSixDecimalUsdc() public {
        _trade(false);
    }

    function test_buyAssetWithSixDecimalUsdc() public {
        _trade(true);
    }

    function _trade(bool buyAsset) internal {
        PoolKey memory key = _key(address(asset), address(usdc));
        manager.initialize(key, 2 ** 96);
        MockERC20 input = buyAsset ? usdc : asset;
        MockERC20 output = buyAsset ? asset : usdc;
        uint256 amountIn = buyAsset ? 100e6 : 1 ether;
        uint256 netOutput = buyAsset ? 1 ether : 99_700_000;
        uint256 fee = (netOutput / 997) * 3 + ((netOutput % 997) * 3) / 997;
        uint256 grossOutput = netOutput + fee;
        bool direction = Currency.unwrap(key.currency0) == address(input);
        AsyncOrder memory order = AsyncOrder(key, maker, direction, amountIn, netOutput, 2 ** 96, bytes32(0));
        input.mint(maker, amountIn);
        output.mint(filler, grossOutput);
        vm.startPrank(maker);
        hook.setExecutor(key.toId(), address(router), true);
        input.approve(address(router), amountIn);
        router.swap(order, abi.encode(AsyncSwap.UserParams(maker, address(router), netOutput)));
        vm.stopPrank();
        order.salt = keccak256(abi.encode(block.timestamp, block.number, address(manager), maker, amountIn, netOutput));
        vm.startPrank(filler);
        output.approve(address(router), grossOutput);
        router.fillOrder(order, grossOutput, "");
        vm.stopPrank();
        assertEq(output.balanceOf(maker), netOutput);
        assertEq(input.balanceOf(filler), amountIn);
        assertEq(output.balanceOf(filler), 0);
        assertEq(manager.balanceOf(address(hook.feeVault()), uint160(address(output))), fee);
        assertEq(
            hook.asyncOrder(key.toId(), keccak256(abi.encode(block.chainid, key.toId(), maker, direction, order.salt))),
            0
        );
    }
}
