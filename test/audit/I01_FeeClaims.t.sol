// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "src/AsyncSwap.sol";
import {FeeVault} from "src/FeeVault.sol";
import {AsyncOrder} from "src/types/AsyncOrder.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

/// @dev Exercise fee accounting with a larger test fee. Production rate is tested separately.
contract FeeTestHook is AsyncSwap {
    constructor(IPoolManager manager, Currency numeraire, address owner_) AsyncSwap(manager, numeraire, owner_) {}

    function calculatePoolFee(uint24, uint256 amount) public pure override returns (uint256) {
        return amount / 100;
    }
}

contract I01_FeeClaimsTest is SetupHook {
    using PoolIdLibrary for PoolKey;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    FeeVault vault;

    function setUp() public override {
        _deployManager();
        _deployTokens();
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        deployCodeTo("FeeTestHook", abi.encode(manager, currency1, address(this)), address(flags));
        hook = AsyncSwap(payable(address(flags)));
        vault = hook.feeVault();
        _deployRouter();
        _createKey();
        _initializePool();
        _mintToOwner();
        topUp(alice, 100 ether);
        topUp(bob, 100 ether);
    }

    function _create(bool direction, uint256 gross) internal returns (AsyncOrder memory order) {
        order = AsyncOrder(key, alice, direction, gross, 1 ether, 2 ** 96, bytes32(0));
        Currency input = direction ? key.currency0 : key.currency1;
        vm.startPrank(alice);
        if (!input.isAddressZero()) {
            (direction ? token0 : token1).approve(address(router), gross);
        }
        router.swap{value: input.isAddressZero() ? gross : 0}(
            order, abi.encode(AsyncSwap.UserParams(alice, address(router), 1 ether))
        );
        vm.stopPrank();
        order.salt = _expectedSalt(alice, gross, 1 ether);
        assertEq(hook.asyncOrder(poolId, _orderIdFor(alice, direction, order.salt)), gross);
    }

    function _fill(AsyncOrder memory order) internal {
        vm.startPrank(bob);
        (order.zeroForOne ? token1 : token0).approve(address(router), type(uint256).max);
        Currency output = order.zeroForOne ? order.key.currency1 : order.key.currency0;
        uint256 grossOutput = 1.01 ether;
        router.fillOrder{value: output.isAddressZero() ? grossOutput : 0}(order, type(uint256).max, "");
        vm.stopPrank();
    }

    function test_collectBeforeFill_cannotTakeEscrow() public {
        AsyncOrder memory order = _create(true, 10 ether);
        assertEq(manager.balanceOf(address(vault), currency0.toId()), 0);
        vault.collect(currency1, bob);
        assertEq(token0.balanceOf(bob), 100 ether);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 10 ether);
        _fill(order);
        assertEq(token0.balanceOf(bob), 110 ether);
        assertEq(token1.balanceOf(alice), 101 ether);
        assertEq(manager.balanceOf(address(vault), currency1.toId()), 0.01 ether);
        vault.collect(currency1, bob);
        assertEq(token0.balanceOf(bob), 110 ether);
        assertEq(token0.balanceOf(address(manager)), 0);
        assertEq(token1.balanceOf(bob), 99 ether);
        assertEq(manager.balanceOf(address(vault), currency1.toId()), 0);
    }

    function test_cancelReverseDirection_refundsFullDeposit() public {
        AsyncOrder memory order = _create(false, 10 ether);
        vm.prank(alice);
        router.cancelOrder(order);
        assertEq(token1.balanceOf(alice), 100 ether);
        vault.collect(currency1, bob);
        assertEq(token1.balanceOf(bob), 100 ether);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
        assertEq(manager.balanceOf(address(vault), currency1.toId()), 0);
    }

    function testFuzz_cancelNeverChargesFees(uint96 value, bool direction) public {
        uint256 gross = bound(uint256(value), 1, 100 ether);
        AsyncOrder memory order = _create(direction, gross);
        Currency input = direction ? currency0 : currency1;
        vault.collect(input, bob);
        assertEq(manager.balanceOf(address(vault), input.toId()), 0);
        assertEq(manager.balanceOf(address(hook), input.toId()), gross);
        vm.prank(alice);
        router.cancelOrder(order);
        assertEq(manager.balanceOf(address(hook), input.toId()), 0);
        assertEq(input.balanceOf(address(manager)), 0);
        assertEq(input.balanceOf(alice), 100 ether);
        assertEq(input.balanceOf(bob), 100 ether);
    }

    function testFuzz_fillConservesInput(uint96 value, bool direction) public {
        uint256 gross = bound(uint256(value), 1, 100 ether);
        AsyncOrder memory order = _create(direction, gross);
        Currency input = direction ? currency0 : currency1;
        _fill(order);
        assertEq(input.balanceOf(bob), 100 ether + gross);
        Currency output = direction ? currency1 : currency0;
        assertEq(manager.balanceOf(address(vault), output.toId()), 0.01 ether);
        vault.collect(output, bob);
        assertEq(output.balanceOf(bob), 99 ether);
        assertEq(manager.balanceOf(address(hook), input.toId()), 0);
        vault.collect(input, bob);
        assertEq(input.balanceOf(address(manager)), 0);
    }

    function test_feeUsesStoredOutput_andCollectionPreservesOtherOrders() public {
        AsyncOrder memory first = _create(true, 10 ether);
        AsyncOrder memory second = _create(true, 20 ether);
        first.amountOutMin = 1; // Untrusted calldata must not reduce the fee.
        _fill(first);
        vault.collect(currency1, bob);
        assertEq(token0.balanceOf(bob), 110 ether);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 20 ether);
        vm.prank(alice);
        router.cancelOrder(second);
        assertEq(token0.balanceOf(alice), 90 ether);
        assertEq(token0.balanceOf(address(manager)), 0);
        assertEq(token1.balanceOf(bob), 99 ether);
        assertEq(manager.balanceOf(address(vault), currency1.toId()), 0);
    }

    function test_failedFillDoesNotEarnFees() public {
        AsyncOrder memory order = _create(true, 10 ether);
        vm.startPrank(bob);
        token1.approve(address(router), 0);
        vm.expectRevert();
        router.fillOrder(order, type(uint256).max, "");
        vm.stopPrank();
        assertEq(manager.balanceOf(address(vault), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 10 ether);
        vm.prank(alice);
        router.cancelOrder(order);
        assertEq(token0.balanceOf(alice), 100 ether);
    }

    function _nativeOrder(bool nativeInput) internal returns (AsyncOrder memory) {
        key.currency0 = Currency.wrap(address(0));
        poolId = key.toId();
        _initializePool();
        vm.prank(alice);
        hook.setExecutor(poolId, address(router), true);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 2 ether);
        return _create(nativeInput, 10 ether);
    }

    function test_nativeCancellation_refundsFullDeposit() public {
        AsyncOrder memory order = _nativeOrder(true);
        vault.collect(key.currency0, bob);
        assertEq(bob.balance, 2 ether);
        vm.prank(alice);
        router.cancelOrder(order);
        assertEq(alice.balance, 10 ether);
        assertEq(address(manager).balance, 0);
    }

    function test_failedNativeRecipient_preservesClaims() public {
        _fill(_nativeOrder(false));
        vm.expectRevert();
        vault.collect(key.currency0, address(this)); // This test has no receive function.
        assertEq(manager.balanceOf(address(vault), 0), 0.01 ether);
        vault.collect(key.currency0, bob);
        assertEq(bob.balance, 1 ether);
    }

    function test_collectionAuthorizationFollowsOwnership() public {
        _fill(_create(true, 10 ether));
        vm.prank(alice);
        vm.expectRevert(FeeVault.Unauthorized.selector);
        vault.collect(currency0, alice);
        hook.transferOwnership(alice);
        // Two-step: alice gains no rights until she accepts.
        vm.prank(alice);
        vm.expectRevert(FeeVault.Unauthorized.selector);
        vault.collect(currency1, bob);
        vm.prank(alice);
        hook.acceptOwnership();
        vm.expectRevert(FeeVault.Unauthorized.selector);
        vault.collect(currency1, bob);
        vm.prank(alice);
        vault.collect(currency1, bob);
        assertEq(token0.balanceOf(bob), 110 ether);
    }

    function test_callbackCannotBeCalledDirectly() public {
        _fill(_create(true, 10 ether));
        vm.expectRevert(FeeVault.Unauthorized.selector);
        vault.unlockCallback(abi.encode(currency0, bob));
    }

    function test_zeroRecipientRejected() public {
        vm.expectRevert(FeeVault.ZeroAddress.selector);
        vault.collect(currency0, address(0));
    }

    function test_emptyAndRepeatedCollection() public {
        vault.collect(currency1, bob);
        _fill(_create(true, 10 ether));
        vault.collect(currency1, bob);
        vault.collect(currency1, bob);
        assertEq(token0.balanceOf(bob), 110 ether);
    }
}
