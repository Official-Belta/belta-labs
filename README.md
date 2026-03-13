# BELTA Labs — IL Hedge Protocol

> Uniswap V4 Hook 기반 LP 비영구적 손실(Impermanent Loss) 자동 헤지 프로토콜

**월가의 전략을 모두에게**

---

## Overview

BELTA IL Hedge Protocol은 Uniswap V4 Hook만으로 구현되는 LP 비영구적 손실 헤지 인프라입니다. LP는 수수료 수익의 일부를 프리미엄으로 납부하고, IL 발생 시 자동으로 보상받습니다.

- Uniswap V4 Hook 네이티브 — 거버넌스 변경 불필요
- IL의 45% 자동 커버리지
- 7일 Epoch 기반 정산
- ERC-4626 Underwriter Pool

## Architecture

```
LP Position (Uniswap V4)
    │
    ├── Premium (12% of fee income) → BELTAHook.sol
    │                                      │
    │                              ┌───────┴────────┐
    │                         IL Settlement     Underwriter Pool
    │                         (Epoch 7d)        (ERC-4626)
    │                         Coverage 45%      Treasury Buffer
    │                              │
    └── IL Payout ←───────────────┘
```

## Smart Contracts

| Contract | Description | Sepolia |
|---|---|---|
| `BELTAHook.sol` | V4 Hook — IL tracking, premium collection | [`0x07f4...9540`](https://sepolia.etherscan.io/address/0x07f4f427378ef485931999ace2917a210f0b9540) |
| `UnderwriterPool.sol` | ERC-4626 vault — deposit/withdraw/shares | [`0x67b0...1622`](https://sepolia.etherscan.io/address/0x67b0e434be06fc63224ee0d0b2e4b08ebd9b1622) |
| `TreasuryModule.sol` | Treasury buffer + self-healing mechanism | [`0xc84b...850e`](https://sepolia.etherscan.io/address/0xc84b9df70cbdf35945b2230f0f9e1d09ee35850e) |
| `PremiumOracle.sol` | Dynamic premium rate (Aave-style curve) | [`0x3fdf...801f`](https://sepolia.etherscan.io/address/0x3fdf2ac8b75aa5043763c9615e20eca88d2a801f) |
| `EpochSettlement.sol` | 7-day epoch settlement coordinator | [`0x064f...ec30`](https://sepolia.etherscan.io/address/0x064f6ada17f51575b11c538ed5c5b6a6d7f0ec30) |
| `MockUSDC` | Test USDC (6 decimals) | [`0xa64b...6d12`](https://sepolia.etherscan.io/address/0xa64b084d47657a799885aac2dc861a7c432b6d12) |

## Parameters

| Parameter | Value |
|---|---|
| Coverage Cap | 45% of IL |
| Premium Rate | 12% of fee income |
| Epoch Duration | 7 days |
| Daily Pay Limit | 5% of pool |
| Cooldown Period | 7 days |
| Treasury Target | 20% of Senior |

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

### Deploy to Sepolia

```bash
source .env  # DEPLOYER_PRIVATE_KEY, SEPOLIA_RPC_URL
forge script script/DeployTestnet.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
```

### Frontend (Local)

```bash
cd frontend
python -m http.server 8080
# Open http://localhost:8080
```

### Keeper (Epoch Settlement)

```bash
cd keeper
npm install
PRIVATE_KEY=0x... node keeper.js
```

## Dashboard

The web dashboard connects to Sepolia via MetaMask and shows:
- Pool TVL, Treasury Buffer, Utilization
- Premium Oracle parameters & rate curve
- Deposit/Withdraw interface
- IL claim interface

## Backtest

```bash
python backtest/engine_v3.py  # Phase 1-5 simulation
```

## Roadmap

| Phase | Timeline | Pool Size | Milestone |
|---|---|---|---|
| 0 | Now | — | Smart contract development |
| 1 Testnet | 1-3 months | — | Sepolia deployment, Audit |
| 2 Mainnet Pilot | 4-9 months | $100K | 24 epochs, Grant application |
| 3 Open Market | 11+ months | $10M | VC round, dual pool |
| 4 DEX Payment | 36+ months | $20M | DEX LP TVL 2% payment |

## License

MIT

---

*BELTA Labs Pte. Ltd. — Singapore*
