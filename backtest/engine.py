"""
BELTA Labs — Backtesting Engine
================================
실제 ETH/USDC 가격 데이터로 BELTA Protocol 성능을 시뮬레이션합니다.

시뮬레이션 항목:
  1. LP의 Impermanent Loss (V3 concentrated liquidity)
  2. 프리미엄 수집 (Aave-style utilization curve)
  3. UnderwriterPool 지급 능력
  4. Treasury 건전성
  5. 에포크별 정산

Usage:
  python backtest/engine.py
"""

import json
import math
import os
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Optional

import matplotlib
matplotlib.use('Agg')  # Non-interactive backend
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
import numpy as np
import pandas as pd
import requests


# ═══════════════════════════════════════════════════════════
# Protocol Parameters (from CLAUDE.md)
# ═══════════════════════════════════════════════════════════
COVERAGE_CAP = 0.45          # 45% IL coverage
BASE_PREMIUM_RATE = 0.12     # 12% annualized
EPOCH_DAYS = 7               # 7-day epochs
KINK_UTILIZATION = 0.80      # 80% kink
MAX_MULTIPLIER = 3.0         # 3x max premium above kink
CAP_MULT = 5                 # pool capacity = 5x TVL
DAILY_PAY_LIMIT = 0.05       # 5% of pool per day
TREASURY_RATIO = 0.20        # 20% of premiums → treasury
SELF_HEAL_RATIO = 0.20       # 20% of premiums for self-healing


# ═══════════════════════════════════════════════════════════
# Data Fetching
# ═══════════════════════════════════════════════════════════
def fetch_eth_prices(days: int = 365) -> pd.DataFrame:
    """CoinGecko에서 ETH/USD 일별 가격 데이터를 가져옵니다."""
    print(f"📡 Fetching ETH price data ({days} days)...")

    url = "https://api.coingecko.com/api/v3/coins/ethereum/market_chart"
    params = {"vs_currency": "usd", "days": days, "interval": "daily"}

    try:
        resp = requests.get(url, params=params, timeout=30)
        resp.raise_for_status()
        data = resp.json()
    except Exception as e:
        print(f"⚠️  CoinGecko API failed: {e}")
        print("📂 Using cached/generated data instead...")
        return _generate_sample_data(days)

    prices = data.get("prices", [])
    if not prices:
        return _generate_sample_data(days)

    df = pd.DataFrame(prices, columns=["timestamp", "price"])
    df["date"] = pd.to_datetime(df["timestamp"], unit="ms")
    df = df[["date", "price"]].set_index("date")

    print(f"✅ Got {len(df)} data points: ${df['price'].iloc[0]:.0f} → ${df['price'].iloc[-1]:.0f}")
    return df


def _generate_sample_data(days: int) -> pd.DataFrame:
    """API 실패 시 현실적인 가격 데이터를 생성합니다."""
    np.random.seed(42)
    dates = pd.date_range(end=datetime.now(), periods=days, freq="D")

    # Geometric Brownian Motion (연간 변동성 80%)
    dt = 1 / 365
    mu = 0.0  # drift
    sigma = 0.80  # annual volatility

    log_returns = np.random.normal(mu * dt, sigma * np.sqrt(dt), days)
    price_path = 2000 * np.exp(np.cumsum(log_returns))

    df = pd.DataFrame({"price": price_path}, index=dates)
    df.index.name = "date"
    print(f"🔧 Generated {days} synthetic data points: ${price_path[0]:.0f} → ${price_path[-1]:.0f}")
    return df


# ═══════════════════════════════════════════════════════════
# IL Calculation (Uniswap V3 Concentrated Liquidity)
# ═══════════════════════════════════════════════════════════
def calculate_il_v2(price_ratio: float) -> float:
    """Uniswap V2 IL 계산: IL = 2√r/(1+r) - 1"""
    if price_ratio <= 0:
        return 0.0
    sqrt_r = math.sqrt(price_ratio)
    return 2 * sqrt_r / (1 + price_ratio) - 1


def calculate_il_v3(price_ratio: float, pa: float, pb: float) -> float:
    """
    Uniswap V3 Concentrated Liquidity IL 계산
    IL_V3 = IL_V2 × concentration_factor
    concentration_factor = 1 / (1 - √(Pa/Pb))
    """
    if pa >= pb or price_ratio <= 0:
        return 0.0

    il_v2 = calculate_il_v2(price_ratio)
    concentration = 1 / (1 - math.sqrt(pa / pb))

    return il_v2 * concentration


def tick_to_price(tick: int) -> float:
    """Uniswap tick → 가격 변환"""
    return 1.0001 ** tick


# ═══════════════════════════════════════════════════════════
# Premium Rate Calculation (Aave-style curve)
# ═══════════════════════════════════════════════════════════
def get_premium_rate(utilization: float) -> float:
    """
    Aave-style utilization curve:
      - below kink (80%): linear from base_rate to base_rate
      - above kink: steep increase up to max_multiplier × base_rate
    """
    if utilization <= KINK_UTILIZATION:
        return BASE_PREMIUM_RATE
    else:
        excess = (utilization - KINK_UTILIZATION) / (1 - KINK_UTILIZATION)
        return BASE_PREMIUM_RATE * (1 + (MAX_MULTIPLIER - 1) * excess)


# ═══════════════════════════════════════════════════════════
# Simulation Data Structures
# ═══════════════════════════════════════════════════════════
@dataclass
class LPPosition:
    """LP 포지션"""
    liquidity_usd: float       # 포지션 크기 (USD)
    entry_price: float         # 진입 가격
    tick_lower: int = -6000    # 약 ±30% 범위
    tick_upper: int = 6000
    premiums_paid: float = 0.0
    il_claimed: float = 0.0
    entry_date: Optional[datetime] = None


@dataclass
class ProtocolState:
    """프로토콜 상태"""
    pool_tvl: float = 0.0              # UnderwriterPool TVL
    treasury_buffer: float = 0.0       # Treasury buffer
    total_premiums_collected: float = 0.0
    total_il_paid: float = 0.0
    total_treasury_absorbed: float = 0.0
    epoch: int = 0

    # 히스토리 추적
    history: list = field(default_factory=list)


@dataclass
class EpochResult:
    """에포크 정산 결과"""
    epoch: int
    date: datetime
    eth_price: float
    price_change_pct: float

    # IL 관련
    il_v2: float
    il_v3: float
    il_usd: float
    covered_il: float

    # 재정
    premium_collected: float
    premium_to_pool: float
    premium_to_treasury: float
    il_payout: float
    treasury_absorbed: float

    # 풀 상태
    pool_tvl: float
    treasury_buffer: float
    utilization: float
    premium_rate: float
    pool_pnl: float  # premium - payout for pool

    # 누적
    cumulative_premiums: float
    cumulative_payouts: float
    cumulative_pnl: float


# ═══════════════════════════════════════════════════════════
# Backtesting Engine
# ═══════════════════════════════════════════════════════════
class BELTABacktester:
    """
    BELTA Protocol Backtesting Engine

    실제 가격 데이터를 사용하여 프로토콜의 성능을 시뮬레이션합니다.
    """

    def __init__(
        self,
        initial_pool_tvl: float = 1_000_000,    # $1M underwriter pool
        initial_treasury: float = 200_000,       # $200K treasury
        lp_position_size: float = 500_000,       # $500K LP position
        tick_lower: int = -6000,                 # ~±30% range
        tick_upper: int = 6000,
    ):
        self.state = ProtocolState(
            pool_tvl=initial_pool_tvl,
            treasury_buffer=initial_treasury,
        )

        self.lp = LPPosition(
            liquidity_usd=lp_position_size,
            entry_price=0,  # set at simulation start
            tick_lower=tick_lower,
            tick_upper=tick_upper,
        )

        self.results: list[EpochResult] = []
        self.initial_pool_tvl = initial_pool_tvl
        self.initial_treasury = initial_treasury

    def run(self, prices: pd.DataFrame) -> list[EpochResult]:
        """메인 시뮬레이션 실행"""
        print("\n🚀 Starting BELTA Backtesting Simulation...")
        print(f"   Pool TVL: ${self.state.pool_tvl:,.0f}")
        print(f"   Treasury: ${self.state.treasury_buffer:,.0f}")
        print(f"   LP Position: ${self.lp.liquidity_usd:,.0f}")
        print(f"   Tick Range: [{self.lp.tick_lower}, {self.lp.tick_upper}]")
        print(f"   Coverage Cap: {COVERAGE_CAP*100}%")
        print(f"   Epoch: {EPOCH_DAYS} days")
        print()

        # 진입 가격 설정
        self.lp.entry_price = prices["price"].iloc[0]
        self.lp.entry_date = prices.index[0]

        # 에포크 단위로 시뮬레이션
        epoch_prices = prices.resample(f"{EPOCH_DAYS}D").last().dropna()

        cumulative_premiums = 0.0
        cumulative_payouts = 0.0

        for i in range(1, len(epoch_prices)):
            self.state.epoch += 1

            current_price = epoch_prices["price"].iloc[i]
            prev_price = epoch_prices["price"].iloc[i - 1]
            entry_price = self.lp.entry_price
            epoch_date = epoch_prices.index[i]

            # ─── 1. 가격 변화 ──────────────────────────
            price_ratio = current_price / entry_price
            price_change = (current_price - prev_price) / prev_price

            # ─── 2. IL 계산 ────────────────────────────
            il_v2 = abs(calculate_il_v2(price_ratio))

            pa = tick_to_price(self.lp.tick_lower)
            pb = tick_to_price(self.lp.tick_upper)
            il_v3 = abs(calculate_il_v3(price_ratio, pa, pb))

            # IL 금액 (USD)
            il_usd = il_v3 * self.lp.liquidity_usd

            # Coverage cap 적용
            covered_il = min(il_usd, self.lp.liquidity_usd * COVERAGE_CAP)

            # ─── 3. 프리미엄 계산 ──────────────────────
            capacity = self.state.pool_tvl * CAP_MULT
            utilization = covered_il / capacity if capacity > 0 else 0
            utilization = min(utilization, 1.0)

            premium_rate = get_premium_rate(utilization)
            epoch_premium = (premium_rate / 365 * EPOCH_DAYS) * self.lp.liquidity_usd

            # 프리미엄 분배
            premium_to_treasury = epoch_premium * TREASURY_RATIO
            premium_to_pool = epoch_premium - premium_to_treasury

            self.state.total_premiums_collected += epoch_premium
            cumulative_premiums += epoch_premium

            # ─── 4. IL 지급 ────────────────────────────
            # 이전 에포크 대비 증분 IL만 지급
            prev_il = 0
            if len(self.results) > 0:
                prev_il = self.results[-1].covered_il

            incremental_il = max(0, covered_il - prev_il)

            # Daily pay limit 적용
            daily_limit = self.state.pool_tvl * DAILY_PAY_LIMIT
            epoch_limit = daily_limit * EPOCH_DAYS
            actual_payout = min(incremental_il, epoch_limit)

            # Treasury first-loss absorption
            treasury_absorbed = 0
            if actual_payout > 0 and self.state.treasury_buffer > 0:
                treasury_absorbed = min(actual_payout * 0.30, self.state.treasury_buffer)
                self.state.treasury_buffer -= treasury_absorbed
                self.state.total_treasury_absorbed += treasury_absorbed

            pool_payout = actual_payout - treasury_absorbed

            if pool_payout > self.state.pool_tvl:
                pool_payout = self.state.pool_tvl  # 풀 이상 지급 불가

            self.state.pool_tvl -= pool_payout
            self.state.pool_tvl += premium_to_pool
            self.state.treasury_buffer += premium_to_treasury

            # Treasury self-healing
            if self.state.treasury_buffer < self.initial_treasury * 0.5:
                heal_amount = premium_to_pool * SELF_HEAL_RATIO
                self.state.treasury_buffer += heal_amount
                self.state.pool_tvl -= heal_amount

            self.state.total_il_paid += actual_payout
            cumulative_payouts += actual_payout

            self.lp.premiums_paid += epoch_premium
            self.lp.il_claimed += actual_payout

            pool_pnl = premium_to_pool - pool_payout
            cumulative_pnl = cumulative_premiums - cumulative_payouts

            # ─── 5. 결과 기록 ──────────────────────────
            result = EpochResult(
                epoch=self.state.epoch,
                date=epoch_date,
                eth_price=current_price,
                price_change_pct=price_change * 100,
                il_v2=il_v2 * 100,
                il_v3=il_v3 * 100,
                il_usd=il_usd,
                covered_il=covered_il,
                premium_collected=epoch_premium,
                premium_to_pool=premium_to_pool,
                premium_to_treasury=premium_to_treasury,
                il_payout=actual_payout,
                treasury_absorbed=treasury_absorbed,
                pool_tvl=self.state.pool_tvl,
                treasury_buffer=self.state.treasury_buffer,
                utilization=utilization * 100,
                premium_rate=premium_rate * 100,
                pool_pnl=pool_pnl,
                cumulative_premiums=cumulative_premiums,
                cumulative_payouts=cumulative_payouts,
                cumulative_pnl=cumulative_pnl,
            )
            self.results.append(result)

        print(f"✅ Simulation complete: {len(self.results)} epochs processed")
        return self.results

    def print_summary(self):
        """시뮬레이션 결과 요약 출력"""
        if not self.results:
            print("No results to summarize")
            return

        r = self.results
        last = r[-1]

        max_il = max(x.il_v3 for x in r)
        max_il_date = [x for x in r if x.il_v3 == max_il][0].date
        max_drawdown = min(x.pool_pnl for x in r)
        profitable_epochs = sum(1 for x in r if x.pool_pnl >= 0)

        print("\n" + "=" * 60)
        print("  BELTA BACKTESTING RESULTS")
        print("=" * 60)
        print(f"\n📅 Period: {r[0].date.strftime('%Y-%m-%d')} → {last.date.strftime('%Y-%m-%d')}")
        print(f"📊 Epochs: {len(r)} ({len(r) * EPOCH_DAYS} days)")
        print(f"💰 ETH Price: ${r[0].eth_price:,.0f} → ${last.eth_price:,.0f} ({((last.eth_price/r[0].eth_price)-1)*100:+.1f}%)")

        print(f"\n─── IL Analysis ───────────────────────")
        print(f"  Max V2 IL:          {max(x.il_v2 for x in r):.2f}%")
        print(f"  Max V3 IL:          {max_il:.2f}% (on {max_il_date.strftime('%Y-%m-%d')})")
        print(f"  Max IL (USD):       ${max(x.il_usd for x in r):,.0f}")
        print(f"  Final IL (V3):      {last.il_v3:.2f}%")

        print(f"\n─── Protocol P&L ─────────────────────")
        print(f"  Total Premiums:     ${last.cumulative_premiums:,.0f}")
        print(f"  Total IL Payouts:   ${last.cumulative_payouts:,.0f}")
        print(f"  Net P&L:            ${last.cumulative_pnl:,.0f}")
        print(f"  Treasury Absorbed:  ${self.state.total_treasury_absorbed:,.0f}")
        print(f"  Profitable Epochs:  {profitable_epochs}/{len(r)} ({profitable_epochs/len(r)*100:.0f}%)")

        print(f"\n─── Pool Health ──────────────────────")
        print(f"  Initial Pool TVL:   ${self.initial_pool_tvl:,.0f}")
        print(f"  Final Pool TVL:     ${last.pool_tvl:,.0f} ({((last.pool_tvl/self.initial_pool_tvl)-1)*100:+.1f}%)")
        print(f"  Initial Treasury:   ${self.initial_treasury:,.0f}")
        print(f"  Final Treasury:     ${last.treasury_buffer:,.0f} ({((last.treasury_buffer/self.initial_treasury)-1)*100:+.1f}%)")
        print(f"  Max Epoch Drawdown: ${abs(max_drawdown):,.0f}")

        # LP 관점
        lp_net = self.lp.il_claimed - self.lp.premiums_paid
        unhedged_il = max(x.il_usd for x in r)
        hedged_loss = unhedged_il - self.lp.il_claimed

        print(f"\n─── LP Perspective ───────────────────")
        print(f"  Position Size:      ${self.lp.liquidity_usd:,.0f}")
        print(f"  Premiums Paid:      ${self.lp.premiums_paid:,.0f} ({self.lp.premiums_paid/self.lp.liquidity_usd*100:.1f}%)")
        print(f"  IL Recovered:       ${self.lp.il_claimed:,.0f}")
        print(f"  LP Net:             ${lp_net:,.0f}")
        print(f"  Worst-case IL:      ${unhedged_il:,.0f}")
        print(f"  Hedged Loss:        ${hedged_loss:,.0f} (saved {(1-hedged_loss/unhedged_il)*100:.0f}% vs unhedged)")

        # Underwriter 수익률
        uw_return = last.cumulative_pnl / self.initial_pool_tvl * 100
        uw_apy = uw_return / (len(r) * EPOCH_DAYS / 365)

        print(f"\n─── Underwriter Returns ──────────────")
        print(f"  Pool Return:        {uw_return:+.2f}%")
        print(f"  Annualized:         {uw_apy:+.2f}% APY")
        print(f"  Worst Epoch Loss:   ${abs(max_drawdown):,.0f}")

        # 위험 지표
        sharpe = self._calculate_sharpe()
        print(f"\n─── Risk Metrics ─────────────────────")
        print(f"  Sharpe Ratio:       {sharpe:.2f}")
        print(f"  Max Utilization:    {max(x.utilization for x in r):.1f}%")
        print(f"  Avg Utilization:    {np.mean([x.utilization for x in r]):.1f}%")
        print(f"  Solvency Maintained: {'✅ YES' if last.pool_tvl > 0 else '❌ NO'}")
        print("=" * 60)

    def _calculate_sharpe(self) -> float:
        """Sharpe Ratio 계산"""
        if not self.results:
            return 0.0
        pnls = [x.pool_pnl for x in self.results]
        if np.std(pnls) == 0:
            return 0.0
        return np.mean(pnls) / np.std(pnls) * np.sqrt(52 / EPOCH_DAYS)  # annualized


# ═══════════════════════════════════════════════════════════
# Chart Generation
# ═══════════════════════════════════════════════════════════
def generate_charts(results: list[EpochResult], output_dir: str):
    """백테스팅 결과 차트를 생성합니다."""
    if not results:
        return

    os.makedirs(output_dir, exist_ok=True)

    dates = [r.date for r in results]

    # 색상 테마 (BELTA 브랜드)
    BG_COLOR = "#0a0e1a"
    TEXT_COLOR = "#e0e0e0"
    NEON_GREEN = "#00ff88"
    NEON_BLUE = "#00d4ff"
    NEON_RED = "#ff4466"
    NEON_YELLOW = "#ffcc00"
    GRID_COLOR = "#1a2040"

    plt.rcParams.update({
        "figure.facecolor": BG_COLOR,
        "axes.facecolor": BG_COLOR,
        "axes.edgecolor": GRID_COLOR,
        "text.color": TEXT_COLOR,
        "axes.labelcolor": TEXT_COLOR,
        "xtick.color": TEXT_COLOR,
        "ytick.color": TEXT_COLOR,
        "grid.color": GRID_COLOR,
        "font.size": 10,
    })

    # ─── Chart 1: ETH Price + IL ──────────────────────
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(14, 8), sharex=True)
    fig.suptitle("BELTA Backtest: ETH Price & Impermanent Loss", fontsize=14, color=NEON_GREEN)

    ax1.plot(dates, [r.eth_price for r in results], color=NEON_BLUE, linewidth=1.5, label="ETH Price")
    ax1.fill_between(dates, [r.eth_price for r in results], alpha=0.1, color=NEON_BLUE)
    ax1.set_ylabel("ETH Price (USD)")
    ax1.legend(loc="upper left")
    ax1.grid(True, alpha=0.3)

    ax2.plot(dates, [r.il_v2 for r in results], color=NEON_YELLOW, linewidth=1, alpha=0.7, label="IL V2")
    ax2.plot(dates, [r.il_v3 for r in results], color=NEON_RED, linewidth=1.5, label="IL V3 (Concentrated)")
    ax2.fill_between(dates, [r.il_v3 for r in results], alpha=0.15, color=NEON_RED)
    ax2.set_ylabel("Impermanent Loss (%)")
    ax2.set_xlabel("Date")
    ax2.legend(loc="upper left")
    ax2.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig(f"{output_dir}/01_price_and_il.png", dpi=150, bbox_inches="tight")
    plt.close()
    print("📊 Chart 1: Price & IL saved")

    # ─── Chart 2: Protocol P&L ────────────────────────
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(14, 8), sharex=True)
    fig.suptitle("BELTA Backtest: Protocol P&L", fontsize=14, color=NEON_GREEN)

    ax1.bar(dates, [r.premium_collected for r in results], width=EPOCH_DAYS,
            color=NEON_GREEN, alpha=0.6, label="Premium Collected")
    ax1.bar(dates, [-r.il_payout for r in results], width=EPOCH_DAYS,
            color=NEON_RED, alpha=0.6, label="IL Payout")
    ax1.set_ylabel("USD per Epoch")
    ax1.legend(loc="upper left")
    ax1.grid(True, alpha=0.3)
    ax1.axhline(y=0, color=TEXT_COLOR, linewidth=0.5)

    ax2.plot(dates, [r.cumulative_premiums for r in results], color=NEON_GREEN,
             linewidth=1.5, label="Cumulative Premiums")
    ax2.plot(dates, [r.cumulative_payouts for r in results], color=NEON_RED,
             linewidth=1.5, label="Cumulative Payouts")
    ax2.plot(dates, [r.cumulative_pnl for r in results], color=NEON_BLUE,
             linewidth=2, label="Net P&L")
    ax2.fill_between(dates, [r.cumulative_pnl for r in results], alpha=0.1, color=NEON_BLUE)
    ax2.set_ylabel("Cumulative USD")
    ax2.set_xlabel("Date")
    ax2.legend(loc="upper left")
    ax2.grid(True, alpha=0.3)
    ax2.axhline(y=0, color=TEXT_COLOR, linewidth=0.5)

    plt.tight_layout()
    plt.savefig(f"{output_dir}/02_protocol_pnl.png", dpi=150, bbox_inches="tight")
    plt.close()
    print("📊 Chart 2: Protocol P&L saved")

    # ─── Chart 3: Pool Health ─────────────────────────
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(14, 8), sharex=True)
    fig.suptitle("BELTA Backtest: Pool & Treasury Health", fontsize=14, color=NEON_GREEN)

    ax1.plot(dates, [r.pool_tvl for r in results], color=NEON_BLUE, linewidth=1.5, label="Pool TVL")
    ax1.plot(dates, [r.treasury_buffer for r in results], color=NEON_YELLOW, linewidth=1.5, label="Treasury Buffer")
    ax1.set_ylabel("USD")
    ax1.legend(loc="upper left")
    ax1.grid(True, alpha=0.3)

    ax2.plot(dates, [r.utilization for r in results], color=NEON_RED, linewidth=1.5, label="Utilization %")
    ax2.plot(dates, [r.premium_rate for r in results], color=NEON_GREEN, linewidth=1,
             alpha=0.7, label="Premium Rate %")
    ax2.axhline(y=KINK_UTILIZATION * 100, color=NEON_YELLOW, linewidth=1,
                linestyle="--", alpha=0.5, label=f"Kink ({KINK_UTILIZATION*100}%)")
    ax2.set_ylabel("Percentage (%)")
    ax2.set_xlabel("Date")
    ax2.legend(loc="upper left")
    ax2.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig(f"{output_dir}/03_pool_health.png", dpi=150, bbox_inches="tight")
    plt.close()
    print("📊 Chart 3: Pool Health saved")

    # ─── Chart 4: LP Comparison ───────────────────────
    fig, ax = plt.subplots(1, 1, figsize=(14, 6))
    fig.suptitle("BELTA Backtest: LP — Hedged vs Unhedged", fontsize=14, color=NEON_GREEN)

    lp_size = results[0].il_usd / (results[0].il_v3 / 100) if results[0].il_v3 > 0 else 500000

    unhedged_loss = [r.il_usd for r in results]
    hedged_loss = []
    cum_premium = 0
    cum_claim = 0
    for r in results:
        cum_premium += r.premium_collected
        cum_claim += r.il_payout
        hedged = r.il_usd - cum_claim + cum_premium
        hedged_loss.append(max(0, hedged))

    ax.plot(dates, unhedged_loss, color=NEON_RED, linewidth=2, label="Unhedged IL (USD)")
    ax.plot(dates, hedged_loss, color=NEON_GREEN, linewidth=2, label="Hedged Net Loss (USD)")
    ax.fill_between(dates, unhedged_loss, hedged_loss, alpha=0.15, color=NEON_GREEN, label="Savings from BELTA")
    ax.set_ylabel("Loss (USD)")
    ax.set_xlabel("Date")
    ax.legend(loc="upper left")
    ax.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig(f"{output_dir}/04_lp_comparison.png", dpi=150, bbox_inches="tight")
    plt.close()
    print("📊 Chart 4: LP Comparison saved")

    print(f"\n📁 All charts saved to: {output_dir}/")


# ═══════════════════════════════════════════════════════════
# Scenario Presets
# ═══════════════════════════════════════════════════════════
SCENARIOS = {
    "baseline": {
        "name": "Baseline (1 Year)",
        "days": 365,
        "pool_tvl": 1_000_000,
        "treasury": 200_000,
        "lp_size": 500_000,
    },
    "bear": {
        "name": "Bear Market (COVID + LUNA)",
        "days": 730,  # 2 years
        "pool_tvl": 2_000_000,
        "treasury": 400_000,
        "lp_size": 1_000_000,
    },
    "stress": {
        "name": "Stress Test (Small Pool)",
        "days": 365,
        "pool_tvl": 200_000,
        "treasury": 40_000,
        "lp_size": 500_000,  # LP > Pool → high utilization
    },
    "whale": {
        "name": "Whale LP (Large Position)",
        "days": 365,
        "pool_tvl": 5_000_000,
        "treasury": 1_000_000,
        "lp_size": 2_000_000,
    },
}


# ═══════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════
def run_scenario(scenario_key: str = "baseline"):
    """시나리오 실행"""
    s = SCENARIOS[scenario_key]
    print(f"\n{'='*60}")
    print(f"  SCENARIO: {s['name']}")
    print(f"{'='*60}")

    prices = fetch_eth_prices(s["days"])

    bt = BELTABacktester(
        initial_pool_tvl=s["pool_tvl"],
        initial_treasury=s["treasury"],
        lp_position_size=s["lp_size"],
    )

    results = bt.run(prices)
    bt.print_summary()

    output_dir = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "results",
        scenario_key
    )
    generate_charts(results, output_dir)

    return bt, results


def run_all_scenarios():
    """모든 시나리오 실행"""
    print("\n" + "=" * 60)
    print("  BELTA LABS — FULL BACKTESTING SUITE")
    print("=" * 60)

    all_results = {}
    for key in SCENARIOS:
        bt, results = run_scenario(key)
        all_results[key] = (bt, results)

    # 비교 테이블
    print("\n" + "=" * 60)
    print("  SCENARIO COMPARISON")
    print("=" * 60)
    print(f"{'Scenario':<20} {'Net P&L':>12} {'UW APY':>10} {'Max IL':>10} {'Solvent':>10}")
    print("-" * 62)

    for key, (bt, results) in all_results.items():
        if results:
            last = results[-1]
            pnl = last.cumulative_pnl
            days = len(results) * EPOCH_DAYS
            apy = (pnl / bt.initial_pool_tvl) / (days / 365) * 100
            max_il = max(r.il_v3 for r in results)
            solvent = "✅" if last.pool_tvl > 0 else "❌"
            print(f"{SCENARIOS[key]['name']:<20} ${pnl:>10,.0f} {apy:>9.1f}% {max_il:>9.1f}% {solvent:>10}")

    print("=" * 62)


if __name__ == "__main__":
    if len(sys.argv) > 1:
        scenario = sys.argv[1]
        if scenario == "all":
            run_all_scenarios()
        elif scenario in SCENARIOS:
            run_scenario(scenario)
        else:
            print(f"Unknown scenario: {scenario}")
            print(f"Available: {', '.join(SCENARIOS.keys())}, all")
    else:
        run_all_scenarios()
