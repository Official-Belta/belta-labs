# BELTA Labs — IL Hedge Protocol for Uniswap V4

> Automated Impermanent Loss hedging via Uniswap V4 Hooks — no governance changes required.

**Wall Street strategies for everyone.**

[![Solidity](https://img.shields.io/badge/Solidity-%5E0.8.26-blue)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)](https://getfoundry.sh/)
[![License: BUSL-1.1](https://img.shields.io/badge/License-BUSL--1.1-blue.svg)](LICENSE)
[![Testnet](https://img.shields.io/badge/Sepolia-Live-brightgreen)](https://sepolia.etherscan.io/address/0x1609e47BE1504F29Ed6DBb5dcdF57dEea9405540)
[![Tests](https://img.shields.io/badge/Tests-17%2F17%20PASS-brightgreen)]()
[![Discord](https://img.shields.io/badge/Discord-Join%20Community-5865F2?logo=discord&logoColor=white)](https://discord.gg/DneWWwxQ)

---

## What is BELTA?

BELTA is a DeFi protocol that **automatically hedges Impermanent Loss** for Uniswap V4 liquidity providers. LPs pay a small premium (12% of fee income), and in return receive automatic IL compensation (up to 35% coverage) settled every 7-day epoch.

### The Problem

Concentrated liquidity on Uniswap V3/V4 amplifies both fee income **and** impermanent loss. LPs using tight ranges can earn 3-5x more fees, but face devastating IL during volatility. Most LPs avoid tight ranges entirely — leaving yield on the table.

### The Solution

BELTA acts as an IL insurance layer built natively into V4 Hooks:

- **LPs** opt-in when adding liquidity, pay 12% of fee income as premium
- **Underwriter Pool** absorbs IL claims using collected premiums
- **Treasury Buffer** provides first-loss protection during black swan events
- **Epoch Settlement** (7 days) ensures predictable, gas-efficient payouts

## Architecture

```
LP Position (Uniswap V4)
    |
    +-- Premium (12% of fee income) --> BELTAHook.sol
    |                                       |
    |                             +---------+---------+
    |                        IL Settlement     Underwriter Pool
    |                        (Epoch 7d)        (ERC-4626)
    |                        Coverage 35%      Treasury Buffer
    |                             |
    +-- IL Payout <---------------+
```

## Smart Contracts (Sepolia Testnet)

| Contract | Description | Address |
|---|---|---|
| `BELTAHook.sol` | V4 Hook — IL tracking + premium collection | [`0x1609...5540`](https://sepolia.etherscan.io/address/0x1609e47BE1504F29Ed6DBb5dcdF57dEea9405540) |
| `UnderwriterPool.sol` | ERC-4626 vault — deposit/withdraw/shares | [`0x4296...a5DD`](https://sepolia.etherscan.io/address/0x4296A225D8077b614DAf25862Bc9F780aFDea5DD) |
| `TreasuryModule.sol` | Treasury buffer + self-healing mechanism | [`0xa0B3...51f3`](https://sepolia.etherscan.io/address/0xa0B315D9bAb3fCAF21F750BD3C8b9D0fc5Bd51f3) |
| `PremiumOracle.sol` | Dynamic premium rate (Aave-style curve) | [`0x2d11...Bf58`](https://sepolia.etherscan.io/address/0x2d11850A62AaC9dc10Bc67Bb2056685e4cF1Bf58) |
| `EpochSettlement.sol` | 7-day epoch settlement coordinator | [`0x693D...E9a1`](https://sepolia.etherscan.io/address/0x693DB559c3bCc243470D31025E7BF5B7f08EE9a1) |

**Pool Manager**: [`0xE03A...3543`](https://sepolia.etherscan.io/address/0xE03A1074c86CFeDd5C142C4F04F1a1536e203543) (Uniswap V4 Sepolia)

## Protocol Parameters

| Parameter | Value | Notes |
|---|---|---|
| Coverage Cap | **35%** | Max IL compensation per position |
| Premium Rate | **12%** | Of LP fee income (6% in Phase 4) |
| Epoch Duration | **7 days** | Settlement cycle |
| Daily Pay Limit | **5%** | Max pool payout per day |
| Cooldown Period | **7 days** | Withdrawal delay |
| Treasury Target | **20%** | Of Senior pool balance |
| Dynamic Rate Kink | **80%** | Utilization threshold for rate spike |

## Test Results

All contracts are deployed on Sepolia and verified via fork tests:

### Unit Tests (`BELTAFlow.t.sol`) — 8/8 PASS
- Deposit/withdraw flow, share calculation, cooldown enforcement, premium collection

### Full LP Lifecycle (`FakeLPFlow.t.sol`) — PASS
Simulates 3 LPs with different risk profiles on a Sepolia fork:

| LP | Range | Liquidity | IL Claim |
|---|---|---|---|
| LP1 (Whale) | Wide ±6% | 500M | 2.30 USDC |
| LP2 (Medium) | Medium ±3% | 200M | 1.84 USDC |
| LP3 (Tight) | Tight ±1.2% | 50M | 1.14 USDC |

- **Price movement**: -4.6% (tick 202200 → 201733) — realistic market conditions
- **Premiums collected**: 64.8 USDC
- **Total IL claims**: 5.28 USDC (8% of premiums — healthy ratio)
- **Full flow verified**: Opt-in → Swap → Epoch advance → Settlement → IL Claim → Zero pending

### E2E Flow (`E2EFlow.t.sol`) — PASS
- Pool initialization, epoch state, capacity, TVL, treasury buffer, oracle rates, settlement

## Quick Start

### Prerequisites

- [Foundry](https://getfoundry.sh)
- Node.js 18+

### Build & Test

```bash
forge install
forge build
forge test -vvv
```

### Fork Test (Sepolia)

```bash
forge test --match-test test_FullLPLifecycle --fork-url https://ethereum-sepolia-rpc.publicnode.com -vv
```

### Deploy to Sepolia

```bash
source .env  # DEPLOYER_PRIVATE_KEY, SEPOLIA_RPC_URL
forge script script/DeployTestnet.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
```

### Keeper (Epoch Settlement)

```bash
cd keeper
npm install
PRIVATE_KEY=0x... node keeper.js
```

### Dashboard

```bash
cd frontend
python -m http.server 8080
# Open http://localhost:8080
```

Or visit the live dashboard: [official-belta.github.io/belta-labs](https://official-belta.github.io/belta-labs/)

## IL Calculation

BELTA uses the V3 concentrated liquidity IL formula with correction factor:

```
IL_V2 = 2*sqrt(r) / (1+r) - 1          where r = priceEnd / priceStart
IL_V3 = IL_V2 * 1 / (1 - sqrt(Pa/Pb))  where Pa = range lower, Pb = range upper

Payout = min(IL_V3, COVERAGE_CAP) * positionValue
```

Tighter ranges amplify IL — BELTA compensates up to 35% of the calculated IL.

## Dynamic Premium Rate

Uses an Aave-style utilization curve to self-regulate demand:

```
Utilization U = Total Hedged TVL / Pool TVL

U < 80%:  Rate = base_rate (12%)
U >= 80%: Rate = base_rate + slope * (U - 80%) / 20%
          -> Up to 2-3x base rate at 100% utilization
```

High utilization = higher premiums = natural demand throttling.

## Roadmap

| Phase | Timeline | Pool Size | Milestone |
|---|---|---|---|
| ~~0~~ | ~~Done~~ | — | ~~Smart contract development~~ |
| **1 Testnet** | **Now** | — | Sepolia deployed, fork tests passing, Audit next |
| **2 Mainnet Pilot** | 4-9 months | $100K | 24 epochs, Grant application |
| **3 Open Market** | 11+ months | $10M | VC round, Treasury/Senior dual pool |
| **4 DEX Integration** | 36+ months | $20M | Premium 6%, DEX LP TVL 2% |
| **5 Global** | 60+ months | ~$170M | Multi-chain expansion |

## Project Structure

```
belta-labs/
├── src/                    # Smart contracts (Solidity)
│   ├── BELTAHook.sol       # V4 Hook — core IL + premium logic
│   ├── UnderwriterPool.sol # ERC-4626 vault
│   ├── EpochSettlement.sol # 7-day epoch settlement
│   ├── PremiumOracle.sol   # Dynamic rate oracle
│   └── TreasuryModule.sol  # Treasury buffer management
├── test/                   # Foundry tests
│   ├── BELTAFlow.t.sol     # Unit tests (8 tests)
│   ├── FakeLPFlow.t.sol    # Full LP lifecycle fork test
│   └── E2EFlow.t.sol       # E2E Sepolia fork test
├── script/                 # Deployment scripts
├── keeper/                 # Epoch settlement bot (Node.js)
├── frontend/               # Dashboard (HTML/JS)
├── backtest/               # Python backtesting engine
└── broadcast/              # Deployment transaction records
```

## Backtest Results

```bash
python backtest/phase_backtest_v4_4_0.py  # Multi-LP cohort model (latest)
```

Backtested against 2020-2025 ETH/USDC data (including COVID, LUNA, FTX events):

| Phase | Treasury CAGR | Senior APY | Sharpe | Pool MDD |
|---|---|---|---|---|
| 1-2 Single Pool | +5.1% | 5-6% | 0.71 | -8% |
| 3-4 Dual Pool | +2.7% | 7.3% | 0.99 | -10.0% |

Treasury absorbs tail risk (MDD up to -61.6% during LUNA), but the overall pool MDD stays below -10% thanks to Senior tranche buffering.

## Community

- **Discord**: [discord.gg/DneWWwxQ](https://discord.gg/DneWWwxQ)
- **GitHub**: [github.com/Official-Belta/belta-labs](https://github.com/Official-Belta/belta-labs)
- **Dashboard**: [official-belta.github.io/belta-labs](https://official-belta.github.io/belta-labs/)

## License

MIT

---

*BELTA Labs — Singapore*
