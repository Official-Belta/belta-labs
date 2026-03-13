// BELTA Labs — Epoch Settlement Keeper
// Automatically calls settle() on EpochSettlement every 7 days
//
// Usage:
//   PRIVATE_KEY=0x... node keeper/keeper.js
//
// Or with .env file:
//   npm install dotenv && node keeper/keeper.js

const { ethers } = require("ethers");

// ─── Config ───────────────────────────────────────────────
const RPC_URL = process.env.RPC_URL || "https://rpc.sepolia.org";
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const CHECK_INTERVAL_MS = 60 * 60 * 1000; // Check every 1 hour

// Contract addresses (Sepolia)
const ADDRESSES = {
  EPOCH_SETTLEMENT: "0x064f6ada17f51575b11c538ed5c5b6a6d7f0ec30",
  BELTA_HOOK: "0x07f4f427378ef485931999ace2917a210f0b9540",
};

// Minimal ABIs
const SETTLEMENT_ABI = [
  "function settle((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey) external",
  "function needsSettlement((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey) external view returns (bool)",
  "function lastSettledEpoch(bytes32 poolId) external view returns (uint256)",
  "function keeper() external view returns (address)",
];

const HOOK_ABI = [
  "function getCurrentEpoch(bytes32 poolId) external view returns (uint256)",
];

// ─── Main ─────────────────────────────────────────────────

async function main() {
  if (!PRIVATE_KEY) {
    console.error("ERROR: Set PRIVATE_KEY environment variable");
    console.error("  PRIVATE_KEY=0x... node keeper/keeper.js");
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  const network = await provider.getNetwork();

  console.log("╔══════════════════════════════════════════╗");
  console.log("║  BELTA Labs — Epoch Settlement Keeper    ║");
  console.log("╚══════════════════════════════════════════╝");
  console.log(`  Network:  ${network.name} (${network.chainId})`);
  console.log(`  Keeper:   ${wallet.address}`);
  console.log(`  RPC:      ${RPC_URL}`);
  console.log(`  Interval: ${CHECK_INTERVAL_MS / 1000}s`);
  console.log("");

  const settlement = new ethers.Contract(
    ADDRESSES.EPOCH_SETTLEMENT,
    SETTLEMENT_ABI,
    wallet
  );

  // Verify keeper role
  const registeredKeeper = await settlement.keeper();
  if (registeredKeeper.toLowerCase() !== wallet.address.toLowerCase()) {
    console.warn(`WARNING: Registered keeper is ${registeredKeeper}`);
    console.warn(`         Your address is ${wallet.address}`);
    console.warn(`         settle() calls will revert unless you are owner or keeper.`);
    console.warn("");
  }

  console.log("Keeper started. Checking for settlements...\n");

  // Run immediately, then on interval
  await checkAndSettle(settlement, wallet);
  setInterval(() => checkAndSettle(settlement, wallet), CHECK_INTERVAL_MS);
}

async function checkAndSettle(settlement, wallet) {
  const now = new Date().toISOString().slice(0, 19);
  console.log(`[${now}] Checking...`);

  try {
    // For now, we use a placeholder pool key
    // In production, this would iterate over registered pools
    // The pool key must match the one used during deployment
    const poolKey = {
      currency0: ethers.ZeroAddress,
      currency1: ethers.ZeroAddress,
      fee: 3000,
      tickSpacing: 60,
      hooks: ADDRESSES.BELTA_HOOK,
    };

    const needs = await settlement.needsSettlement(poolKey);

    if (needs) {
      console.log(`  → Settlement needed! Sending tx...`);

      const tx = await settlement.settle(poolKey, {
        gasLimit: 500000,
      });
      console.log(`  → TX submitted: ${tx.hash}`);

      const receipt = await tx.wait();
      console.log(`  → Settled! Block: ${receipt.blockNumber}, Gas: ${receipt.gasUsed}`);
    } else {
      console.log(`  → No settlement needed yet.`);
    }
  } catch (err) {
    if (err.reason) {
      console.log(`  → Skip: ${err.reason}`);
    } else {
      console.error(`  → Error: ${err.message}`);
    }
  }
}

// ─── Start ────────────────────────────────────────────────
main().catch(console.error);
