# AsyncSwap Protocol

A Uniswap v4 hook that turns an exact-input swap into an open async limit order.
The maker deposits their input via `_beforeSwap`; a filler later settles by
paying the maker's limit-priced output. v1 is full-fill only — partials are not
supported and a successful fill deletes the record entirely.

Built around three contracts:

- **`AsyncSwap.sol`** — the v4 hook. Captures maker input, stores the open order,
  emits `AsyncOrderCreated` / `AsyncOrderFilled` / `AsyncOrderCancelled` /
  `AsyncOrderPriceUpdated` events.
- **`Router.sol`** — thin entrypoint for makers (`swap`), fillers (`fillOrder`),
  and cancellations (`cancelOrder`). Wraps every action in a `PoolManager.unlock`
  context so the hook can do PM-side accounting. Native ETH is supported in
  both directions via `payable` + `msg.value`.
- **`libraries/AsyncFiller.sol`** — per-order storage + fill / cancel /
  updatePrice mechanics. Settles real tokens directly to the maker (no 6909
  withdrawal step required).

## Signed maker actions

Makers sign readable EIP-712 order fields, then submit the transaction with their
own wallet and pay network gas. A separate relayer service is not required. Type strings live in
`libraries/OrderSignatures.sol` and are pinned by `test/SignedOrders.t.sol`.

| Action | Entry point | Signed type | EIP-712 domain |
|---|---|---|---|
| Create | `Router.swapWithSig(order, permit, grant)` | Permit2 `PermitWitnessTransferFrom` with `AsyncOrder` witness (`spender` = Router) | Permit2 |
| First order on a pool | `grant` arg above, or `AsyncSwap.setExecutorWithSig` | `SetExecutor` | `AsyncSwap` v1 (hook) |
| Reprice | `AsyncSwap.updatePriceWithSig` | `UpdatePrice` | `AsyncSwap` v1 (hook) |
| Cancel | `Router.cancelWithSig` | `CancelOrder` | `AsyncSwap Router` v1 |

- The maker approves Permit2 once per input token; subsequent creates use a signature followed by a transaction.
  Native ETH input still goes through `swap`.
- `SetExecutor` / `UpdatePrice` use unordered per-maker nonces (`nonceUsed`); revoke an unsent
  signature with `invalidateNonce`. Create nonces are Permit2's. Cancel needs no nonce (it deletes the order).
- Signatures from smart-contract wallets (ERC-1271) are accepted on the hook and Router paths.

## Deployments

### Unichain (chainId `130`)

| Contract     | Address                                                                                                                  | Verified                                                                                            |
| ------------ | ------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------- |
| AsyncSwap    | [`0x917b2e7C352af82c35C7a4477d7D055C54E76888`](https://uniscan.xyz/address/0x917b2e7c352af82c35c7a4477d7d055c54e76888)    | [Uniscan](https://uniscan.xyz/address/0x917b2e7c352af82c35c7a4477d7d055c54e76888#code) · Sourcify   |
| Router       | [`0x88A76b0991016754425093C8fB440744c5574b75`](https://uniscan.xyz/address/0x88a76b0991016754425093c8fb440744c5574b75)    | [Uniscan](https://uniscan.xyz/address/0x88a76b0991016754425093c8fb440744c5574b75#code) · Sourcify   |
| PoolManager  | [`0x1F98400000000000000000000000000000000004`](https://uniscan.xyz/address/0x1f98400000000000000000000000000000000004)    | (canonical Uniswap v4)                                                                              |

The hook address has the `0x91…` prefix to make it visually identifiable; CREATE2
salt is mined offline by `script/mine-hook-salt.ts`.

The full registry — including the per-chain start block the indexer reads from —
lives at `deployments/<chainId>.json`, written by the deploy scripts.

## Build & test

```sh
# install deps
forge soldeer install

# build
forge build

# run the full test suite (ERC20 pool + native ETH pool)
forge test
```

The native ETH coverage lives in `test/NativeAsyncSwap.t.sol`; the ERC20 pool
coverage lives in `test/AsyncSwap.t.sol`. Both share `test/SetupHook.t.sol` for
the basic deploy + pool init scaffold.

### Pre-commit hook

CI enforces `forge fmt --check`. Enable the local pre-commit hook so commits
are auto-formatted before they leave your machine:

```sh
git config core.hooksPath .githooks
```

The hook runs `forge fmt` on staged `.sol` files and re-stages them, so the
commit always reflects the formatted version. To bypass for a single commit:
`git commit --no-verify`.

## Local pipeline

Run the following scripts against a running local Anvil. Deploy and fund a mock
USDC first, then set `USDC_ADDRESS` to its address before deploying the hook:

```
00 deploy PoolManager  (or record canonical for known chains)
01 deploy hook + Router (mines salt via FFI; verifies prefix + flag bits)
02 init asset/numeraire pool + mint the mock asset
03 swap                 (maker submits an order)
04 cancelOrder          (commented; uncomment to test cancel instead of fill)
05 executeOrder         (filler completes the order)
```

Each script writes / reads from `deployments/<chainId>.json` so subsequent
scripts pick up addresses from the registry, not from `broadcast/` artifacts.
The pool initializer uses the hook's configured numeraire; it does not mint USDC.
For `03_Swap.s.sol`, supply `AMOUNT_IN` and `AMOUNT_OUT_MIN` in their respective
token base units, and optionally `ZERO_FOR_ONE` (default true). Do not use 18-decimal
amounts for 6-decimal USDC. `Trade.s.sol` remains the symbol-based mainnet helper.

## Verifying a fresh deploy on Uniscan

`forge script ... --verify --verifier etherscan` silently routes to Sourcify on
some chains. For Uniscan specifically, run after the deploy:

```sh
forge verify-contract \
  --chain unichain \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch \
  --constructor-args "$(cast abi-encode 'constructor(address,address)' "$POOL_MANAGER" "$USDC_ADDRESS")" \
  <hookAddress> \
  src/AsyncSwap.sol:AsyncSwap

forge verify-contract \
  --chain unichain \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch \
  --constructor-args "$(cast abi-encode 'constructor(address,address,address)' "$POOL_MANAGER" "$HOOK" "$PERMIT2")" \
  <routerAddress> \
  src/Router.sol:Router
```

### USDC numeraire

Every pool attached to this hook must include the exact USDC address configured
at deployment. `AsyncSwap(poolManager, numeraire)` stores that address immutably;
`numeraire()` exposes it. `beforeInitialize` rejects a pool with neither currency
equal to it. USDC can be currency0 or currency1 according to address sorting.
ETH/USDC is supported; ETH/other-token and non-USDC ERC-20 pairs are rejected.

`01_DeployHook.s.sol` requires `USDC_ADDRESS`. Verify it against the issuer's
registry for the target chain before deployment. The constructor rejects zero
and addresses without code, but cannot certify that an arbitrary contract is
issuer-approved USDC. Token names/symbols and decimals do not establish identity.
The address is included in CREATE2 salt mining and constructor verification.

This is a pairing rule, not an oracle or price peg. Order amounts stay in each
token's base units; makers specify the net output they accept. Fees still accrue
in the output token, which can be the asset when buying with USDC. Asset-to-asset
routing through USDC is not implemented by this change.

A new hook deployment and new pools are required. Existing hooks, pools, and open
orders are unaffected. See [the architecture decision](decisions/usdc-numeraire.md).

### Protocol fee claims

The protocol takes 0.2% of gross **output** only on a successful fill. The stored
and signed `amountOutMin` is the maker's **net minimum after fees**. For a fill of
100 USDC, the maker receives 99.8 USDC and the vault earns 0.2 USDC. The filler
receives the entire input deposit. Creation charges no fee; cancellation returns
all input.

`calculatePoolFee(poolFee, netOutput)` returns `netOutput / 499` (integer division).
The filler pays `grossOutput = netOutput + fee`; this guarantees
`fee == floor(grossOutput / 500)` and the exact signed net receipt. Token-unit fees
round down. Router approvals, native deposits and `maxPrice` cover gross output.

Input claims remain in the hook until fill/cancel. On fill the hook settles gross
output, pays the maker the net amount and mints output-currency fee claims to
`hook.feeVault()`. `AsyncOrderFilled` reports full input and net output;
`OrderFeeAccrued` records the output-currency fee separately.

The current `hook.owner()` can call `FeeVault.collect(currency, recipient)` to
redeem that currency's fee claims. Ownership transfers also transfer collection
authority. Collection cannot redeem the hook's open-order claims. Available fees
are `PoolManager.balanceOf(vault, currency.toId())`; `FeesCollected` records
withdrawals. The hook's `sweep` remains for raw donations/stranded balances.

The hook constructor deploys its vault automatically. This requires a new hook
and newly mined salt; existing deployments are unaffected. Regression tests cover
ERC-20/native output, cancellation, access control, failed fills and collection,
rounding, and the production 0.2% rate.
