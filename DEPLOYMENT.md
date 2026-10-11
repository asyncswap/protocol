# Unichain deployment runbook

This runbook deploys the current hook and Router to Unichain mainnet (chain ID `130`). It does not broadcast anything unless the `broadcast` mode is passed explicitly. Deploying creates new contract addresses; initialize new pools against the new hook after deployment. Existing pools and orders remain attached to the old hook.

## Chain coverage in this checkout

The reference addresses and per-chain readiness flags are in [`script/config/chains.json`](script/config/chains.json). It covers every chain currently configured in the app/protocol checkout; it is not a registry of every network with a Uniswap v4 deployment.

| Chain | ID | Current state |
| --- | ---: | --- |
| Unichain mainnet | `130` | Deployment wrapper and live token map are prepared. |
| Ethereum mainnet | `1` | Canonical PoolManager is configured; deploy wrapper and live token/pool map are not. |
| Unichain Sepolia | `1301` | Canonical PoolManager is configured; deploy wrapper and test-token/pool map are not. |
| Anvil | `31337` | Local development/test path only. |

No other network is deployment-ready in this repository. Before adding one, configure and verify that chain's v4 PoolManager, official USDC address, token map, RPC/chain-ID checks, and deployment metadata. Do not substitute bridged or lookalike USDC contracts.

## Parameters

| Name | Required | Value / purpose |
| --- | --- | --- |
| `RPC_URL` | Yes | Private or provider RPC endpoint for Unichain mainnet. The wrapper verifies chain ID `130`. |
| `DEPLOYER_ACCOUNT` | Broadcast only | Foundry keystore account. It must resolve to the protocol owner `0xb1F0982E02f9F71E60512fd47471d76610CcB556`, which the deploy script uses as `OWNER_DEFAULT`. Keep its password in the local Foundry prompt/keystore. |
| `USDC_ADDRESS` | Yes | Unichain USDC: `0x078D782b760474a361dDA0AF3839290b0EF57AD6`. The wrapper checks this exact address and that code exists. |
| `HOOK_SALT` | No | Optional override. Leave unset to mine a valid CREATE2 salt for the hook flags and `0x91` address prefix. |
| `ETHERSCAN_API_KEY` | Verify only | API key for source verification on Uniscan. Never needed to deploy. |

The script supplies the canonical Unichain PoolManager (`0x1F98400000000000000000000000000000000004`) and canonical Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`). The deployer must also hold enough native ETH on Unichain for gas.

Create a local config and fill in the provider URL and keystore account:

```sh
cp .env.deploy.example .env.deploy
```

`.env.deploy` is git-ignored. Do not put a raw private key in this file; use a Foundry keystore account.

## Deploy hook and Router

Run the preflight simulation first. It validates the chain, USDC address/code, CREATE2 salt and hook permission bits, and simulates the deployment without broadcasting:

```sh
bash script/deploy-unichain.sh dry-run
```

After reviewing the predicted hook address and simulation output, deploy explicitly:

```sh
bash script/deploy-unichain.sh broadcast
```

The script writes the new Hook and Router addresses to `deployments/130.json`, then copies their confirmed transaction hashes and receipt blocks from Foundry's broadcast artifact into the registry. The canonical PoolManager is recorded with start block `0` and no deployment transaction hash because AsyncSwap did not deploy it. Use the new addresses in frontend, indexer, and ERC-7730 metadata configuration.

## Initialize a pool

The deploy step does not initialize pools. `script/InitPool.s.sol` supports `ETH`, `WETH`, `USDC`, and `USDT` symbols on Unichain, but each pool must include the exact configured USDC token. For example, choose one of `ETH/USDC`, `WETH/USDC`, or `USDT/USDC`.

Required pool input:

| Name | Default | Meaning |
| --- | --- | --- |
| `TOKEN_IN` | `ETH` | First symbol; order is normalized by token address. |
| `TOKEN_OUT` | `USDC` | Second symbol; one side must be USDC. |
| `INIT_SQRT_PRICE_X96` | **Required** | Initial square-root price for sorted `currency1` per `currency0`, scaled by `2^96`. |
| `POOL_FEE` | `8388608` | Dynamic-fee flag (`LPFeeLibrary.DYNAMIC_FEE_FLAG`). |
| `POOL_TICK_SPACING` | `60` | Positive `int24` tick spacing. |

The initial price is not a quote or a limit; it initializes the pool's starting price. Compute it from the intended `currency1`/`currency0` price, accounting for each token's decimals:

```text
sqrtPriceX96 = floor(sqrt(priceToken1PerToken0Raw) * 2^96)
priceToken1PerToken0Raw = humanPriceToken1PerToken0 * 10^(decimals1 - decimals0)
```

For ETH/USDC, ETH is sorted as `currency0` and USDC as `currency1`; use the current intended USDC-per-ETH starting price. The script now rejects a missing, zero, or out-of-range `INIT_SQRT_PRICE_X96` rather than silently initializing at 1:1.

After setting `TOKEN_IN`, `TOKEN_OUT`, and `INIT_SQRT_PRICE_X96` in `.env.deploy`, simulate and then initialize explicitly:

```sh
forge script script/InitPool.s.sol --rpc-url "$RPC_URL" --ffi --account "$DEPLOYER_ACCOUNT"
forge script script/InitPool.s.sol --rpc-url "$RPC_URL" --ffi --account "$DEPLOYER_ACCOUNT" --broadcast
```

The pool script persists the `PoolKey` in `deployments/130-pool.json`. This deployment does not add liquidity; AsyncSwap orders are peer-to-peer.

## Post-deployment checks

1. Confirm the recorded hook and Router addresses match the broadcast receipts and the hook's immutable `numeraire()` is the verified USDC address.
2. Verify both contracts on Uniscan using the constructor argument forms in the protocol README.
3. Initialize only the intended USDC pair(s), then update the app's hook/router addresses and the indexer's start block.
4. Publish ERC-7730 metadata only after the final addresses and chain bindings are recorded.
