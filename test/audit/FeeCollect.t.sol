// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ISignatureTransfer} from "@async-swap/interfaces/ISignatureTransfer.sol";
import {Permit2Bytecode} from "../utils/Permit2Bytecode.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {FeeVault} from "@async-swap/FeeVault.sol";
import {Router} from "@async-swap/Router.sol";
import {CurrencySettler} from "@async-swap/libraries/CurrencySettler.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {Test, stdError} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Currency, IPoolManager, SwapParams} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

/// @dev Maker that is also its own executor. Creates an order and fills it in one unlock, paying
///      exactly `pay` of the output currency. Used to show the fee is enforced by the hook, not
///      only by the Router.
contract SelfExecutor {
    using CurrencySettler for Currency;

    IPoolManager pm;
    AsyncSwap hook;
    PoolKey key;

    constructor(IPoolManager _pm, AsyncSwap _hook, PoolKey memory _key) {
        pm = _pm;
        hook = _hook;
        key = _key;
        hook.setExecutor(PoolIdLibrary.toId(_key), address(this), true);
    }

    function run(bool zeroForOne, uint256 amountIn, uint256 amountOutMin, uint256 pay) external {
        pm.unlock(abi.encode(zeroForOne, amountIn, amountOutMin, pay));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool zfo, uint256 amountIn, uint256 amountOutMin, uint256 pay) =
            abi.decode(data, (bool, uint256, uint256, uint256));
        Currency input = zfo ? key.currency0 : key.currency1;
        Currency output = zfo ? key.currency1 : key.currency0;

        pm.swap(
            key,
            SwapParams(zfo, -int256(amountIn), 2 ** 96),
            abi.encode(AsyncSwap.UserParams({user: address(this), executor: address(this), amountOutMin: amountOutMin}))
        );
        input.settle(pm, address(this), amountIn, false);

        bytes32 salt =
            keccak256(abi.encode(block.timestamp, block.number, address(pm), address(this), amountIn, amountOutMin));
        AsyncOrder memory o = AsyncOrder(key, address(this), zfo, amountIn, amountOutMin, 0, salt);

        if (output.isAddressZero()) {
            (bool ok,) = address(hook).call{value: pay}("");
            require(ok, "fwd");
        } else {
            pm.sync(output);
            MockERC20(Currency.unwrap(output)).transfer(address(pm), pay);
            pm.settleFor(address(hook));
        }
        hook.executeOrder(o, abi.encode(address(this)));
        return "";
    }

    receive() external payable {}
}

/// @dev Tries to pull ERC-6909 fee claims out of the vault without being the vault.
contract ClaimThief {
    IPoolManager pm;
    address vault;

    constructor(IPoolManager _pm, address _vault) {
        pm = _pm;
        vault = _vault;
    }

    function burnViaUnlock(uint256 id, uint256 amount) external {
        pm.unlock(abi.encode(id, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (uint256 id, uint256 amount) = abi.decode(data, (uint256, uint256));
        pm.burn(vault, id, amount); // reverts: no allowance / operator
        pm.take(Currency.wrap(address(0)), address(this), amount);
        return "";
    }
}

/// @dev Native-output maker whose receive() re-enters mid-fill, while the hook still holds a
///      positive ETH delta equal to the not-yet-minted fee. Tries to spend that credit on a
///      second native-output order it executes itself.
contract FeeCreditGrabber {
    Router router;
    AsyncSwap hook;
    PoolKey key;
    PoolId poolId;
    MockERC20 erc20;

    AsyncOrder public second;
    bool public armed;
    bool public reentryReverted;
    bytes public reentryError;

    constructor(Router _router, AsyncSwap _hook, PoolKey memory _key, MockERC20 _erc20) {
        router = _router;
        hook = _hook;
        key = _key;
        poolId = PoolIdLibrary.toId(_key);
        erc20 = _erc20;
        hook.setExecutor(poolId, address(_router), true);
        hook.setExecutor(poolId, address(this), true);
        erc20.approve(address(router), type(uint256).max);
    }

    function submit(uint256 amountIn, uint256 amountOutMin) external {
        AsyncOrder memory o = AsyncOrder(key, address(this), false, amountIn, amountOutMin, 2 ** 96, bytes32(0));
        router.swap(
            o,
            abi.encode(
                AsyncSwap.UserParams({user: address(this), executor: address(router), amountOutMin: amountOutMin})
            )
        );
    }

    function arm(AsyncOrder calldata o) external {
        second = o;
        armed = true;
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        // Hook currently has +fee_A ETH delta. Execute `second` (native output) without depositing.
        (bool ok, bytes memory err) = address(hook)
            .call(abi.encodeWithSelector(AsyncSwap.executeOrder.selector, second, abi.encode(address(this))));
        reentryReverted = !ok;
        reentryError = err;
    }
}

contract FeeCollectTest is Test {
    using PoolIdLibrary for PoolKey;

    address owner = makeAddr("deployer");
    address bob = makeAddr("bob");
    address treasury = makeAddr("treasury");
    IPoolManager manager;
    AsyncSwap hook;
    Router router;
    FeeVault vault;
    MockERC20 erc20;
    Currency eth = Currency.wrap(address(0));
    Currency tok;
    PoolKey key;
    PoolId poolId;

    function setUp() public {
        manager = new PoolManager(owner);
        erc20 = new MockERC20("Test Token", "TST", 18);
        tok = Currency.wrap(address(erc20));
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        deployCodeTo("AsyncSwap.sol", abi.encode(manager, tok, address(this)), address(flags));
        hook = AsyncSwap(payable(address(flags)));
        vault = hook.feeVault();
        router = new Router(manager, hook, ISignatureTransfer(Permit2Bytecode.PERMIT2));
        key = PoolKey({currency0: eth, currency1: tok, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 1, hooks: hook});
        poolId = key.toId();
        manager.initialize(key, 2 ** 96);
        vm.deal(bob, 100 ether);
        erc20.mint(bob, 100 ether);
    }

    function _salt(address user, uint256 amountIn, uint256 amountOutMin) internal view returns (bytes32) {
        return keccak256(abi.encode(block.timestamp, block.number, address(manager), user, amountIn, amountOutMin));
    }

    /* ---------------- fee is enforced by the hook, not just the Router ---------------- */

    function test_customExecutor_underpayingFee_ERC20Output_reverts() public {
        SelfExecutor s = new SelfExecutor(manager, hook, key);
        vm.deal(address(s), 1 ether);
        erc20.mint(address(s), 10 ether);
        uint256 amountOutMin = 1 ether;
        uint256 fee = hook.calculatePoolFee(key.fee, amountOutMin);
        assertGt(fee, 0);

        // Pays net only: hook is left -fee in TST, unlock fails.
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        s.run(true, 1 ether, amountOutMin, amountOutMin);
        // Pays one wei short of gross.
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        s.run(true, 1 ether, amountOutMin, amountOutMin + fee - 1);
        assertEq(manager.balanceOf(address(vault), tok.toId()), 0);

        // Exact gross works and the fee lands in the vault.
        s.run(true, 1 ether, amountOutMin, amountOutMin + fee);
        assertEq(manager.balanceOf(address(vault), tok.toId()), fee);
        assertEq(erc20.balanceOf(address(s)), 10 ether - fee); // paid gross, got net back
    }

    function test_customExecutor_underpayingFee_nativeOutput_reverts() public {
        SelfExecutor s = new SelfExecutor(manager, hook, key);
        vm.deal(address(s), 10 ether);
        erc20.mint(address(s), 1 ether);
        uint256 amountOutMin = 1 ether;
        uint256 fee = hook.calculatePoolFee(key.fee, amountOutMin);

        vm.expectRevert(AsyncSwap.UnaccountedNativeOutput.selector);
        s.run(false, 1 ether, amountOutMin, amountOutMin);
        vm.expectRevert(AsyncSwap.UnaccountedNativeOutput.selector);
        s.run(false, 1 ether, amountOutMin, amountOutMin + fee - 1);
        assertEq(manager.balanceOf(address(vault), eth.toId()), 0);

        s.run(false, 1 ether, amountOutMin, amountOutMin + fee);
        assertEq(manager.balanceOf(address(vault), eth.toId()), fee);
        assertEq(address(s).balance, 10 ether - fee);
        assertEq(address(hook).balance, 0, "no ETH stranded in hook");
    }

    /* ---------------- vault claims cannot be moved by anyone but the owner ---------------- */

    function _fillOneNativeOutputOrder() internal returns (uint256 fee) {
        // bob is maker (TST in, ETH out) and filler.
        vm.startPrank(bob);
        hook.setExecutor(poolId, address(router), true);
        erc20.approve(address(router), type(uint256).max);
        AsyncOrder memory o = AsyncOrder(key, bob, false, 1 ether, 1 ether, 2 ** 96, bytes32(0));
        router.swap(o, abi.encode(AsyncSwap.UserParams(bob, address(router), 1 ether)));
        o.salt = _salt(bob, 1 ether, 1 ether);
        fee = hook.calculatePoolFee(key.fee, 1 ether);
        router.fillOrder{value: 1 ether + fee}(o, type(uint256).max, "");
        vm.stopPrank();
        assertEq(manager.balanceOf(address(vault), eth.toId()), fee);
    }

    function test_thirdParty_cannotTransferOrBurnVaultClaims() public {
        uint256 fee = _fillOneNativeOutputOrder();
        uint256 id = eth.toId();

        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError); // allowance underflow
        manager.transferFrom(address(vault), bob, id, fee);

        ClaimThief t = new ClaimThief(manager, address(vault));
        vm.expectRevert(stdError.arithmeticError); // burn: allowance underflow
        t.burnViaUnlock(id, fee);

        assertEq(manager.balanceOf(address(vault), id), fee);
        assertFalse(manager.isOperator(address(vault), bob));
        assertEq(manager.allowance(address(vault), bob, id), 0);
    }

    function test_ownerCannotReachEscrow_onlyFees() public {
        // open an unfilled order; its input sits as hook claims
        vm.startPrank(bob);
        hook.setExecutor(poolId, address(router), true);
        erc20.approve(address(router), type(uint256).max);
        AsyncOrder memory o = AsyncOrder(key, bob, false, 5 ether, 1 ether, 2 ** 96, bytes32(0));
        router.swap(o, abi.encode(AsyncSwap.UserParams(bob, address(router), 1 ether)));
        vm.stopPrank();
        uint256 fee = _fillOneNativeOutputOrder();

        vault.collect(tok, treasury);
        vault.collect(eth, treasury);
        hook.sweep(tok, treasury);
        hook.sweep(eth, treasury);

        assertEq(treasury.balance, fee, "owner got exactly the fee");
        assertEq(erc20.balanceOf(treasury), 0, "owner got none of the escrow");
        assertEq(manager.balanceOf(address(hook), tok.toId()), 5 ether, "escrow intact");
    }

    /* ---------------- mid-fill reentrancy cannot capture the unminted fee credit ---------------- */

    function test_reentrantMaker_cannotSpendHookFeeCredit() public {
        FeeCreditGrabber m = new FeeCreditGrabber(router, hook, key, erc20);
        erc20.mint(address(m), 10 ether);

        // Order A: big, gets filled by bob. Order B: tiny, so amountOutMin_B + fee_B <= fee_A.
        uint256 outA = 10 ether;
        uint256 feeA = hook.calculatePoolFee(key.fee, outA);
        uint256 outB = feeA / 2;
        m.submit(1 ether, outA);
        m.submit(1 ether, outB);
        AsyncOrder memory a =
            AsyncOrder(key, address(m), false, 1 ether, outA, 2 ** 96, _salt(address(m), 1 ether, outA));
        AsyncOrder memory b =
            AsyncOrder(key, address(m), false, 1 ether, outB, 2 ** 96, _salt(address(m), 1 ether, outB));
        m.arm(b);

        uint256 mBefore = address(m).balance;
        vm.prank(bob);
        router.fillOrder{value: outA + feeA}(a, type(uint256).max, "");

        assertTrue(m.reentryReverted(), "reentrant executeOrder must fail");
        assertEq(bytes4(m.reentryError()), AsyncSwap.UnaccountedNativeOutput.selector);
        assertEq(address(m).balance - mBefore, outA, "maker got exactly net A");
        assertEq(manager.balanceOf(address(vault), eth.toId()), feeA, "full fee A in vault");
        assertEq(
            hook.asyncOrder(poolId, keccak256(abi.encode(block.chainid, poolId, address(m), false, b.salt))),
            1 ether,
            "B untouched"
        );
    }

    /* ---------------- robustness: collect has no amount parameter ---------------- */

    function test_info_collectRevertsIfClaimsExceedInt128() public {
        // Only reachable with a worthless attacker-minted token; included to document the limit.
        MockERC20 junk = new MockERC20("Junk", "JNK", 18);
        Currency j = Currency.wrap(address(junk));
        uint256 huge = uint256(uint128(type(int128).max)) + 1;
        JunkMinter jm = new JunkMinter(manager, address(vault), junk);
        junk.mint(address(jm), huge);
        jm.go(huge);
        assertEq(manager.balanceOf(address(vault), j.toId()), huge);

        vm.expectRevert(SafeCast.SafeCastOverflow.selector); // burn() casts the full balance to int128
        vault.collect(j, treasury);
        // Other currencies unaffected.
        uint256 fee = _fillOneNativeOutputOrder();
        vault.collect(eth, treasury);
        assertEq(treasury.balance, fee);
    }
}

contract JunkMinter {
    IPoolManager pm;
    address vault;
    MockERC20 junk;

    constructor(IPoolManager _pm, address _vault, MockERC20 _junk) {
        pm = _pm;
        vault = _vault;
        junk = _junk;
    }

    function go(uint256 amount) external {
        pm.unlock(abi.encode(amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        uint256 amount = abi.decode(data, (uint256));
        Currency c = Currency.wrap(address(junk));
        // Mint in two halves: each settle/mint must itself fit int128.
        for (uint256 i; i < 2; i++) {
            uint256 part = i == 0 ? amount / 2 : amount - amount / 2;
            pm.sync(c);
            junk.transfer(address(pm), part);
            pm.settle();
            pm.mint(vault, c.toId(), part);
        }
        return "";
    }
}
