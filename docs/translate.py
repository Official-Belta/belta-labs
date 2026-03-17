#!/usr/bin/env python3
"""Translate BELTA whitepaper from Korean to English."""
import re

with open('whitepaper.html', 'r', encoding='utf-8') as f:
    c = f.read()

# Massive replacement dictionary
R = {
    # === CSS comments (keep but translate) ===
    '/* h2 뒤에 최소 4줄 남지 않으면 다음 페이지로 */': '/* Push h2 to next page if fewer than 4 lines remain */',
    '/* highlight 박스가 h2 바로 뒤에 올 때 같이 넘기기 */': '/* Keep highlight box together with preceding h2 */',

    # === Cover ===
    '5.1년': '5.1 yrs',
    '실측 패닉 에포크': 'Measured Panic Epochs',
    '33회': '33',
    'LP 이탈 방지': 'LP Retention',
    'V4 Hook 생태계': 'V4 Hook Ecosystem',

    # === Section 02 ===
    '<!-- ══════════ 02. 문제 정의 ══════════ -->': '<!-- ══════════ 02. PROBLEM DEFINITION ══════════ -->',
    "비영구적 손실(IL)은 AMM에 유동성을 공급했을 때, 자산을 단순 보유(HODL)했을 경우와 비교한 가치 손실이다. '비영구적'이라는 명칭은 가격이 원점으로 돌아오면 손실이 사라지기 때문이지만, 현실에서는 가격이 원점으로 돌아오지 않는 경우가 대부분이어서 사실상 영구 손실에 가깝다.": "Impermanent Loss (IL) is the value loss compared to simply holding (HODL) assets when providing liquidity to an AMM. It is called 'impermanent' because the loss disappears if prices return to the original level, but in practice prices rarely revert, making it effectively a permanent loss.",
    'Uniswap V3의 집중 유동성은 수수료 효율을 높이는 대신, 범위 이탈 시 포지션이 수수료를 전혀 받지 못하며 IL이 범위 폭에 반비례하여 증폭된다.': "Uniswap V3's concentrated liquidity increases fee efficiency, but when price exits the range, positions earn zero fees and IL amplifies inversely proportional to range width.",
    '* 이벤트 스파이크(COVID, LUNA, FTX) 포함 실효 IL 기준': '* Effective IL including event spikes (COVID, LUNA, FTX)',
    'ETH/USDC 수수료 APY (현재 실측)': 'ETH/USDC Fee APY (current measured)',
    'TVL $71.4M, 일 거래량 $87.6M 기준': 'Based on TVL $71.4M, daily volume $87.6M',
    'ETH/USDC 수수료 APY (강세 시)': 'ETH/USDC Fee APY (bull market)',
    '2024년 상승장 실측치': '2024 bull market measured',
    '연간 IL 비용 (Medium 범위)': 'Annual IL Cost (Medium range)',
    '이벤트 포함': 'Including events',
    '손실 기록 LP 비율': 'LP Loss Rate',
    '학술 연구 기준': 'Based on academic research',
    '헤지 적용 LP 순 수익 (현재 기준)': 'Hedged LP Net Return (current)',
    '22.4% - 2.69% 프리미엄 + 1.38% 보상': '22.4% - 2.69% premium + 1.38% compensation',
    'IL 제거 불가, 관리 수수료 발생': 'Cannot eliminate IL, management fees apply',
    '수수료 효율 급감': 'Fee efficiency drops sharply',
    'dYdX/GMX 숏': 'dYdX/GMX short',
    '모니터링 + 리밸런싱 + 펀딩 관리 = trading desk 수준 운영': 'Monitoring + rebalancing + funding management = trading desk-level operation',
    '유동성 낮음, 프리미엄 고가, 만기 관리 복잡': 'Low liquidity, expensive premiums, complex expiry management',
    'V4 Hook 자동 헤지': 'V4 Hook auto-hedge',
    '풀에 유동성만 넣으면 끝 — LP 조작 불필요, 자동 정산': 'Just provide liquidity — no LP manipulation needed, automatic settlement',

    # Manual hedging box
    'Manual Hedging vs BELTA — 왜 직접 안 하는가:': 'Manual Hedging vs BELTA — Why not do it yourself:',
    '기관 LP가 Perps로 IL을 직접 헤지하려면 ① 포지션 실시간 모니터링 ② 헤지 비율 계산 ③ Perp 매매 실행 ④ 펀딩레이트 관리 ⑤ 주기적 리밸런싱이 필요하다. 이는 사실상 trading desk 운영이며, $10K~$1M LP에게는 인프라 비용이 수익을 초과한다.': 'For institutional LPs to hedge IL with Perps directly requires (1) real-time position monitoring (2) hedge ratio calculation (3) perp trade execution (4) funding rate management (5) periodic rebalancing. This is effectively running a trading desk, and for $10K~$1M LPs, infrastructure costs exceed returns.',
    'BELTA는 이 전체 과정을 V4 Hook으로 자동화하여, manual hedging을 passive risk infrastructure로 전환한다.': 'BELTA automates this entire process via V4 Hooks, transforming manual hedging into passive risk infrastructure.',

    # === Section 03 ===
    '<!-- ══════════ 03. 프로토콜 설계 ══════════ -->': '<!-- ══════════ 03. PROTOCOL DESIGN ══════════ -->',
    'Uniswap V4의 Hook 시스템을 활용하여 LP 포지션 생성·청산·스왑 이벤트를 온체인에서 직접 감지하고 IL을 자동 정산한다. LP는 별도의 트랜잭션 없이 헤지 혜택을 받는다.': "Utilizing Uniswap V4's Hook system to directly detect LP position creation, removal, and swap events on-chain for automatic IL settlement. LPs receive hedging benefits without separate transactions.",
    '포지션 등록, 언더라이팅 검증, 진입가 스냅샷 저장': 'Position registration, underwriting verification, entry price snapshot',
    '프리미엄 누적, IL epoch 업데이트': 'Premium accumulation, IL epoch update',
    'IL 계산, Coverage 비율 적용, 정산금 자동 지급': 'IL calculation, coverage ratio applied, automatic settlement payout',
    '서킷 브레이커 점검, 이상 거래 감지': 'Circuit breaker check, anomalous trade detection',
    'V4 Hook 메인 컨트랙트 — IL 계산, 정산 로직, Dynamic Fee (beforeSwap)': 'V4 Hook main contract — IL calculation, settlement logic, Dynamic Fee (beforeSwap)',
    'ERC-4626 Vault — Underwriter Pool 관리, 프리미엄 배분, 쿨다운': 'ERC-4626 Vault — Underwriter Pool management, premium distribution, cooldown',
    '7일 에포크 IL 정산 — Keeper 자동화, 일일 지급 상한 적용': '7-day epoch IL settlement — Keeper automation, daily payout cap',
    '동적 마진율 산출 — Aave 이용률 곡선 (80% kink, 최대 3x)': 'Dynamic margin rate — Aave utilization curve (80% kink, max 3x)',
    'Treasury 버퍼 관리 + Aave Yield Stacking (Layer 2)': 'Treasury buffer management + Aave Yield Stacking (Layer 2)',
    'EWMA 변동성 추적 — Dynamic Fee 곡선 계산 (Layer 1)': 'EWMA volatility tracking — Dynamic Fee curve calculation (Layer 1)',
    'Perps Delta-Hedging — dYdX/GMX/Hyperliquid 어댑터 (Layer 3, Phase 2+)': 'Perps Delta-Hedging — dYdX/GMX/Hyperliquid adapter (Layer 3, Phase 2+)',
    '서킷 브레이커': 'Circuit Breaker',
    '24시간 IL 지급액이 Pool의 30% 초과 시 자동 일시 중지': 'Automatic pause when 24h IL payouts exceed 30% of Pool',
    '일일 지급 한도': 'Daily Payout Cap',
    'Pool 잔액의 5% 초과 단일 지급 불가': 'No single payout exceeding 5% of Pool balance',
    '다중 서명(Multisig)': 'Multisig',
    '프로토콜 파라미터 변경 시 3/5 서명 필요': '3/5 signatures required for protocol parameter changes',
    '오라클 이중화': 'Oracle Redundancy',
    'Chainlink + Uniswap TWAP 교차 검증': 'Chainlink + Uniswap TWAP cross-verification',
    '보안 감사': 'Security Audits',
    '전문 감사 기관 2회 (예산 $25K 배정)': '2 professional audits (budget $25K allocated)',

    # 3.4
    'BELTA IL Hedge Protocol은 Uniswap V4 Hook 기반으로 설계되어 있으며, <strong>헤지 컨트랙트는 LP 포지션과 동일 체인에 배포</strong>되어야 실시간 IL 추적 및 Epoch 정산이 가능하다. 따라서 배포 체인 선택은 프로토콜의 실효 TAM(Total Addressable Market)을 직접 결정한다.': 'BELTA IL Hedge Protocol is designed on Uniswap V4 Hooks, and <strong>hedge contracts must be deployed on the same chain as LP positions</strong> for real-time IL tracking and Epoch settlement. Therefore, deployment chain selection directly determines the protocol\'s effective TAM (Total Addressable Market).',
    '* 타겟 3개 풀(ETH/USDC + BTC/USDC + SOL/USDC) 멀티체인 합산 TAM:': '* Target 3 pools (ETH/USDC + BTC/USDC + SOL/USDC) multi-chain combined TAM:',

    # SOL note
    '⚠ SOL/USDC 특이 사항:': '⚠ SOL/USDC Special Note:',
    'Uniswap V4 내 SOL은 Wrapped SOL(ERC-20)로 유동성이 제한적이다. Solana native 생태계(Raydium, Orca)의 SOL/USDC TVL이 압도적으로 크나, V4 Hook 기반 헤지 연동은 현재 기술적으로 불가하다. Phase 4+ 시점에 Solana VM 호환 Hook 또는 크로스체인 정산 메커니즘이 성숙한 경우에 한해 확장을 검토하며, Phase 1~3 기준 SOL/USDC는 보조 풀로만 운영한다.': 'SOL within Uniswap V4 is Wrapped SOL (ERC-20) with limited liquidity. The Solana native ecosystem (Raydium, Orca) has overwhelmingly larger SOL/USDC TVL, but V4 Hook-based hedge integration is currently not technically feasible. Expansion will only be considered at Phase 4+ when Solana VM-compatible Hooks or cross-chain settlement mechanisms mature. For Phases 1~3, SOL/USDC operates as a secondary pool only.',

    # Chain selection criteria
    'V4 Hook 지원': 'V4 Hook Support',
    'PoolManager 컨트랙트가 배포된 체인만 대상': 'Only chains with deployed PoolManager contracts',
    'LP TVL 임계값': 'LP TVL Threshold',
    '타겟 풀 TVL $100M 이상인 체인 우선 (수수료 수익 지속성)': 'Priority for chains with target pool TVL $100M+ (fee revenue sustainability)',
    '오라클 신뢰성': 'Oracle Reliability',
    'Chainlink price feed + Uniswap TWAP 동시 지원 필수': 'Chainlink price feed + Uniswap TWAP simultaneous support required',
    '감사 범위': 'Audit Scope',
    '체인 추가 시 해당 체인 환경 별도 보안 감사 필수': 'Separate security audit required for each additional chain environment',

    # 3.5
    'BELTA IL Hedge Protocol은 단순 보험풀 모델의 구조적 한계(UW 수익 불안정)를 해결하기 위해 <strong>3가지 레이어</strong>를 결합하여 모든 Phase에서 Underwriter가 수익을 낼 수 있는 구조를 설계했다.': 'BELTA IL Hedge Protocol combines <strong>3 layers</strong> to solve the structural limitations of simple insurance pool models (unstable UW returns), ensuring underwriters can profit in every Phase.',
    '핵심 논리:': 'Core Logic:',
    'IL 지급 부담을 줄이면서(Layer 1, 3) 동시에 Pool 수익을 늘린다(Layer 2). 세 레이어가 독립적으로 작동하므로 어느 하나가 실패해도 전체 구조는 유지된다.': 'Reduce IL payout burden (Layers 1, 3) while increasing Pool revenue (Layer 2). The three layers operate independently, so the overall structure remains intact even if one fails.',

    # Layer 1
    '변동성 수준': 'Volatility Level',
    '수수료율': 'Fee Rate',
    '효과': 'Effect',
    '낮음': 'Low',
    '중간': 'Medium',
    '높음': 'High',
    '거래량 유치 극대화': 'Maximize volume attraction',
    '기본 수준': 'Standard level',
    'IL 발생 시기에 수수료 3~8x': 'Fee 3~8x during IL events',
    '<code>beforeSwap</code>에서 실시간 변동성을 측정해 수수료를 자동 조정한다. IL이 가장 많이 발생하는 고변동 시기에 LP 수수료 수입이 함께 증가하여 <strong>IL과 수수료 수익이 자연스럽게 상쇄</strong>된다.': '<code>beforeSwap</code> measures real-time volatility to automatically adjust fees. During high-volatility periods when IL is highest, LP fee income increases accordingly, causing <strong>IL and fee revenue to naturally offset</strong>.',
    '* LVR(Loss-Versus-Rebalancing)의 50~80% 회수 가능. 추가 APY 효과: +3~8%. V4 native — 외부 의존성 없음.': '* Can recover 50~80% of LVR (Loss-Versus-Rebalancing). Additional APY effect: +3~8%. V4 native — no external dependencies.',

    # Layer 2
    'Underwriter Pool의 유휴 자금(전체 TVL의 약 70%)을 Aave에 자동 예치하여 <strong>기본 수익을 항시 창출</strong>한다. 긴급 IL 클레임 발생 시 즉시 인출 가능하도록 30% 유동성 준비금을 유보한다.': "Automatically deposits the Underwriter Pool's idle funds (~70% of total TVL) into Aave to <strong>consistently generate base returns</strong>. Retains 30% liquidity reserve for immediate withdrawal in case of urgent IL claims.",
    'Aave 예치 자금 (70%)': 'Aave Deposited Funds (70%)',
    'Aave USDC APR (4~8%)': 'Aave USDC APR (4~8%)',
    '유동성 준비금 (30%)': 'Liquidity Reserve (30%)',
    '즉시 인출 가능': 'Immediately withdrawable',
    '추가 Pool APY 효과': 'Additional Pool APY Effect',

    # Layer 3
    'UW Pool이 IL을 지급해야 할 때, 그 IL을 <strong>Perps 숏 포지션으로 부분 상쇄</strong>한다. dYdX / GMX / Hyperliquid 어댑터를 통해 헤지 TVL의 50% 상당 ETH 숏을 유지하며, Keeper가 주기적으로 delta를 자동 조정한다.': 'When the UW Pool needs to pay IL, it <strong>partially offsets the IL with Perps short positions</strong>. Maintains ETH shorts equivalent to 50% of hedged TVL through dYdX / GMX / Hyperliquid adapters, with Keeper periodically auto-adjusting delta.',
    '헤지 없음': 'Without Hedge',
    'Layer 3 적용': 'Layer 3 Applied',
    '숏 이익 $400K 상쇄': 'Short profit $400K offset',
    '펀딩 비용 (연간)': 'Funding Cost (annual)',
    'IL 지급 부담 감소': 'IL Payout Burden Reduction',
    '* Phase 1: 설계 준비. Phase 2~3: 소규모 도입. Phase 4+: 본격 운용.': '* Phase 1: Design prep. Phase 2~3: Small-scale intro. Phase 4+: Full operation.',

    # 3-Layer combined
    '3-Layer 종합 효과 (Phase 3 기준, $10M Pool)': '3-Layer Combined Effect (Phase 3, $10M Pool)',
    'Layer 미적용': 'Without Layers',
    '3-Layer 적용': '3-Layer Applied',
    'LP 프리미엄 수입': 'LP Premium Income',
    'Dynamic Fee 추가 수입 (Layer 1)': 'Dynamic Fee Additional Income (Layer 1)',
    'Aave 이자 수입 (Layer 2)': 'Aave Interest Income (Layer 2)',
    'IL 클레임 지급': 'IL Claims Paid',
    'Perps 헤지 절감 (Layer 3)': 'Perps Hedge Savings (Layer 3)',
    'Pool 순이익': 'Pool Net Profit',
}

for old, new in R.items():
    c = c.replace(old, new)

with open('whitepaper.html', 'w', encoding='utf-8') as f:
    f.write(c)

import sys
sys.stdout.reconfigure(encoding='utf-8')
korean_chars = re.findall('[가-힣]', c[c.find('<body>'):])
print(f'Korean chars remaining: {len(korean_chars)}')
