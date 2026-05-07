#!/usr/bin/env bun
/**
 * Submit an AsyncSwap limit order against the deployed hook on Unichain.
 *
 *   bun packages/protocol/script/submit-order.ts \
 *     --in ETH --out USDC --amount 0.005 [--price 4500] [--slippage 100] [--dry]
 *
 * Required env:
 *   PRIVATE_KEY          maker's key (broadcasts the tx)
 *
 * Optional env:
 *   CHAIN_ID             default 130
 *   RPC_URL              default https://unichain-rpc.publicnode.com
 *   INDEXER_URL          default https://api.asyncswap.org
 *   ROUTER_ADDRESS       overrides the canonical lookup
 *   HOOK_ADDRESS         overrides the canonical lookup
 *   POOL_FEE             override pool fee (default reads from the indexer)
 *   POOL_TICK_SPACING    override pool tickSpacing (default reads from the indexer)
 *
 * Behavior:
 *   - If --price is omitted, the script fetches USD rates from Coinbase for both
 *     symbols and uses tokenIn-USD / tokenOut-USD as the implied rate.
 *   - amountOutMin = price * amount * (1 - slippageBps/10000). Default slippage
 *     is 1% (100 bps).
 *   - For ERC20 input, sets allowance(Router) = amountIn before submitting.
 *   - For native ETH input (currency0 = 0x0 + zeroForOne, or currency1 = 0x0 + !zeroForOne),
 *     the call carries msg.value = amountIn — no approval needed.
 *   - Looks up the pool via the indexer's GraphQL `pools(where: {chainId, currency0, currency1})`.
 *     If the pool doesn't exist yet, exits with an error pointing at 02_InitializePool.
 *
 *   Use --dry to print the resolved order without broadcasting.
 */

import {
	createPublicClient,
	createWalletClient,
	http,
	parseUnits,
	formatUnits,
	encodeAbiParameters,
	getAddress,
	type Hex,
	type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { unichain } from "viem/chains";

/* ------------------------------- token registry ------------------------------ */

const TOKENS_BY_CHAIN: Record<number, Record<string, { address: Address; decimals: number }>> = {
	130: {
		ETH: { address: "0x0000000000000000000000000000000000000000", decimals: 18 },
		USDC: { address: "0x078D782b760474a361dDA0AF3839290b0EF57AD6", decimals: 6 },
		USDT: { address: "0x9151434b16b9763660705744891fa906f660ecc5", decimals: 6 },
		WETH: { address: "0x4200000000000000000000000000000000000006", decimals: 18 },
	},
};

/* ----------------------------------- args ---------------------------------- */

function arg(name: string): string | undefined {
	const i = process.argv.indexOf(`--${name}`);
	return i >= 0 ? process.argv[i + 1] : undefined;
}
function flag(name: string): boolean {
	return process.argv.includes(`--${name}`);
}

const inSym = (arg("in") ?? "ETH").toUpperCase();
const outSym = (arg("out") ?? "USDC").toUpperCase();
const humanAmount = arg("amount") ?? "0.001";
const priceArg = arg("price");
const slippageBps = Number(arg("slippage") ?? "100");
const dry = flag("dry");

const chainId = Number(process.env.CHAIN_ID ?? "130");
const rpcUrl = process.env.RPC_URL ?? "https://unichain-rpc.publicnode.com";
const indexerUrl = process.env.INDEXER_URL ?? "https://api.asyncswap.org";
const pk = process.env.PRIVATE_KEY as Hex | undefined;
if (!pk) {
	throw new Error("PRIVATE_KEY env var is required (a 0x-prefixed maker private key).");
}

const tokens = TOKENS_BY_CHAIN[chainId];
if (!tokens) throw new Error(`Unknown chainId ${chainId}; extend TOKENS_BY_CHAIN.`);
const tokenIn = tokens[inSym];
const tokenOut = tokens[outSym];
if (!tokenIn) throw new Error(`Unknown tokenIn "${inSym}" — known: ${Object.keys(tokens).join(", ")}`);
if (!tokenOut) throw new Error(`Unknown tokenOut "${outSym}" — known: ${Object.keys(tokens).join(", ")}`);
if (tokenIn.address.toLowerCase() === tokenOut.address.toLowerCase()) {
	throw new Error("tokenIn and tokenOut must differ");
}

/* -------------------------- contract address lookup ------------------------- */

const HOOK_ADDRESS = (process.env.HOOK_ADDRESS ?? "0x91db9941a44c19a5409345C5f2f8A2C1f81ba888") as Address;
const ROUTER_ADDRESS = (process.env.ROUTER_ADDRESS ?? "0x2A144DAb2EBcD4adfA239Ef86bBBa148CbBDfd37") as Address;

/* ----------------------------------- pricing ---------------------------------- */

async function coinbaseUsd(symbol: string): Promise<number> {
	// Some tokens (USDC, USDT) aren't directly priced on the spot endpoint; the
	// exchange-rates endpoint always works.
	const r = await fetch(`https://api.coinbase.com/v2/exchange-rates?currency=${symbol}`);
	if (!r.ok) throw new Error(`Coinbase ${symbol}: ${r.status}`);
	const j = (await r.json()) as { data: { rates: Record<string, string> } };
	const usd = Number(j.data.rates.USD);
	if (!Number.isFinite(usd) || usd <= 0) {
		throw new Error(`Coinbase returned invalid USD rate for ${symbol}: ${j.data.rates.USD}`);
	}
	return usd;
}

async function resolvePrice(): Promise<number> {
	if (priceArg) {
		const p = Number(priceArg);
		if (!Number.isFinite(p) || p <= 0) throw new Error(`--price must be > 0, got ${priceArg}`);
		return p;
	}
	const [inUsd, outUsd] = await Promise.all([coinbaseUsd(inSym), coinbaseUsd(outSym)]);
	return inUsd / outUsd; // tokenOut per tokenIn
}

/* ------------------------------- pool lookup ------------------------------- */

const [c0, c1] =
	tokenIn.address.toLowerCase() < tokenOut.address.toLowerCase()
		? [tokenIn.address, tokenOut.address]
		: [tokenOut.address, tokenIn.address];
const zeroForOne = tokenIn.address.toLowerCase() === c0.toLowerCase();

interface IndexerPool {
	poolId: Hex;
	currency0: Address;
	currency1: Address;
	fee: number;
	tickSpacing: number;
	hooks: Address;
}

async function findPool(): Promise<IndexerPool | null> {
	const query = `query($chainId:Int,$c0:String!,$c1:String!){
		pools(where:{chainId:$chainId,currency0:$c0,currency1:$c1},limit:1){
			items { poolId chainId currency0 currency1 fee tickSpacing hooks }
		}
	}`;
	const r = await fetch(`${indexerUrl}/graphql`, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({
			query,
			variables: { chainId, c0: c0.toLowerCase(), c1: c1.toLowerCase() },
		}),
	});
	if (!r.ok) throw new Error(`Indexer ${r.status} ${r.statusText}`);
	const j = (await r.json()) as { data?: { pools: { items: IndexerPool[] } } };
	const items = j.data?.pools?.items ?? [];
	return items.find((p) => p.hooks.toLowerCase() === HOOK_ADDRESS.toLowerCase()) ?? null;
}

/* -------------------------------- ABIs ------------------------------------ */

const ERC20_ABI = [
	{
		type: "function",
		name: "approve",
		stateMutability: "nonpayable",
		inputs: [{ name: "spender", type: "address" }, { name: "value", type: "uint256" }],
		outputs: [{ type: "bool" }],
	},
	{
		type: "function",
		name: "allowance",
		stateMutability: "view",
		inputs: [{ name: "owner", type: "address" }, { name: "spender", type: "address" }],
		outputs: [{ type: "uint256" }],
	},
] as const;

const POOL_KEY_COMPONENTS = [
	{ name: "currency0", type: "address" },
	{ name: "currency1", type: "address" },
	{ name: "fee", type: "uint24" },
	{ name: "tickSpacing", type: "int24" },
	{ name: "hooks", type: "address" },
] as const;

const ASYNC_ORDER_TUPLE = {
	type: "tuple",
	components: [
		{ name: "key", type: "tuple", components: POOL_KEY_COMPONENTS },
		{ name: "owner", type: "address" },
		{ name: "zeroForOne", type: "bool" },
		{ name: "amountIn", type: "uint256" },
		{ name: "amountOutMin", type: "uint256" },
		{ name: "sqrtPrice", type: "uint160" },
		{ name: "nonce", type: "uint64" },
	],
} as const;

const ROUTER_SWAP_ABI = [
	{
		type: "function",
		name: "swap",
		stateMutability: "payable",
		inputs: [
			{ name: "order", ...ASYNC_ORDER_TUPLE },
			{ name: "userData", type: "bytes" },
		],
		outputs: [],
	},
] as const;

const USER_PARAMS_TUPLE = [
	{ name: "user", type: "address" },
	{ name: "executor", type: "address" },
	{ name: "amountOutMin", type: "uint256" },
	{ name: "nonce", type: "uint64" },
] as const;

/* ---------------------------------- main ---------------------------------- */

async function main() {
	if (!pk) throw new Error("PRIVATE_KEY env var is required");
	const account = privateKeyToAccount(pk);
	const publicClient = createPublicClient({
		chain: chainId === 130 ? unichain : { ...unichain, id: chainId } as never,
		transport: http(rpcUrl),
	});
	const walletClient = createWalletClient({ account, chain: publicClient.chain, transport: http(rpcUrl) });

	const price = await resolvePrice();
	const amountInWei = parseUnits(humanAmount, tokenIn.decimals);
	const amountOutHuman = price * Number(humanAmount) * (1 - slippageBps / 10_000);
	const amountOutMinWei = parseUnits(amountOutHuman.toFixed(tokenOut.decimals), tokenOut.decimals);

	const pool = await findPool();
	if (!pool) {
		const fee = process.env.POOL_FEE ? Number(process.env.POOL_FEE) : null;
		const tickSpacing = process.env.POOL_TICK_SPACING ? Number(process.env.POOL_TICK_SPACING) : null;
		if (fee === null || tickSpacing === null) {
			throw new Error(
				`No AsyncSwap pool indexed for ${inSym}/${outSym} (currency0=${c0}, currency1=${c1}, hook=${HOOK_ADDRESS}). ` +
					`Initialize one first (forge script script/02_InitializePool.s.sol with these tokens) or set POOL_FEE + POOL_TICK_SPACING env to bypass the lookup.`,
			);
		}
		console.warn("[submit-order] no indexed pool; using POOL_FEE/POOL_TICK_SPACING overrides");
	}

	const fee = pool?.fee ?? Number(process.env.POOL_FEE);
	const tickSpacing = pool?.tickSpacing ?? Number(process.env.POOL_TICK_SPACING);
	const hooks = pool?.hooks ?? HOOK_ADDRESS;

	const nonce = BigInt(Math.floor(Date.now() / 1000));
	const sqrtPrice = 2n ** 96n; // mid-tick reference; hook reads amountOutMin from hookData

	const order = {
		key: {
			currency0: getAddress(c0),
			currency1: getAddress(c1),
			fee,
			tickSpacing,
			hooks: getAddress(hooks),
		},
		owner: account.address,
		zeroForOne,
		amountIn: amountInWei,
		amountOutMin: amountOutMinWei,
		sqrtPrice,
		nonce,
	};

	const userData = encodeAbiParameters(
		[{ type: "tuple", components: USER_PARAMS_TUPLE }],
		[
			{
				user: account.address,
				executor: ROUTER_ADDRESS,
				amountOutMin: amountOutMinWei,
				nonce,
			},
		],
	);

	const isNativeIn = tokenIn.address === "0x0000000000000000000000000000000000000000";
	const value = isNativeIn ? amountInWei : 0n;

	console.log(`[submit-order] chainId=${chainId} maker=${account.address}`);
	console.log(
		`[submit-order] ${humanAmount} ${inSym} → at least ${formatUnits(amountOutMinWei, tokenOut.decimals)} ${outSym} (${slippageBps} bps slippage)`,
	);
	console.log(`[submit-order] price=${price.toFixed(6)} ${outSym}/${inSym}`);
	console.log(`[submit-order] pool fee=${fee} tickSpacing=${tickSpacing} hook=${hooks}`);
	if (!isNativeIn) {
		const allowance = (await publicClient.readContract({
			address: tokenIn.address,
			abi: ERC20_ABI,
			functionName: "allowance",
			args: [account.address, ROUTER_ADDRESS],
		})) as bigint;
		console.log(`[submit-order] current allowance=${allowance}`);
	}

	if (dry) {
		console.log("[submit-order] --dry, exiting before broadcast.");
		return;
	}

	if (!isNativeIn) {
		const allowance = (await publicClient.readContract({
			address: tokenIn.address,
			abi: ERC20_ABI,
			functionName: "allowance",
			args: [account.address, ROUTER_ADDRESS],
		})) as bigint;
		if (allowance < amountInWei) {
			console.log("[submit-order] approving Router for", amountInWei.toString());
			const approveHash = await walletClient.writeContract({
				address: tokenIn.address,
				abi: ERC20_ABI,
				functionName: "approve",
				args: [ROUTER_ADDRESS, amountInWei],
			});
			await publicClient.waitForTransactionReceipt({ hash: approveHash });
			console.log("[submit-order] approve tx:", approveHash);
		}
	}

	const swapHash = await walletClient.writeContract({
		address: ROUTER_ADDRESS,
		abi: ROUTER_SWAP_ABI,
		functionName: "swap",
		args: [order, userData],
		value,
	});
	console.log("[submit-order] swap tx submitted:", swapHash);
	const receipt = await publicClient.waitForTransactionReceipt({ hash: swapHash });
	console.log(
		`[submit-order] confirmed in block ${receipt.blockNumber}, status=${receipt.status}, gasUsed=${receipt.gasUsed}`,
	);
}

main().catch((err) => {
	console.error("[submit-order] failed:", err);
	process.exit(1);
});
