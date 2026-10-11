# AsyncSwap Protocol

AsyncSwap is a peer-to-peer order protocol built as a Uniswap v4 hook. A maker
posts a full-fill order; a filler can settle it when the maker's limit is met.
The maker signs the order terms and submits the transaction from their wallet.
There is no relayer requirement.

## Contract rules

- **Full fills only.** Partial fills are planned for a future version.
- **USDC numeraire.** Every pool using an AsyncSwap hook must pair one asset with
  that deployment's configured USDC. This rule applies to anyone initializing a
  pool with the hook; unrelated v4 pools are unaffected.
- **0.2% protocol fee.** The fee is taken from gross output on successful fills.
  The maker's signed minimum is net of the fee; creation and cancellation have
  no protocol fee.
- **Signed actions.** EIP-712 signatures support create, authorize, reprice, and
  cancel actions. ERC-1271 wallets are supported. ERC-20 input uses Permit2;
  native ETH input requires a transaction.

## Contracts

- [`src/AsyncSwap.sol`](src/AsyncSwap.sol) — v4 hook, order state, numeraire
  check, and fee accounting.
- [`src/Router.sol`](src/Router.sol) — maker and filler entry points.
- [`src/libraries/AsyncFiller.sol`](src/libraries/AsyncFiller.sol) — order
  storage and full-fill, reprice, and cancel logic.

## Build and test

```sh
forge soldeer install
forge build
forge test
forge fmt --check
```

## Deployment

The checked deployment flow currently targets Unichain mainnet only. The
existing addresses in `deployments/130/130.json` may refer to an earlier version;
the current source changes require a new hook and Router deployment, followed
by initialization of new pools. Existing pools and open orders remain on their
current hook.

- [Deployment runbook](DEPLOYMENT.md) — inputs, preflight, broadcast, and pool initialization.
- [Chain configuration](script/config/chains.json) — configured networks and readiness.
- [Signed-message metadata](ERC-7730.md) — wallet display metadata and release checks.
- [USDC numeraire spec](docs/specs/usdc-numeraire.md) — scope and rationale.

Do not enable the new deployment in the frontend or publish wallet metadata
until the deployed addresses, supported chains, and security review are final.
