# USDC as the common numeraire

Date: 2026-10-10. Implemented in source; not deployed.

AsyncSwap markets pair every supported asset with USDC on each supported chain.
This provides a common quote currency without asking the settlement contract to
determine fair market value.

## Contract rule

Each hook receives one chain-specific numeraire address in its constructor. It is
immutable, publicly readable, and must contain deployed code. The deployment
operator is responsible for choosing the approved USDC contract on that chain.
There is no owner setter that could change the quote currency of existing pools.

During `beforeInitialize`, at least one currency must equal that address. The
PoolManager separately enforces distinct, sorted currencies, so exactly one side
of a valid pool is USDC. The check applies to direct PoolManager initialization
as well as initialization through scripts or routers. Existing callback access
control permits only the PoolManager to initialize the hook's pool state.

The same rule permits both buy and sell orders and native ETH/USDC pools.
Symbols, decimals, and lookalike tokens do not satisfy address equality.

## Pricing and accounting

USDC provides a shared valuation unit. It does not imply one USDC per asset token
or guarantee equal economic value before and after a trade. Six-decimal USDC and
assets with other decimal scales retain their independent base-unit amounts.
Quotes, oracle selection, stale-price checks, and RWA issuer restrictions remain
separate concerns. The hook enforces maker-selected net output amounts.

The 0.2% fee remains denominated in the filled output, not necessarily USDC.
Changing fee denomination would require a separate design. Automatic cross-pool
asset-to-asset routing and cross-chain settlement are also outside this change.

## Deployment and compatibility

Set `USDC_ADDRESS` explicitly for the chain. Constructor arguments, creation
bytecode, mined salt, and hook address change. Deploy a new router referencing the
new hook and initialize new USDC pools. Existing contracts and open orders stay
on their original deployments. Frontend/indexer configuration must move only when
the new deployment is ready; none is changed by this source update.

## Validation

`test/Numeraire.t.sol` checks constructor rejection, exact token identity, both
sorted currency positions, native pairs, fuzzed non-numeraire pairs, and complete
buy/sell settlement using six-decimal USDC and an eighteen-decimal asset. Existing
signature, cancellation, fee, and audit regression tests continue to run with an
explicitly configured quote token.
