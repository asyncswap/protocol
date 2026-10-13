# Unichain deployment runbook

This runbook deploys the current hook and Router to Unichain mainnet (chain ID `130`). It does not broadcast anything unless the `broadcast` mode is passed explicitly. Deploying creates new contract addresses; initialize new pools against the new hook after deployment. Existing pools and orders remain attached to the old hook.

## Chain coverage in this checkout

The reference addresses and per-chain readiness flags are in [`script/config/chains.json`](../script/config/chains.json). It covers every chain currently configured in the app/protocol checkout; it is not a registry of every network with a Uniswap v4 deployment.

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
| `HOOK_SALT` | No | Optional override. Leave unset to mine a valid CREATE2 salt for the hook flags and `0x91` address prefix. |
| `ETHERSCAN_API_KEY` | Verify only | API key for source verification on Uniscan. Never needed to deploy. |

The wrapper reads Unichain's chain ID and USDC address from [`script/config/chains.json`](../script/config/chains.json), then checks that the RPC is on that chain and that the configured token has code. Do not set or copy `USDC_ADDRESS` into `.env.deploy`; chain-specific contract addresses belong in the deployment config. Networks without a verified USDC address remain ineligible for deployment.

The script supplies the canonical Unichain PoolManager (`0x1F98400000000000000000000000000000000004`) and canonical Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`). The deployer must also hold enough native ETH on Unichain for gas.

### Step 1: Pick the deployer keystore

`DEPLOYER_ACCOUNT` must be a Foundry keystore whose address is the owner `0xb1F0982E02f9F71E60512fd47471d76610CcB556`. List your keystores and check each candidate's address (this asks for that keystore's password):

```sh
cast wallet list
cast wallet address --account <name>
```

If none of them matches, import the owner key into a new keystore. This prompts for the private key and a password, and never writes the key to a file in the repo:

```sh
cast wallet import asyncswap-production --interactive
```

Check that the owner holds enough ETH on Unichain for gas (a deploy costs about 0.00002 ETH at 0.001 gwei):

```sh
cast balance 0xb1F0982E02f9F71E60512fd47471d76610CcB556 --ether --rpc-url https://mainnet.unichain.org
```

### Step 2: Create `.env.deploy`

```sh
cp .env.deploy.example .env.deploy
```

Then set at least:

```sh
RPC_URL=https://mainnet.unichain.org   # or a private provider URL
DEPLOYER_ACCOUNT=<keystore name from step 1>
```

`.env.deploy` is git-ignored. Do not put a raw private key in this file; use a Foundry keystore account.

## Deploy hook and Router

### Step 3: Dry run

Run the preflight simulation first. It validates the configured chain and USDC code, CREATE2 salt and hook permission bits, and simulates the deployment without broadcasting:

```sh
bash script/deploy-unichain.sh dry-run
```

Expect `Script ran successfully`, a `predicted hook address` starting with `0x91`, and `SIMULATION COMPLETE`. A `contract size limit` error means the optimizer settings in `foundry.toml` were changed; the hook only fits under EIP-170 with the optimizer on. The simulation updates `deployments/130/130.json` and adds a timestamped `130-*.json` file; discard both before broadcasting:

```sh
git checkout -- deployments && git clean -f deployments
```

### Step 4: Broadcast

After reviewing the predicted hook address and simulation output, deploy explicitly. Foundry prompts for the keystore password:

```sh
bash script/deploy-unichain.sh broadcast
```

The script writes the new Hook and Router addresses to `deployments/130/130.json`, then copies their confirmed transaction hashes and receipt blocks from Foundry's broadcast artifact into the registry. The canonical PoolManager is recorded with start block `0` and no deployment transaction hash because AsyncSwap did not deploy it. Use the new addresses in frontend, indexer, and ERC-7730 metadata configuration.

### Step 5: Confirm ownership and numeraire on-chain

The deploy script already asserts the owner during the run. Confirm against the chain anyway, using the hook address from `deployments/130/130.json`:

```sh
cast call <HOOK> "owner()(address)" --rpc-url "$RPC_URL"      # 0xb1F0982E02f9F71E60512fd47471d76610CcB556
cast call <HOOK> "numeraire()(address)" --rpc-url "$RPC_URL"  # 0x078D782b760474a361dDA0AF3839290b0EF57AD6
cast call <HOOK> "feeVault()(address)" --rpc-url "$RPC_URL"
cast call <ROUTER> "PERMIT2()(address)" --rpc-url "$RPC_URL"  # 0x000000000022D473030F116dDEE9F6B43aC78BA3
```

Then commit the updated registry (`deployments/130/`).

### Breaking changes in this release

This deployment includes the [security review fixes](../audits/README.md). Old and new contracts are not interchangeable:

- Signed cancels use a new `CancelOrder` EIP-712 type with a `nonce` field, and `Router.cancelWithSig` takes `(order, nonce, deadline, signature)`. The app must ship the matching signing code (interface commit `8c0dc035`) at the same time as it switches to the new addresses.
- Ownership transfers take two steps: `transferOwnership(newOwner)`, then `acceptOwnership()` from the new owner.
- Custom executors (anything other than the Router) must call `PoolManager.swap` themselves, and for ERC20 output must pay into the PoolManager and call `settleFor(hook)` before `executeOrder`.

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

The pool script persists the `PoolKey` in `deployments/130/130-pool.json`. This deployment does not add liquidity; AsyncSwap orders are peer-to-peer.

## Post-deployment checks

1. Confirm the recorded hook and Router addresses match the broadcast receipts and the hook's immutable `numeraire()` is the verified USDC address.
2. Verify both contracts on Uniscan with the `foundry.toml` compiler settings (solc 0.8.26, optimizer on, 1,000,000 runs). Constructor arguments: `AsyncSwap(poolManager, usdc, owner)` and `Router(poolManager, hook, permit2)`.
3. Initialize only the intended USDC pair(s), then update the app's hook/router addresses and the indexer's start block.
4. Publish ERC-7730 metadata only after the final addresses and chain bindings are recorded.
