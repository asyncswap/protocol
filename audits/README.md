# Audits

Security reports for the AsyncSwap protocol, and the status of every finding.

| Report | Date | Author | Scope |
|--------|------|--------|-------|
| [lee-audit.md](lee-audit.md) | 2026-05-08 | Lee, 33 Labs | Full protocol |
| [H05-native-overpay-stranded.md](H05-native-overpay-stranded.md) | 2026-08-08 | Meek | Follow-up to lee-audit |
| [claude-audit.md](claude-audit.md) | 2026-10-10 | Claude Code (AI-assisted) | Full protocol at `760699a` |

## Status key

| Status | Meaning |
|--------|---------|
| ✅ Fixed | Code changed; a regression test reproduces the issue on the old code and passes on the fix. |
| 🟢 Works as expected | Reviewed; current behaviour is correct or intended, no code change needed. |
| 📝 Acknowledged | Real but accepted; not fixed, with a stated reason. |
| ❌ Rejected | Not a valid issue. |
| ⏳ Open | Not yet addressed. |

Each report's IDs are its own (lee-audit L-01 and claude-audit.md L-01 are different findings), so findings are grouped by report below. Regression tests for `claude-audit.md` use the `SR_` prefix.

## lee-audit.md

| ID | Severity | Finding | Status | Evidence |
|----|----------|---------|--------|----------|
| C-01 | Critical | Native escrow commingled in hook balance, so a self-owned native-output order drains it | ✅ Fixed | Per-tx native deposit ledger; `test/audit/C01_CommingledEscrow.t.sol` |
| H-01 | High | Maker front-runs a fill with `updatePrice` | ✅ Fixed | `maxPrice` cap on `fillOrder`; `test/audit/H01_MakerFrontrun.t.sol` |
| H-02 | High | Forged `hookData` grants executor rights over a victim's orders | ✅ Fixed | Executor must be pre-authorized by the maker; `test/audit/H02_ExecutorForgery.t.sol` |
| H-03 | High | Stranded ETH extractable via a `msg.value = 0` native order plus cancel | ✅ Fixed | Exact `msg.value` check; `test/audit/H03_StrandedEth.t.sol` |
| H-04 | High | `Router.swap` NatSpec disagrees with code on where `amountOutMin` comes from | ✅ Fixed | `userData.amountOutMin == order.amountOutMin` enforced; `test/audit/H04_NatspecMismatch.t.sol` |
| L-01 | Low | `setExecutor` has no revoke path | 🟢 Works as expected | `setExecutor(poolId, executor, false)` revokes; `test/audit/OwnerDirectCancel.t.sol` |
| L-02 | Low | `Router.swap` doesn't enforce `order.owner == msg.sender` | ✅ Fixed | Owner and user guards; `test/audit/L02_MakerIdentity.t.sol` |
| L-03 | Low | Native overpayment to `Router.swap` not refunded | ✅ Fixed | Covered by the H-03 fix (exact `msg.value`); `test/audit/H03_StrandedEth.t.sol` |
| I-01 | Info | Fee portion of `amountTaken` never burned (6909 leak) | ✅ Fixed | Fees minted to `FeeVault` only on fill; `test/audit/I01_FeeClaims.t.sol` |

## H05-native-overpay-stranded.md

| ID | Severity | Finding | Status | Evidence |
|----|----------|---------|--------|----------|
| H-05 | High | Native-output fill overpayment permanently stranded in the hook | ✅ Fixed | `msg.value` must equal the live price plus fee; `test/audit/H05_NativeOverpayStranded.t.sol` |
| — | — | Native reentrancy defense (hardening, no written finding) | ✅ Fixed | `test/audit/H06_NativeReentrancyDefense.t.sol` |

## claude-audit.md

| ID | Severity | Finding | Status | Evidence |
|----|----------|---------|--------|----------|
| M-01 | Medium | Anyone can steal ERC20 sitting in the hook through `executeOrder` | ✅ Fixed | ERC20 output is paid into the PoolManager and credited to the hook with `settleFor`; the hook never spends its own token balance. `test/audit/SR_M01_ERC20StrandedDrain.t.sol` |
| M-02 | Medium | Scripted CREATE2 deploy makes the deterministic deployer the hook owner, locking fees | ✅ Fixed | Constructor takes an explicit `_owner`; the deploy script passes `OWNER` and asserts it. `test_ownerIsExplicitArgumentNotDeployer` in `test/Numeraire.t.sol` |
| L-01 | Low | Anyone can open orders that appear to belong to another maker | ✅ Fixed | `_beforeSwap` requires `sender == hookData.executor`; `test/audit/SR_L01_OrderSpoofing.t.sol` |
| L-02 | Low | Signed `CancelOrder` replayable on a recurring order ID | ✅ Fixed | `CancelOrder` carries a nonce, burned in `Router.cancelNonceUsed`; `test_cancelWithSig_rejectsReplayOnRecurringOrderId` in `test/SignedOrders.t.sol` |
| L-03 | Low | Tokens that don't return a bool can't be traded | ✅ Fixed | Production `src/libraries/CurrencySettler.sol` uses OpenZeppelin `SafeERC20`; the Router uses `safeTransferFrom`. `test/audit/SR_L03_NoReturnToken.t.sol` |
| I-01 | Info | Ownership transfers in a single step | ✅ Fixed | `transferOwnership` + `acceptOwnership`; `test_collectionAuthorizationFollowsOwnership` in `test/audit/I01_FeeClaims.t.sol` |
| I-02 | Info | Fee rounds to zero on orders under 499 base units | 📝 Acknowledged | Under $0.0005 for 6-decimal USDC. The fee itself is exactly 0.2% of gross, as documented. |
| I-03 | Info | String revert instead of a custom error | ✅ Fixed | `DynamicFeeRequired()` |

### Breaking changes from the claude-audit.md fixes

These need a Router and hook redeploy, and frontend updates:

- `Router.cancelWithSig(order, deadline, sig)` is now `cancelWithSig(order, nonce, deadline, sig)`, and the `CancelOrder` EIP-712 type gains `uint256 nonce` before `deadline`. Update `src/app/data/orderSignatures.ts` and `orderTransactions.ts` in the app repo.
- Ownership transfer now takes two steps: the new owner must call `acceptOwnership()`.
- The `AsyncSwap` constructor takes a third argument, `address _owner`. Use `(poolManager, numeraire, owner)` when verifying on Uniscan.
- `foundry.toml` now enables the optimizer (`optimizer_runs = 1_000_000`). Without it, `AsyncSwap` was 25,525 bytes, over the EIP-170 limit of 24,576, and could not be deployed; it is now 18,375 bytes. Verify with the same compiler settings.
- Custom executors (not the Router) must call `PoolManager.swap` themselves (L-01), and for ERC20 output must pay into the PoolManager and call `settleFor(hook)` before `executeOrder` (M-01).
