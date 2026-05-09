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

`dev/start.sh` chains the five scripts against a running local Anvil:

```
00 deploy PoolManager  (or record canonical for known chains)
01 deploy hook + Router (mines salt via FFI; verifies prefix + flag bits)
02 init pool + mint mock tokens
03 swap                 (maker submits an order)
04 cancelOrder          (commented; uncomment to test cancel instead of fill)
05 executeOrder         (filler completes the order)
```

Each script writes / reads from `deployments/<chainId>.json` so subsequent
scripts pick up addresses from the registry, not from `broadcast/` artifacts.

## Verifying a fresh deploy on Uniscan

`forge script ... --verify --verifier etherscan` silently routes to Sourcify on
some chains. For Uniscan specifically, run after the deploy:

```sh
forge verify-contract \
  --chain unichain \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch \
  --constructor-args 0x000000000000000000000000<poolManagerAddress> \
  <hookAddress> \
  src/AsyncSwap.sol:AsyncSwap

forge verify-contract \
  --chain unichain \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --watch \
  --constructor-args 0x000000000000000000000000<poolManagerAddress>000000000000000000000000<hookAddress> \
  <routerAddress> \
  src/Router.sol:Router
```
