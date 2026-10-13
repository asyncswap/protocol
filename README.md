# AsyncSwap Protocol

AsyncSwap adds on-chain limit orders to Uniswap v4. A maker specifies the input
amount and minimum output, then creates an order against a pool. Another
participant can fill it when the terms meet their needs; the Router and hook
settle the trade on-chain. Orders currently fill in full, and makers can update
the limit price or cancel an order while it remains open.

## Contract rules

- **Full fills only.** Partial fills are planned for a future version.
- **USDC numeraire.** Every pool using an AsyncSwap hook must pair one asset with
  that deployment's configured USDC. This rule applies to anyone initializing a
  pool with the hook; unrelated v4 pools are unaffected.
- **0.3% protocol fee.** The fee is taken from gross output on successful fills.
  The maker's signed minimum is net of the fee; creation and cancellation have
  no protocol fee.
- **Signed actions.** EIP-712 signatures support create, authorize, reprice, and
  cancel actions. ERC-1271 wallets are supported. ERC-20 input uses Permit2;
  native ETH input requires a transaction.

## Contracts

- [`src/AsyncSwap.sol`](https://github.com/asyncswap/protocol/blob/dev/src/AsyncSwap.sol) — v4 hook, order state, numeraire
  check, and fee accounting.
- [`src/Router.sol`](https://github.com/asyncswap/protocol/blob/dev/src/Router.sol) — maker and filler entry points.
- [`src/libraries/AsyncFiller.sol`](https://github.com/asyncswap/protocol/blob/dev/src/libraries/AsyncFiller.sol) — order
  storage and full-fill, reprice, and cancel logic.

## Build and test

```
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
current hook. The 0.3% fee in this source applies only to hooks deployed from
this version; already deployed hooks retain their existing fee.

- [Deployment runbook](https://github.com/asyncswap/protocol/blob/dev/docs/DEPLOYMENT.md) — inputs, preflight, broadcast, and pool initialization.
- [Chain configuration](https://github.com/asyncswap/protocol/blob/dev/script/config/chains.json) — configured networks and readiness.
- [Signed-message metadata](https://github.com/asyncswap/protocol/blob/dev/docs/ERC-7730.md) — wallet display metadata and release checks.
- [USDC numeraire spec](https://github.com/asyncswap/protocol/blob/dev/docs/specs/usdc-numeraire.md) — scope and rationale.

Do not enable the new deployment in the frontend or publish wallet metadata
until the deployed addresses, supported chains, and security review are final.
