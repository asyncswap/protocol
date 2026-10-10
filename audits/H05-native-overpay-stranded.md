# AsyncSwap Protocol — Follow-up Finding

**Date**: 2026-08-08
**Target**: `src/Router.sol` · `src/AsyncSwap.sol` · `src/libraries/AsyncFiller.sol`
**Author**: Meek
**Status**: Fixed at submission (2026-10-10): native `msg.value` must equal the live stored price.

Extends the [lee-audit](lee-audit.md) run. This is a new finding not covered there.

---

## Summary

| Severity | Count |
|----------|-------|
| High | 1 |

---

## Findings

### [H-05] Native-output fill overpayment is permanently stranded in the hook

**What's wrong**

`Router.fillOrder` validates the filler's `msg.value` against the **caller-supplied** `order.amountOutMin` struct field, but the maker is only paid the **live** price read from hook storage. `order.amountOutMin` is not part of the `orderId`, so it is never checked against the live price. Any positive difference `msg.value − livePrice` is left in the hook's raw ETH balance with no way to reclaim it. The ERC20-output branch does not have this gap — it pulls exactly `livePrice` — so only native-output fillers can lose funds.

**How (mechanism)**

`Router.fillOrder` requires `msg.value == order.amountOutMin` ([Router.sol:115](../src/Router.sol#L115)) and forwards the full `msg.value` to the hook via `address(HOOK).call{value: msg.value}` ([Router.sol:116](../src/Router.sol#L116)); `receive()` credits it to a transient pending ledger ([AsyncSwap.sol:282](../src/AsyncSwap.sol#L282)). Settlement then reads the live stored price via `HOOK.asyncOrderInfo` ([Router.sol:181](../src/Router.sol#L181)) and `AsyncFiller.fill` settles/takes only `amountOutMin` (the live value) to the maker ([AsyncFiller.sol:116-117](../src/libraries/AsyncFiller.sol#L116-L117)). `executeOrder` decrements the pending ledger by only the live `amountOutMin` ([AsyncSwap.sol:189](../src/AsyncSwap.sol#L189)). The residual `msg.value − livePrice` stays in `address(hook).balance`; there was no `withdraw`/`sweep`/`recover` path in `src/`. The `maxPrice` guard does not help — it only blocks *upward* price moves (`require(livePrice <= maxPrice)`), while overpayment arises when the live price is *below* the filler's supplied value.

Contrast the ERC20-output branch, which pulls exactly `livePrice` from the filler ([Router.sol:191](../src/Router.sol#L191)) and therefore cannot overpay.

**Severity**: High  **Confidence**: High  **Class**: DeltaAccounting / TokenEdgeCases
**Location**: `Router.sol:fillOrder` / `AsyncSwap.sol:executeOrder` / `AsyncFiller.sol:fill`

**Exploit Path**

1. Maker creates a native-output order (`zeroForOne = false`: deposit TST, receive ETH) with `amountOutMin = 1 ETH`.
2. Trigger (either):
   - **(a) stale price** — filler broadcasts a struct carrying `amountOutMin = 1 ETH` while the live stored price is lower (e.g. 0.6 ETH). The `orderId` excludes `amountOutMin`, so the fill still targets the live order.
   - **(b) maker front-run** — maker calls `updatePrice` to lower the live price to 0.6 ETH after the filler broadcasts (griefing; maker gains nothing, filler loses).
3. Filler calls `Router.fillOrder{value: 1 ETH}(order, type(uint256).max, "")`. `msg.value` is checked against the struct's 1 ETH and forwarded to the hook.
4. `fill` settles only the live 0.6 ETH to the maker; the pending ledger is decremented by 0.6 ETH.
5. The 0.4 ETH excess remains in `address(hook).balance`, unreachable by the filler or maker.

**Expected Delta**: filler loses `msg.value − livePrice` per fill (40% of payment in the tested case); funds are locked in the hook, not gained by the maker.

**PoC** — `[POC-PASS]` Run: `forge test --match-contract H05_NativeOverpayStranded -vv`.

Full test: [`test/audit/H05_NativeOverpayStranded.t.sol`](../test/audit/H05_NativeOverpayStranded.t.sol). Native pools sort ETH to `currency0`, so native output requires `zeroForOne = false`. Key assertions from scenario (a):

```solidity
// live price 0.6 ETH; filler broadcasts a struct with amountOutMin = 1 ETH
AsyncOrder memory order = _createNativeOutputOrder(1 ether, 0.6 ether);
AsyncOrder memory staleOrder = order;
staleOrder.amountOutMin = 1 ether; // orderId excludes amountOutMin -> same order

vm.prank(bob);
router.fillOrder{value: 1 ether}(staleOrder, type(uint256).max, "");

assertEq(bobEthBefore - bob.balance, 1 ether,   "filler paid full msg.value");
assertEq(alice.balance - aliceEthBefore, 0.6 ether, "maker received only live price");
assertEq(address(hook).balance, 0.4 ether,      "0.4 ETH stranded in hook");
// no withdraw()/sweep() selector existed pre-fix -> ETH unrecoverable
```

Results: 3/3 pre-fix tests pass — `test_H05_frontrunUpdatePrice_excessStranded` and `test_H05_staleHigherStructPrice_excessStranded` each strand **0.4 ETH (40%)**; the control `test_H05_control_fairFill_noStranding` (msg.value == live) strands **0**.

**Current fix (2026-10-10)**

`Router.fillOrder` reads the order's live `amountOutMin` and requires
`msg.value == livePrice` before forwarding ETH. A stale higher quote, inflated
struct amount, or underpayment reverts atomically: the deposit stays with the
filler, balances are unchanged, and the order remains open. The filler can refresh
and retry with the live price. `maxPrice` still caps the accepted price.

This deliberately rejects stale native deposits instead of introducing a refund
callback. ERC-20 fills already pull exactly the live price and are unchanged.

The earlier owner-only `sweep` mitigation recovered overpayments for the protocol,
not for the filler. It is retained for donations/accumulated balances, but is no
longer relied on to address this finding. The exploit examples above document the
historical behavior, not the current implementation.

**Regression coverage**: `test/audit/H05_NativeOverpayStranded.t.sol` tests a maker
lowering the price, an inflated struct price, insufficient ETH despite a donated
hook balance, fuzzed overpayments, exact live-price fills with stale structs,
`maxPrice` enforcement, fair fills, and donation sweeping without consuming an
open order. The rejection tests were observed failing before the fix.
