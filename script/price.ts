#!/usr/bin/env bun
/**
 * FFI helper for forge scripts. Given a token-in symbol, token-out symbol, an
 * input amount (human-readable), and a slippage in bps, prints the abi-encoded
 * tuple `(uint256 amountIn, uint256 amountOutMin)` in wei to stdout.
 *
 *   bun packages/protocol/script/price.ts <inSym> <outSym> <amount> <slippageBps>
 *   bun packages/protocol/script/price.ts ETH USDC 0.005 100
 *
 * Stdout is consumed by `vm.ffi` in 03_Swap.s.sol, so it MUST be a single hex
 * blob with no extra whitespace or framing.
 *
 * Env overrides (rarely needed):
 *   PRICE                 hard-codes the tokenOut/tokenIn rate, skipping Coinbase
 *   COINBASE_BASE_URL     defaults to https://api.coinbase.com
 */

import { encodeAbiParameters, parseUnits } from "viem";

interface Token {
	symbol: string;
	decimals: number;
}

// chainId is implicit via the TS caller; this map only needs decimals + symbol
// because pricing is symbol-driven (Coinbase). Address resolution lives in the
// Forge script.
const TOKENS: Record<string, Token> = {
	ETH: { symbol: "ETH", decimals: 18 },
	WETH: { symbol: "ETH", decimals: 18 }, // priced as ETH
	USDC: { symbol: "USDC", decimals: 6 },
	USDT: { symbol: "USDT", decimals: 6 },
};

function fail(msg: string): never {
	console.error(`[price] ${msg}`);
	process.exit(1);
}

const [, , inArg, outArg, amountArg, slippageArg] = process.argv;
if (!inArg || !outArg || !amountArg) {
	fail("usage: bun price.ts <inSym> <outSym> <amount> [slippageBps]");
}

const inSym = inArg!.toUpperCase();
const outSym = outArg!.toUpperCase();
const slippageBps = Number(slippageArg ?? "100");
if (!Number.isFinite(slippageBps) || slippageBps < 0 || slippageBps > 10_000) {
	fail(`slippageBps must be in [0, 10000], got ${slippageArg}`);
}

const tokenIn = TOKENS[inSym];
const tokenOut = TOKENS[outSym];
if (!tokenIn) fail(`unknown tokenIn "${inSym}"; known: ${Object.keys(TOKENS).join(", ")}`);
if (!tokenOut) fail(`unknown tokenOut "${outSym}"; known: ${Object.keys(TOKENS).join(", ")}`);

const amountInWei = parseUnits(amountArg!, tokenIn.decimals);

async function coinbaseUsd(symbol: string): Promise<number> {
	const base = process.env.COINBASE_BASE_URL ?? "https://api.coinbase.com";
	const r = await fetch(`${base}/v2/exchange-rates?currency=${symbol}`);
	if (!r.ok) fail(`Coinbase ${symbol}: ${r.status}`);
	const j = (await r.json()) as { data: { rates: Record<string, string> } };
	const usd = Number(j.data.rates.USD);
	if (!Number.isFinite(usd) || usd <= 0) fail(`Coinbase invalid USD rate for ${symbol}`);
	return usd;
}

async function resolveRate(): Promise<number> {
	if (process.env.PRICE) {
		const p = Number(process.env.PRICE);
		if (!Number.isFinite(p) || p <= 0) fail(`PRICE env "${process.env.PRICE}" must be > 0`);
		return p;
	}
	const [inUsd, outUsd] = await Promise.all([coinbaseUsd(tokenIn.symbol), coinbaseUsd(tokenOut.symbol)]);
	return inUsd / outUsd; // tokenOut per tokenIn
}

const rate = await resolveRate();

// outputHuman = inputHuman * rate; then knock off slippage to get amountOutMin.
const inputHuman = Number(amountArg);
const outputHuman = inputHuman * rate * (1 - slippageBps / 10_000);
// Use toFixed at tokenOut.decimals so parseUnits doesn't choke on extra precision.
const amountOutMinWei = parseUnits(outputHuman.toFixed(tokenOut.decimals), tokenOut.decimals);

const encoded = encodeAbiParameters(
	[
		{ type: "uint256", name: "amountIn" },
		{ type: "uint256", name: "amountOutMin" },
	],
	[amountInWei, amountOutMinWei],
);

// Single-line hex output — no trailing newline, no logs. vm.ffi parses this.
process.stdout.write(encoded);
