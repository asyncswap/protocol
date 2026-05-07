#!/usr/bin/env bun
/**
 * Offline CREATE2 salt miner for AsyncSwap hook.
 *
 * Why offline: the hook address must satisfy BOTH the bottom-14-bit Uniswap v4
 * permission flags AND a top-byte prefix (0x91). Mining in a Forge script
 * `for` loop blows up Forge's memory tracker (MemoryOOG) over millions of
 * iterations.
 *
 * Workflow:
 *   1. Run the probe step to obtain the init code hash:
 *        forge script script/01_DeployHook.s.sol --rpc-url <rpc>
 *      The script prints `initCodeHash` and other parameters, then reverts.
 *   2. Either pass --init-code-hash 0x... directly, or paste it into the
 *      `INIT_CODE_HASH` constant below.
 *   3. Run this miner:
 *        bun run script/mine-hook-salt.ts \
 *          --init-code-hash 0xabc... \
 *          [--deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C]
 *   4. Export the printed salt and deploy:
 *        HOOK_SALT=0x... forge script script/01_DeployHook.s.sol --rpc-url <rpc> --broadcast
 */

import { getCreate2Address, type Hex } from "viem";

// ---------- constants matching 01_DeployHook.s.sol ----------

/** Standard CREATE2 deployer proxy used by `forge script`. */
const DEFAULT_DEPLOYER: Hex = "0x4e59b44847b379578588920cA78FbF26c0B4956C";

/** Uniswap v4 ALL_HOOK_MASK = bottom 14 bits. */
const FLAG_MASK = (1n << 14n) - 1n;

/** Hooks.BEFORE_INITIALIZE_FLAG | BEFORE_ADD_LIQUIDITY_FLAG | BEFORE_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG */
const HOOK_FLAGS =
  (1n << 13n) | // BEFORE_INITIALIZE       = 1 << 13
  (1n << 11n) | // BEFORE_ADD_LIQUIDITY    = 1 << 11
  (1n << 7n) | //  BEFORE_SWAP             = 1 << 7
  (1n << 3n); //   BEFORE_SWAP_RETURNS_DELTA = 1 << 3

/** Top-byte prefix (bits 152-159). */
const HOOK_PREFIX = 0x91n << 152n;
const HOOK_PREFIX_MASK = 0xffn << 152n;

// ---------- arg parsing ----------

function getArg(name: string): string | undefined {
  const idx = process.argv.indexOf(`--${name}`);
  if (idx === -1 || idx === process.argv.length - 1) return undefined;
  return process.argv[idx + 1];
}

const initCodeHashArg = getArg("init-code-hash");
const deployerArg = getArg("deployer");
const startArg = getArg("start");
const maxArg = getArg("max");
/**
 * When --ffi is passed, suppress all human-readable output and print ONLY the
 * salt as a single 0x-prefixed bytes32 on stdout. Forge `vm.ffi` reads stdout
 * and abi-decodes the result, so any extra logging would corrupt it.
 * Progress and errors still go to stderr (which Forge surfaces verbatim).
 */
const ffiMode = process.argv.includes("--ffi");

const log = (msg: string) => {
  if (!ffiMode) console.log(msg);
};
const progress = (msg: string) => {
  // stderr in both modes so FFI stdout stays clean but the user still sees life
  process.stderr.write(msg);
};

if (!initCodeHashArg || !/^0x[0-9a-fA-F]{64}$/.test(initCodeHashArg)) {
  console.error(
    "Missing or invalid --init-code-hash. Run the probe step first:\n" +
      "  forge script script/01_DeployHook.s.sol --rpc-url <rpc>\n" +
      "and copy the bytes32 value it prints.",
  );
  process.exit(1);
}

const initCodeHash = initCodeHashArg as Hex;
const deployer = (deployerArg ?? DEFAULT_DEPLOYER) as Hex;
const startSalt = startArg ? BigInt(startArg) : 0n;
const maxIterations = maxArg ? BigInt(maxArg) : 500_000_000n;

// ---------- mining loop ----------

log("Mining CREATE2 salt for AsyncSwap hook...");
log(`  deployer:        ${deployer}`);
log(`  initCodeHash:    ${initCodeHash}`);
log(`  required flags:  0x${HOOK_FLAGS.toString(16).padStart(4, "0")} (mask 0x3FFF)`);
log(`  required prefix: 0x91 in top byte`);
log(`  start salt:      ${startSalt}`);
log(`  max iterations:  ${maxIterations}`);
log("");

const t0 = Date.now();
let lastLog = t0;

for (let salt = startSalt; salt < startSalt + maxIterations; salt++) {
  const saltHex = `0x${salt.toString(16).padStart(64, "0")}` as Hex;
  const addr = getCreate2Address({ from: deployer, salt: saltHex, bytecodeHash: initCodeHash });
  const a = BigInt(addr);

  if ((a & FLAG_MASK) === HOOK_FLAGS && (a & HOOK_PREFIX_MASK) === HOOK_PREFIX) {
    const elapsed = (Date.now() - t0) / 1000;
    const iterations = salt - startSalt + 1n;
    if (ffiMode) {
      // Forge will abi-decode this as bytes32. Must be the ONLY thing on stdout.
      process.stdout.write(saltHex);
      process.stderr.write(`\n[mine-hook-salt] found ${addr} salt=${saltHex} iters=${iterations} (${elapsed.toFixed(1)}s)\n`);
    } else {
      log("=== FOUND ===");
      log(`  address:    ${addr}`);
      log(`  salt:       ${saltHex}`);
      log(`  iterations: ${iterations}`);
      log(`  elapsed:    ${elapsed.toFixed(1)}s`);
      log("");
      log("Deploy with:");
      log(`  HOOK_SALT=${saltHex} forge script script/01_DeployHook.s.sol --rpc-url <rpc> --broadcast`);
    }
    process.exit(0);
  }

  // Progress every ~3s (stderr only — never pollutes FFI stdout).
  const now = Date.now();
  if (now - lastLog > 3000) {
    const iterations = salt - startSalt + 1n;
    const rate = Number(iterations) / ((now - t0) / 1000);
    progress(`  tried ${iterations.toString()} salts (${rate.toFixed(0)}/s, current 0x${salt.toString(16)})\r`);
    lastLog = now;
  }
}

process.stderr.write(`\nNo salt found in ${maxIterations} iterations starting from ${startSalt}.\n`);
process.stderr.write("Re-run with --start to resume from a higher offset, or --max to extend the search.\n");
process.exit(1);
