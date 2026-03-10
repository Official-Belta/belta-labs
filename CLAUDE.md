# BELTA LABS — Claude Code 컨텍스트

> 이 파일은 Claude Code가 프로젝트를 즉시 이해하고 작업할 수 있도록 작성된 컨텍스트입니다.
> Claude.ai에서 설계·기획·백테스트를 진행하고, Claude Code에서 구현을 담당합니다.

---

## 프로젝트 한 줄 요약

**"Uniswap V3/V4 LP의 비영구적 손실(IL)을 자동 헤징하는 DeFi 프로토콜"**
슬로건: 월가의 전략을 모두에게

---

## 핵심 메커니즘

```
LP 포지션 (Uniswap V3/V4)
    │
    ├─ 프리미엄 납부 → BELTA 프로토콜 (BELTAHook.sol)
    │                        │
    │                ┌───────┴────────┐
    │           IL 정산 (Epoch 7일)   Underwriter Pool
    │           Coverage 45%          Senior APY 7%
    │                │                Treasury 버퍼
    └─ IL 보상 ←────┘
```

- LP는 프리미엄을 내고 IL 헤지를 받음
- Underwriter Pool 참여자는 프리미엄 수익에서 APY를 수취
- Treasury가 first-loss를 흡수 (블랙스완 방어)

---

## 확정 파라미터

| 파라미터 | 값 | 비고 |
|---|---|---|
| Coverage Cap | **45%** | IL의 최대 45% 보상 |
| 프리미엄율 | **12%** | fee 수익 × 12% (Phase 4: 6%) |
| Senior APY | **7%** | Phase 3+ 확정 |
| Treasury 버퍼 | **Senior의 20%** | `max(initial_treasury, senior_bal × 0.20)` |
| Epoch | **7일** | IL 정산 주기 |
| CAP_MULT | **6x** (Phase3~4) / **5x** (Phase1~2) | 최대 커버 배수 |
| LP_FEE_APY | Low 18% / **Mid 22.4%** / High 28% | ETH/USDC 0.05% 풀 실측 |
| Daily Pay Limit | **5%** | Pool 일일 지급 상한 |

---

## Phase 로드맵

| Phase | 기간 | Pool 규모 | 핵심 이벤트 |
|---|---|---|---|
| 0 | 현재 | — | 스마트컨트랙트 개발 중 |
| 1 테스트넷 | 1~3개월 | — | Sepolia/Unichain 배포, 1차 Audit |
| 2 메인넷 파일럿 | 4~9개월 | **$100K** | 에포크 24회, 그랜트 신청 |
| 3 오픈마켓 | 11개월~ | $10M | VC 라운드, Treasury/Senior 이중 풀 |
| 4 DEX납부 | 36개월~ | $20M | 프리미엄 6%, DEX LP TVL 2% 납부 |
| 5 글로벌 | 60개월~ | ~$170M | — |

---

## Pool 구조

- **Phase 1~2**: 단일 Underwriter Pool (Treasury/Senior 구분 없음)
  - Aave 5% 기본 수익 + 프리미엄 수입
- **Phase 3~4**: Treasury / Senior 이중 풀
  - 강제 분할 비율 20:80
  - Treasury: first-loss 흡수, xBELTA 예치 대상
  - Senior: 일반 투자자, APY 7% 수취

---

## 스마트컨트랙트 구조

```
contracts/
├── BELTAHook.sol          # Uniswap V4 Hook 핵심 — IL 측정 + 프리미엄 징수
├── UnderwriterPool.sol    # ERC-4626 vault — Senior/Treasury 풀 관리
├── EpochSettlement.sol    # 7일 에포크 IL 정산 로직
├── PremiumOracle.sol      # 동적 마진율 계산 (Aave 이용률 곡선)
└── TreasuryModule.sol     # Treasury 버퍼 관리 + 자기치유 메커니즘
```

**개발 환경**: Foundry + Solidity ^0.8.24
**타깃 체인**: Arbitrum (메인), Unichain (테스트넷)
**핵심 의존성**: Uniswap V4 core, OpenZeppelin, Aave V3 interface

---

## IL 계산 공식

```solidity
// V3 집중 유동성 IL 보정
// IL_V3 = IL_V2 × 1 / (1 - √(Pa/Pb))
// Pa = range lower, Pb = range upper

function calcIL(
    uint256 priceStart,
    uint256 priceEnd,
    uint256 priceLower,  // Pa
    uint256 priceUpper   // Pb
) public pure returns (uint256 ilBps) {
    // price ratio
    uint256 r = priceEnd * 1e18 / priceStart;
    // IL_V2 = 2√r / (1+r) - 1
    uint256 il_v2 = (2 * sqrt(r) * 1e9 / (1e18 + r)) - 1e9;
    // V3 보정계수
    uint256 sqrtRatio = sqrt(priceLower * 1e18 / priceUpper);
    uint256 correction = 1e18 / (1e18 - sqrtRatio);
    ilBps = il_v2 * correction / 1e9;
}
```

---

## 동적 마진율 (Aave 이용률 곡선)

```
이용률 U = 현재 헤지 TVL / Pool 총 TVL

U < 80%:  마진율 = base_rate (12%)
U >= 80%: 마진율 = base_rate + slope × (U - 80%) / 20%
           → 최대 2~3배까지 급등 (과도한 헤지 억제)
```

---

## BELTA 토큰 구조

- **총 발행량**: 100M BELTA
- **배분**: Treasury 인센티브 40% / 팀 20%(4년 락업 1년 클리프) / 생태계 20% / 커뮤니티 10% / Reserve 10%
- **Phase 1~2**: 토큰 미발행
- **Phase 3**: 발행 + xBELTA 예치 오픈 (거래소 상장 없음)
- **Phase 3+**: Uniswap ETH/BELTA DEX 유동성 풀
- **Phase 4**: 거버넌스 투표권 활성화

### xBELTA 메커니즘 (xSUSHI 방식)

```
BELTA 예치 → xBELTA 발행
Treasury 순수익 → xBELTA 환율 상승
언스테이킹 → 수익 포함 BELTA 환급

쿨다운: 30일 (Treasury) / 7일 (Senior)
조기 인출 수수료: 2~5%
```

---

## 백테스트 핵심 결과 (phase_backtest_v4.2.0, ETH/USDC Mid Fee 22.4%)

| Phase | Treasury CAGR | Senior APY | Sharpe | Pool MDD |
|---|---|---|---|---|
| 1~2 단일 풀 | +5.1% | 5~6% | 0.71 | -8% |
| 3~4 이중 풀 | **+2.7%** | **7.3%** | **0.99** | **-10.0%** |

**이벤트별 Treasury MDD**:
- COVID: -41.2%
- LUNA: -61.6%
- FTX: -55.1%
- Aug2024: -16.0%

→ Treasury MDD 높아 보이지만 Pool 전체 MDD는 -10% 이하 유지 (Senior가 완충)

---

## 백서 & 파일 현황

| 파일 | 경로 | 설명 |
|---|---|---|
| 백서 | `BELTA_LABS_Whitepaper_v5.0.1.html` | 최신 백서 |
| 홈페이지 | `index.html` (= BELTA_Home.html) | GitHub Pages 메인 |
| 로드맵 | `BELTA_Roadmap_KR_v3.html` | 홈에서 iframe 연결 |
| 백테스트 | `phase_backtest_v4_2_0.py` | Python, 로컬 실행 |

---

## 개발 우선순위 (현재)

1. **BELTAHook.sol** — V4 Hook, IL 측정 + 프리미엄 징수 (최우선)
2. **UnderwriterPool.sol** — ERC-4626, Phase 1~2 단일 풀 먼저
3. **EpochSettlement.sol** — 7일 정산 로직
4. **PremiumOracle.sol** — 동적 마진율
5. **TreasuryModule.sol** — 버퍼 관리
6. **Fork test** — Mainnet fork로 블랙스완 재현

---

## 자주 묻는 것들

**Q. Coverage 45%인데 왜 백서에 "손실 94% 방어"라고 나오나?**
A. 다른 맥락. Coverage 45%는 IL 자체의 보상 한도. "94% 방어"는 ETH -50% 시 수수료 수익까지 합산한 LP 순손익(-5.4%) 기준으로 -0.33%까지 줄었다는 의미.

**Q. IL은 하락장에서만 발생하나?**
A. 아님. 급등=급락 동일. 가격 변동 방향 무관, 폭에만 비례. 하락장이 더 나쁘게 느껴지는 건 거래량 감소로 수수료가 줄기 때문.

**Q. BELTA의 핵심 가치는?**
A. "IL 리스크 때문에 못 했던 좁은 범위 / 고변동성 페어 LP 전략을 안전하게 쓸 수 있게 해주는 인프라". 현물 대비 우위가 아닌 고수익 LP 전략 enabler.

---

*최종 업데이트: 2026년 3월 | Claude.ai ↔ Claude Code 연동용*
