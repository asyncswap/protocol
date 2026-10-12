// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "./SetupHook.t.sol";
import {Permit2Bytecode} from "./utils/Permit2Bytecode.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {Router} from "@async-swap/Router.sol";
import {OrderSignatures} from "@async-swap/libraries/OrderSignatures.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Currency} from "v4-core/types/Currency.sol";

interface IPermit2Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @notice Gasless maker flows: a relayer submits EIP-712 signatures for create (Permit2 witness),
///         executor grant, price update and cancel. The maker never sends a transaction after the
///         one-time Permit2 token approval.
contract SignedOrdersTest is SetupHook {
    bytes4 constant PERMIT2_INVALID_SIGNER = 0x815e1d64; // InvalidSigner()
    bytes4 constant PERMIT2_INVALID_NONCE = 0x756688fe; // InvalidNonce()
    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");

    uint256 makerPk = 0xA11CE;
    address maker;
    address relayer = makeAddr("relayer");
    address bob = makeAddr("bob"); // filler

    uint256 constant AMOUNT_IN = 1 ether;
    uint256 constant AMOUNT_OUT_MIN = 0.95 ether;

    function setUp() public override {
        super.setUp();
        vm.etch(Permit2Bytecode.PERMIT2, Permit2Bytecode.RUNTIME);
        maker = vm.addr(makerPk);
        vm.prank(owner);
        token0.transfer(maker, 10 ether);
        // One-time on-chain step: approve Permit2 for the input token. No setExecutor call.
        vm.prank(maker);
        token0.approve(Permit2Bytecode.PERMIT2, type(uint256).max);
        topUp(bob, 100 ether);
    }

    /* --------------------------------- helpers --------------------------------- */

    function _order(uint256 amountOutMin) internal view returns (AsyncOrder memory) {
        return AsyncOrder({
            key: key,
            owner: maker,
            zeroForOne: true,
            amountIn: AMOUNT_IN,
            amountOutMin: amountOutMin,
            sqrtPrice: 2 ** 96,
            salt: bytes32(0)
        });
    }

    function _sign(bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _digest(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _permit(AsyncOrder memory order, uint256 nonce, uint256 deadline)
        internal
        view
        returns (Router.PermitData memory)
    {
        bytes32 typehash = keccak256(
            abi.encodePacked(
                "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,",
                OrderSignatures.PERMIT2_WITNESS_TYPE
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                typehash,
                keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, Currency.unwrap(currency0), order.amountIn)),
                address(router),
                nonce,
                deadline,
                OrderSignatures.hashOrder(order)
            )
        );
        bytes32 digest = _digest(IPermit2Domain(Permit2Bytecode.PERMIT2).DOMAIN_SEPARATOR(), structHash);
        return Router.PermitData({nonce: nonce, deadline: deadline, signature: _sign(digest)});
    }

    function _grant(uint256 nonce) internal view returns (Router.ExecutorGrant memory) {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = OrderSignatures.hashSetExecutor(key, maker, address(router), true, nonce, deadline);
        return Router.ExecutorGrant({
            nonce: nonce, deadline: deadline, signature: _sign(_digest(hook.DOMAIN_SEPARATOR(), structHash))
        });
    }

    function _noGrant() internal pure returns (Router.ExecutorGrant memory) {
        return Router.ExecutorGrant({nonce: 0, deadline: 0, signature: ""});
    }

    /// @dev Relayer submits a signed create; returns the order with the hook-assigned salt.
    function _createSigned() internal returns (AsyncOrder memory order) {
        order = _order(AMOUNT_OUT_MIN);
        Router.PermitData memory permit = _permit(order, 0, block.timestamp + 1 hours);
        vm.prank(relayer);
        router.swapWithSig(order, permit, _grant(0));
        order.salt = _expectedSalt(maker, AMOUNT_IN, AMOUNT_OUT_MIN);
    }

    function _id(AsyncOrder memory order) internal view returns (bytes32) {
        return _orderIdFor(order.owner, order.zeroForOne, order.salt);
    }

    /* ------------------------- executor authorization ------------------------- */

    function test_setExecutorWithSig_emitsGrantForMaker() public {
        Router.ExecutorGrant memory grant = _grant(7);

        vm.expectEmit(true, true, true, true, address(hook));
        emit AsyncSwap.ExecutorSet(poolId, maker, address(router), true);
        vm.prank(relayer);
        hook.setExecutorWithSig(key, maker, address(router), true, grant.nonce, grant.deadline, grant.signature);

        assertTrue(hook.isExecutor(poolId, maker, address(router)), "maker authorized executor");
        assertFalse(hook.isExecutor(poolId, relayer, address(router)), "relayer did not authorize executor");
        assertTrue(hook.nonceUsed(maker, grant.nonce), "nonce consumed");
    }

    function test_setExecutorWithSig_emitsRevocationForMaker() public {
        vm.prank(maker);
        hook.setExecutor(poolId, address(router), true);
        uint256 nonce = 7;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = OrderSignatures.hashSetExecutor(key, maker, address(router), false, nonce, deadline);
        bytes memory signature = _sign(_digest(hook.DOMAIN_SEPARATOR(), structHash));

        vm.expectEmit(true, true, true, true, address(hook));
        emit AsyncSwap.ExecutorSet(poolId, maker, address(router), false);
        vm.prank(relayer);
        hook.setExecutorWithSig(key, maker, address(router), false, nonce, deadline, signature);

        assertFalse(hook.isExecutor(poolId, maker, address(router)), "maker revoked executor");
        assertTrue(hook.nonceUsed(maker, nonce), "nonce consumed");
    }

    /* --------------------------------- create ---------------------------------- */

    function test_swapWithSig_relayerCreatesOrder_andGrantsExecutor() public {
        uint256 makerBefore = token0.balanceOf(maker);
        AsyncOrder memory order = _createSigned();

        (uint256 storedIn, uint256 storedOutMin) = hook.asyncOrderInfo(poolId, _id(order));
        assertEq(storedIn, AMOUNT_IN, "amountIn escrowed");
        assertEq(storedOutMin, AMOUNT_OUT_MIN, "amountOutMin stored");
        assertEq(token0.balanceOf(maker), makerBefore - AMOUNT_IN, "input pulled via Permit2");
        assertTrue(hook.isExecutor(poolId, maker, address(router)), "router authorized by signed grant");
    }

    function test_swapWithSig_skipsGrantWhenAlreadyAuthorized() public {
        _createSigned();
        AsyncOrder memory order = _order(0.9 ether);
        Router.PermitData memory permit = _permit(order, 1, block.timestamp + 1 hours);
        vm.prank(relayer);
        router.swapWithSig(order, permit, _noGrant());
        bytes32 id = _orderIdFor(maker, true, _expectedSalt(maker, AMOUNT_IN, 0.9 ether));
        (uint256 storedIn,) = hook.asyncOrderInfo(poolId, id);
        assertEq(storedIn, AMOUNT_IN, "second order without grant");
    }

    function test_swapWithSig_revertsWithoutExecutorGrant() public {
        AsyncOrder memory order = _order(AMOUNT_OUT_MIN);
        Router.PermitData memory permit = _permit(order, 0, block.timestamp + 1 hours);
        vm.prank(relayer);
        vm.expectRevert();
        router.swapWithSig(order, permit, _noGrant());
    }

    function test_swapWithSig_revertsWhenRelayerAltersPrice() public {
        AsyncOrder memory order = _order(AMOUNT_OUT_MIN);
        Router.PermitData memory permit = _permit(order, 0, block.timestamp + 1 hours);
        order.amountOutMin = 1; // relayer tries to dump the maker's input at a worse price
        Router.ExecutorGrant memory grant = _grant(0);
        vm.prank(relayer);
        vm.expectRevert(PERMIT2_INVALID_SIGNER);
        router.swapWithSig(order, permit, grant);
    }

    function test_swapWithSig_replayReverts() public {
        AsyncOrder memory order = _order(AMOUNT_OUT_MIN);
        Router.PermitData memory permit = _permit(order, 0, block.timestamp + 1 hours);
        vm.prank(relayer);
        router.swapWithSig(order, permit, _grant(0));
        vm.prank(relayer);
        vm.expectRevert(PERMIT2_INVALID_NONCE);
        router.swapWithSig(order, permit, _noGrant());
    }

    function test_swapWithSig_thenFill() public {
        AsyncOrder memory order = _createSigned();
        uint256 makerOutBefore = token1.balanceOf(maker);

        vm.startPrank(bob);
        token1.approve(address(router), type(uint256).max);
        router.fillOrder(order, type(uint256).max, "");
        vm.stopPrank();

        assertEq(token1.balanceOf(maker), makerOutBefore + AMOUNT_OUT_MIN, "maker paid limit price");
        (uint256 storedIn,) = hook.asyncOrderInfo(poolId, _id(order));
        assertEq(storedIn, 0, "order cleared");
    }

    /* ------------------------------- update price ------------------------------ */

    function _updateSig(AsyncOrder memory order, uint256 newOut, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = OrderSignatures.hashUpdatePrice(order, _id(order), AMOUNT_IN, newOut, nonce, deadline);
        return _sign(_digest(hook.DOMAIN_SEPARATOR(), structHash));
    }

    function test_updatePriceWithSig_relayerUpdates() public {
        AsyncOrder memory order = _createSigned();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _updateSig(order, 0.99 ether, 7, deadline);

        vm.prank(relayer);
        hook.updatePriceWithSig(order, 0.99 ether, 7, deadline, sig);

        (, uint256 storedOutMin) = hook.asyncOrderInfo(poolId, _id(order));
        assertEq(storedOutMin, 0.99 ether, "price updated");
        assertTrue(hook.nonceUsed(maker, 7), "nonce burned");

        vm.prank(relayer);
        vm.expectRevert(AsyncSwap.NonceAlreadyUsed.selector);
        hook.updatePriceWithSig(order, 0.99 ether, 7, deadline, sig);
    }

    function test_updatePriceWithSig_rejectsWrongSigner() public {
        AsyncOrder memory order = _createSigned();
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = OrderSignatures.hashUpdatePrice(order, _id(order), AMOUNT_IN, 1, 1, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, _digest(hook.DOMAIN_SEPARATOR(), structHash));

        vm.prank(relayer);
        vm.expectRevert(AsyncSwap.InvalidSignature.selector);
        hook.updatePriceWithSig(order, 1, 1, deadline, abi.encodePacked(r, s, v));
    }

    function test_updatePriceWithSig_rejectsTamperedPrice() public {
        AsyncOrder memory order = _createSigned();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _updateSig(order, 0.99 ether, 1, deadline);

        vm.prank(relayer);
        vm.expectRevert(AsyncSwap.InvalidSignature.selector);
        hook.updatePriceWithSig(order, 1, 1, deadline, sig);
    }

    function test_updatePriceWithSig_rejectsExpired() public {
        AsyncOrder memory order = _createSigned();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _updateSig(order, 0.99 ether, 1, deadline);
        vm.warp(deadline + 1);

        vm.prank(relayer);
        vm.expectRevert(AsyncSwap.SignatureExpired.selector);
        hook.updatePriceWithSig(order, 0.99 ether, 1, deadline, sig);
    }

    function test_invalidateNonce_revokesSignedUpdate() public {
        AsyncOrder memory order = _createSigned();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _updateSig(order, 0.99 ether, 3, deadline);

        vm.prank(maker);
        hook.invalidateNonce(3);

        vm.prank(relayer);
        vm.expectRevert(AsyncSwap.NonceAlreadyUsed.selector);
        hook.updatePriceWithSig(order, 0.99 ether, 3, deadline, sig);
    }

    /* ---------------------------------- cancel --------------------------------- */

    function _cancelSig(AsyncOrder memory order, uint256 nonce, uint256 deadline, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = OrderSignatures.hashCancel(order, _id(order), AMOUNT_IN, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(router.DOMAIN_SEPARATOR(), structHash));
        return abi.encodePacked(r, s, v);
    }

    function test_cancelWithSig_returnsInputToMaker() public {
        AsyncOrder memory order = _createSigned();
        uint256 makerBefore = token0.balanceOf(maker);
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(relayer);
        router.cancelWithSig(order, 0, deadline, _cancelSig(order, 0, deadline, makerPk));

        assertEq(token0.balanceOf(maker), makerBefore + AMOUNT_IN, "input returned");
        (uint256 storedIn,) = hook.asyncOrderInfo(poolId, _id(order));
        assertEq(storedIn, 0, "order cleared");
    }

    function test_cancelWithSig_rejectsWrongSigner() public {
        AsyncOrder memory order = _createSigned();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _cancelSig(order, 0, deadline, 0xBAD);

        vm.prank(relayer);
        vm.expectRevert(Router.InvalidSignature.selector);
        router.cancelWithSig(order, 0, deadline, sig);
    }

    function test_cancelWithSig_rejectsExpired() public {
        AsyncOrder memory order = _createSigned();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _cancelSig(order, 0, deadline, makerPk);
        vm.warp(deadline + 1);

        vm.prank(relayer);
        vm.expectRevert(Router.SignatureExpired.selector);
        router.cancelWithSig(order, 0, deadline, sig);
    }

    /// @dev L-02: an identical order re-placed in the same block gets the same id; the used
    ///      cancel nonce must stop the old signature from cancelling the replacement.
    function test_cancelWithSig_rejectsReplayOnRecurringOrderId() public {
        AsyncOrder memory order = _createSigned();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _cancelSig(order, 0, deadline, makerPk);
        vm.prank(relayer);
        router.cancelWithSig(order, 0, deadline, sig);

        AsyncOrder memory again = _order(AMOUNT_OUT_MIN);
        Router.PermitData memory permit = _permit(again, 1, block.timestamp + 1 hours);
        vm.prank(relayer);
        router.swapWithSig(again, permit, _noGrant());
        (uint256 storedIn,) = hook.asyncOrderInfo(poolId, _id(order));
        assertEq(storedIn, AMOUNT_IN, "same order id reused");

        vm.prank(relayer);
        vm.expectRevert(Router.NonceAlreadyUsed.selector);
        router.cancelWithSig(order, 0, deadline, sig);
    }

    /* ------------------------------ type strings ------------------------------- */

    /// @dev Pins the exact EIP-712 strings the frontend must reproduce for wallets to show the fields.
    function test_typeStrings() public pure {
        assertEq(
            OrderSignatures.PERMIT2_WITNESS_TYPE,
            "AsyncOrder witness)AsyncOrder(address maker,address tokenIn,address tokenOut,uint256 amountIn,uint256 amountOutMin,PoolKey pool)PoolKey(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)TokenPermissions(address token,uint256 amount)"
        );
        assertEq(
            OrderSignatures.ASYNC_ORDER_TYPEHASH,
            keccak256(
                "AsyncOrder(address maker,address tokenIn,address tokenOut,uint256 amountIn,uint256 amountOutMin,PoolKey pool)PoolKey(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)"
            )
        );
        assertEq(
            OrderSignatures.CANCEL_ORDER_TYPEHASH,
            keccak256(
                "CancelOrder(address maker,address tokenIn,address tokenOut,uint256 amountIn,bytes32 orderId,uint256 nonce,uint256 deadline)"
            )
        );
    }
}
