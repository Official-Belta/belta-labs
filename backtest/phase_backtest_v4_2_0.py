"""
BELTA Labs — Phase Backtest v4.2.0
====================================
CLAUDE.md 확정 파라미터 기반 백테스트.
핵심 차이점 (vs engine_v3):
  1. Phase 3+: Treasury/Senior 이중 풀 (20:80)
  2. Treasury가 first-loss 전액 흡수 → Senior 보호
  3. Senior APY 7% 보장 (Phase 3+)
  4. CAP_MULT Phase별 차등 (5x / 6x)
  5. 5년+ 데이터 (COVID, LUNA, FTX 포함)
  6. Premium = fee income × 12% (확정)
  7. Coverage = 45% of NET IL (IL - fee offset)

Usage:
  python backtest/phase_backtest_v4_2_0.py
  python backtest/phase_backtest_v4_2_0.py [phase1|phase3|phase4|phase5|all]
"""

import math
import os
import sys
import random
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import requests


# ================================================================
# Protocol Parameters (CLAUDE.md 확정)
# ================================================================
COVERAGE_CAP = 0.45          # 45% of NET IL
PREMIUM_RATE = 0.12          # 12% of LP fee income
LP_FEE_APY = 0.224           # 22.4% Mid estimate
EPOCH_DAYS = 7
KINK_UTILIZATION = 0.80
MAX_MULTIPLIER = 3.0
DAILY_PAY_LIMIT = 0.05       # 5% of pool per day
TREASURY_RATIO = 0.20        # Treasury/Senior 분할비
SELF_HEAL_RATIO = 0.20
AAVE_BASE_YIELD = 0.05       # 5% Aave base yield
SENIOR_TARGET_APY = 0.07     # 7% Senior APY target (Phase 3+)


# ================================================================
# Data — 5년+ ETH 가격
# ================================================================
def fetch_eth_prices(days: int = 1865) -> pd.DataFrame:
    """CoinGecko max 데이터 또는 합성 데이터"""
    print(f"  Fetching ETH prices ({days}d)...")

    # CoinGecko free API는 최대 365일 → 긴 기간은 합성 데이터 사용
    if days <= 365:
        url = "https://api.coingecko.com/api/v3/coins/ethereum/market_chart"
        params = {"vs_currency": "usd", "days": days, "interval": "daily"}
        try:
            resp = requests.get(url, params=params, timeout=30)
            resp.raise_for_status()
            data = resp.json()
            prices = data.get("prices", [])
            if prices:
                df = pd.DataFrame(prices, columns=["timestamp", "price"])
                df["date"] = pd.to_datetime(df["timestamp"], unit="ms")
                df = df[["date", "price"]].set_index("date")
                print(f"  API OK: {len(df)} pts, ${df['price'].iloc[0]:.0f} -> ${df['price'].iloc[-1]:.0f}")
                return df
        except Exception as e:
            print(f"  API fail ({e}), using synthetic")

    return generate_historical_eth(days)


def generate_historical_eth(days: int = 1865) -> pd.DataFrame:
    """
    2019-01 ~ 2024-06 실제 ETH 가격 패턴을 재현하는 합성 데이터.
    주요 이벤트: COVID crash, DeFi summer, ATH, LUNA, FTX, 2024 recovery.
    """
    np.random.seed(42)

    # 실제 ETH 가격 체크포인트 (월별 대표가)
    checkpoints = [
        ("2019-01-01", 130),
        ("2019-06-01", 270),
        ("2020-01-01", 130),
        ("2020-03-12", 100),     # COVID crash
        ("2020-06-01", 230),
        ("2020-12-01", 600),
        ("2021-02-01", 1500),
        ("2021-05-12", 4200),    # ATH approach
        ("2021-06-22", 1800),    # Summer dip
        ("2021-11-10", 4800),    # ATH
        ("2022-01-01", 3700),
        ("2022-05-12", 1800),    # LUNA crash
        ("2022-06-18", 1000),    # Bottom
        ("2022-09-01", 1600),
        ("2022-11-09", 1200),    # FTX
        ("2022-12-31", 1200),
        ("2023-04-01", 1800),
        ("2023-10-01", 1600),
        ("2024-01-01", 2300),
        ("2024-03-13", 4000),    # ETF rally
        ("2024-06-01", 3800),
        ("2024-08-05", 2200),    # Aug 2024 crash
        ("2024-10-01", 2400),
        ("2024-12-31", 3400),
    ]

    # Build daily prices by interpolating between checkpoints with noise
    dates_all = []
    prices_all = []

    for i in range(len(checkpoints) - 1):
        d1 = pd.Timestamp(checkpoints[i][0])
        d2 = pd.Timestamp(checkpoints[i + 1][0])
        p1 = checkpoints[i][1]
        p2 = checkpoints[i + 1][1]

        n_days = (d2 - d1).days
        if n_days <= 0:
            continue

        # Log-linear interpolation with noise
        log_p1 = math.log(p1)
        log_p2 = math.log(p2)

        for j in range(n_days):
            t = j / n_days
            log_p = log_p1 + (log_p2 - log_p1) * t
            # Daily noise: ~2% std
            noise = np.random.normal(0, 0.02)
            price = math.exp(log_p + noise)
            date = d1 + pd.Timedelta(days=j)
            dates_all.append(date)
            prices_all.append(price)

    # Add final checkpoint
    dates_all.append(pd.Timestamp(checkpoints[-1][0]))
    prices_all.append(checkpoints[-1][1])

    df = pd.DataFrame({"price": prices_all}, index=pd.DatetimeIndex(dates_all))
    df = df[~df.index.duplicated(keep='first')]
    df = df.sort_index()

    # Trim to requested days
    if len(df) > days:
        df = df.iloc[-days:]

    print(f"  Synthetic: {len(df)} pts, ${df['price'].iloc[0]:.0f} -> ${df['price'].iloc[-1]:.0f}")
    print(f"  Period: {df.index[0].strftime('%Y-%m-%d')} -> {df.index[-1].strftime('%Y-%m-%d')}")
    return df


# ================================================================
# IL Math
# ================================================================
def il_v2(price_ratio):
    if price_ratio <= 0:
        return 0.0
    sr = math.sqrt(price_ratio)
    return abs(2 * sr / (1 + price_ratio) - 1)


def il_v3(price_ratio, tick_lower, tick_upper):
    if price_ratio <= 0:
        return 0.0
    pa = 1.0001 ** tick_lower
    pb = 1.0001 ** tick_upper
    if pa >= pb:
        return 0.0
    base = il_v2(price_ratio)
    conc = min(1 / (1 - math.sqrt(pa / pb)), 10.0)
    return base * conc


def get_premium_rate(utilization):
    if utilization <= KINK_UTILIZATION:
        return PREMIUM_RATE
    excess = (utilization - KINK_UTILIZATION) / (1 - KINK_UTILIZATION)
    return PREMIUM_RATE * (1 + (MAX_MULTIPLIER - 1) * excess)


# ================================================================
# LP Model
# ================================================================
@dataclass
class LP:
    id: int
    liquidity_usd: float
    entry_price: float
    entry_epoch: int
    tick_lower: int
    tick_upper: int
    active: bool = True
    total_premium_paid: float = 0.0
    total_fee_earned: float = 0.0
    il_on_exit: float = 0.0
    net_il_on_exit: float = 0.0
    payout_received: float = 0.0


# ================================================================
# Phase Config
# ================================================================
@dataclass
class PhaseConfig:
    name: str
    pool_size: float
    treasury_init: float      # Initial treasury (= pool_size * TREASURY_RATIO for dual pool)
    num_lps: int
    avg_lp: float
    lp_std: float
    churn: float
    cap_mult: int
    dual_pool: bool           # True = Treasury/Senior split
    premium_rate: float       # base premium rate
    data_days: int


# LP total liquidity should be < pool_size * cap_mult for healthy utilization
# Rule: num_lps * avg_lp ~ pool_size * 0.5 (50% utilization target)
PHASES = {
    "phase1": PhaseConfig(
        name="Phase 1-2 Single Pool ($100K)",
        pool_size=100_000, treasury_init=20_000,
        num_lps=5, avg_lp=20_000, lp_std=10_000,
        churn=0.05, cap_mult=5, dual_pool=False,
        premium_rate=0.12, data_days=1865,
    ),
    "phase3": PhaseConfig(
        name="Phase 3 Open Market ($10M)",
        pool_size=10_000_000, treasury_init=2_000_000,
        num_lps=30, avg_lp=80_000, lp_std=40_000,
        churn=0.04, cap_mult=6, dual_pool=True,
        premium_rate=0.12, data_days=1865,
    ),
    "phase4": PhaseConfig(
        name="Phase 4 DEX Payment ($20M)",
        pool_size=20_000_000, treasury_init=4_000_000,
        num_lps=50, avg_lp=120_000, lp_std=60_000,
        churn=0.03, cap_mult=6, dual_pool=True,
        premium_rate=0.06, data_days=1865,
    ),
    "phase5": PhaseConfig(
        name="Phase 5 Global ($170M)",
        pool_size=170_000_000, treasury_init=34_000_000,
        num_lps=100, avg_lp=200_000, lp_std=100_000,
        churn=0.02, cap_mult=6, dual_pool=True,
        premium_rate=0.06, data_days=1865,
    ),
}


# ================================================================
# Epoch Result
# ================================================================
@dataclass
class EpochResult:
    epoch: int
    date: datetime
    eth_price: float
    price_change_pct: float

    # Revenue
    total_fee_generated: float
    total_premium_collected: float
    premium_to_senior: float
    premium_to_treasury: float
    pool_aave_yield: float

    # IL
    lps_exiting: int
    lps_with_net_il: int
    gross_il: float
    fee_offset: float
    net_il: float
    covered_il: float
    actual_payout: float
    treasury_absorbed: float

    # Pool state (dual pool)
    senior_tvl: float
    treasury_tvl: float
    total_pool: float
    utilization: float

    # Senior metrics
    senior_epoch_return: float   # Senior의 이번 에포크 수익
    senior_cum_return_pct: float

    # Cumulative
    cum_premiums: float
    cum_aave: float
    cum_payouts: float
    cum_pnl: float

    # MDD tracking
    treasury_peak: float
    treasury_mdd: float
    pool_peak: float
    pool_mdd: float


# ================================================================
# Engine v4.2.0
# ================================================================
class PhaseBacktester:

    def __init__(self, config: PhaseConfig):
        self.cfg = config
        self.initial_pool = config.pool_size
        self.initial_treasury = config.treasury_init

        if config.dual_pool:
            # 이중 풀: Treasury 20%, Senior 80%
            self.treasury = config.treasury_init
            self.senior = config.pool_size - config.treasury_init
        else:
            # 단일 풀
            self.treasury = config.treasury_init
            self.senior = config.pool_size - config.treasury_init

        self.lps: list[LP] = []
        self.results: list[EpochResult] = []
        self.next_id = 0

        self.cum_premiums = 0.0
        self.cum_aave = 0.0
        self.cum_payouts = 0.0
        self.total_treasury_abs = 0.0

        # MDD tracking
        self.treasury_peak = self.treasury
        self.pool_peak = self.senior + self.treasury
        self.senior_cum_return = 0.0

    def _new_lp(self, price, epoch):
        size = max(10_000, np.random.normal(self.cfg.avg_lp, self.cfg.lp_std))
        w = random.choice([2000, 3000, 4000, 6000, 8000])
        h = w // 2
        tl = -(h // 60) * 60
        tu = (h // 60) * 60
        lp = LP(id=self.next_id, liquidity_usd=size, entry_price=price,
                entry_epoch=epoch, tick_lower=tl, tick_upper=tu)
        self.next_id += 1
        return lp

    def run(self, prices: pd.DataFrame):
        cfg = self.cfg
        print(f"\n  {'='*56}")
        print(f"  Phase Backtest v4.2.0 - {cfg.name}")
        print(f"  {'='*56}")
        print(f"  Pool:       ${self.initial_pool:,.0f}" +
              (f" (Treasury ${self.treasury:,.0f} / Senior ${self.senior:,.0f})" if cfg.dual_pool else ""))
        print(f"  Dual Pool:  {cfg.dual_pool}")
        print(f"  LPs:        {cfg.num_lps} (avg ${cfg.avg_lp:,.0f})")
        print(f"  Premium:    {cfg.premium_rate:.0%} of fee income")
        print(f"  CAP_MULT:   {cfg.cap_mult}x")
        print(f"  Coverage:   {COVERAGE_CAP:.0%} of NET IL")
        print()

        ep = prices.resample(f"{EPOCH_DAYS}D").last().dropna()
        p0 = ep["price"].iloc[0]

        np.random.seed(42)
        random.seed(42)
        for _ in range(cfg.num_lps):
            noise = np.random.uniform(0.95, 1.05)
            self.lps.append(self._new_lp(p0 * noise, 0))

        for i in range(1, len(ep)):
            epoch = i
            price = ep["price"].iloc[i]
            prev = ep["price"].iloc[i - 1]
            date = ep.index[i]
            pchg = (price - prev) / prev

            active = [lp for lp in self.lps if lp.active]
            total_liq = sum(lp.liquidity_usd for lp in active)
            total_pool = self.senior + self.treasury

            # === 1. LP Fee Income ===
            epoch_fee_total = 0
            for lp in active:
                fee = lp.liquidity_usd * LP_FEE_APY / 365 * EPOCH_DAYS
                lp.total_fee_earned += fee
                epoch_fee_total += fee

            # === 2. Premiums ===
            capacity = total_pool * cfg.cap_mult
            util = total_liq * COVERAGE_CAP / capacity if capacity > 0 else 0
            util = min(util, 1.0)

            # Premium rate uses phase-specific base rate
            if util <= KINK_UTILIZATION:
                prem_rate = cfg.premium_rate
            else:
                excess = (util - KINK_UTILIZATION) / (1 - KINK_UTILIZATION)
                prem_rate = cfg.premium_rate * (1 + (MAX_MULTIPLIER - 1) * excess)

            total_prem = 0
            for lp in active:
                lp_fee = lp.liquidity_usd * LP_FEE_APY / 365 * EPOCH_DAYS
                prem = lp_fee * prem_rate
                lp.total_premium_paid += prem
                total_prem += prem

            if cfg.dual_pool:
                prem_to_treasury = total_prem * TREASURY_RATIO
                prem_to_senior = total_prem - prem_to_treasury
            else:
                prem_to_treasury = total_prem * TREASURY_RATIO
                prem_to_senior = total_prem - prem_to_treasury

            # === 3. Aave yield on total pool ===
            aave_yield = total_pool * AAVE_BASE_YIELD / 365 * EPOCH_DAYS
            aave_to_senior = aave_yield * 0.8 if cfg.dual_pool else aave_yield
            aave_to_treasury = aave_yield * 0.2 if cfg.dual_pool else 0

            # === 4. LP Churn — exiting LPs realize IL ===
            n_exit = max(1, int(len(active) * cfg.churn))
            exiting = sorted(active, key=lambda x: x.entry_epoch)[:n_exit]

            gross_il = 0
            fee_offset = 0
            net_il = 0
            lps_with_net_il = 0

            for lp in exiting:
                ratio = price / lp.entry_price
                raw_il = il_v3(ratio, lp.tick_lower, lp.tick_upper) * lp.liquidity_usd
                lp.il_on_exit = raw_il

                lp_fees = lp.total_fee_earned
                lp_net_il = max(0, raw_il - lp_fees)
                lp.net_il_on_exit = lp_net_il

                gross_il += raw_il
                fee_offset += min(raw_il, lp_fees)

                if lp_net_il > 0:
                    net_il += lp_net_il
                    lps_with_net_il += 1

                lp.active = False

            # Coverage cap
            covered_il = net_il * COVERAGE_CAP

            # Daily pay limit
            daily_lim = total_pool * DAILY_PAY_LIMIT
            epoch_lim = daily_lim * EPOCH_DAYS
            actual_payout = min(covered_il, epoch_lim)

            # === 5. Payout — Treasury absorbs first-loss ===
            treasury_abs = 0
            pool_payout_from_senior = 0

            if cfg.dual_pool:
                # 이중 풀: Treasury가 first-loss 전액 흡수
                if actual_payout > 0:
                    treasury_can_absorb = min(actual_payout, self.treasury)
                    treasury_abs = treasury_can_absorb
                    self.treasury -= treasury_abs
                    self.total_treasury_abs += treasury_abs

                    # Treasury로 못 커버한 잔액 → Senior에서 지급
                    remaining = actual_payout - treasury_abs
                    if remaining > 0:
                        pool_payout_from_senior = min(remaining, self.senior)
                        self.senior -= pool_payout_from_senior
            else:
                # 단일 풀: 30% Treasury, 70% Pool
                if actual_payout > 0 and self.treasury > 0:
                    absorb = min(actual_payout * 0.30, self.treasury)
                    self.treasury -= absorb
                    treasury_abs = absorb
                    self.total_treasury_abs += absorb

                pool_payout = min(actual_payout - treasury_abs, self.senior)
                self.senior -= pool_payout
                pool_payout_from_senior = pool_payout

            # Distribute payouts to exiting LPs
            if net_il > 0:
                for lp in exiting:
                    if lp.net_il_on_exit > 0:
                        share = lp.net_il_on_exit / net_il
                        lp.payout_received = actual_payout * share

            # === 6. Add revenue to pools ===
            self.senior += prem_to_senior + aave_to_senior
            self.treasury += prem_to_treasury + aave_to_treasury

            # Self-healing: if treasury below 50% of target
            treasury_target = self.senior * TREASURY_RATIO if cfg.dual_pool else self.initial_treasury
            if self.treasury < treasury_target * 0.5:
                heal = prem_to_senior * SELF_HEAL_RATIO
                self.treasury += heal
                self.senior -= heal

            # === 7. Senior APY guarantee (Phase 3+) ===
            senior_epoch_return = prem_to_senior + aave_to_senior - pool_payout_from_senior
            if cfg.dual_pool:
                # Senior가 목표 APY에 미달하면 Treasury에서 보전
                target_senior_yield = self.senior * SENIOR_TARGET_APY / 365 * EPOCH_DAYS
                if senior_epoch_return < target_senior_yield and self.treasury > 0:
                    shortfall = target_senior_yield - senior_epoch_return
                    supplement = min(shortfall, self.treasury * 0.05)  # Treasury의 5% 한도
                    self.senior += supplement
                    self.treasury -= supplement
                    senior_epoch_return += supplement

            self.cum_premiums += total_prem
            self.cum_aave += aave_yield
            self.cum_payouts += actual_payout

            # New LPs
            for _ in range(n_exit):
                noise = np.random.uniform(0.98, 1.02)
                self.lps.append(self._new_lp(price * noise, epoch))

            # MDD tracking
            total_pool_now = self.senior + self.treasury
            self.treasury_peak = max(self.treasury_peak, self.treasury)
            self.pool_peak = max(self.pool_peak, total_pool_now)
            t_mdd = (self.treasury - self.treasury_peak) / self.treasury_peak * 100 if self.treasury_peak > 0 else 0
            p_mdd = (total_pool_now - self.pool_peak) / self.pool_peak * 100 if self.pool_peak > 0 else 0

            # Senior cumulative return
            initial_senior = self.initial_pool - self.initial_treasury
            self.senior_cum_return = (self.senior - initial_senior) / initial_senior * 100 if initial_senior > 0 else 0

            self.results.append(EpochResult(
                epoch=epoch, date=date, eth_price=price,
                price_change_pct=pchg * 100,
                total_fee_generated=epoch_fee_total,
                total_premium_collected=total_prem,
                premium_to_senior=prem_to_senior,
                premium_to_treasury=prem_to_treasury,
                pool_aave_yield=aave_yield,
                lps_exiting=n_exit,
                lps_with_net_il=lps_with_net_il,
                gross_il=gross_il,
                fee_offset=fee_offset,
                net_il=net_il,
                covered_il=covered_il,
                actual_payout=actual_payout,
                treasury_absorbed=treasury_abs,
                senior_tvl=self.senior,
                treasury_tvl=self.treasury,
                total_pool=total_pool_now,
                utilization=util * 100,
                senior_epoch_return=senior_epoch_return,
                senior_cum_return_pct=self.senior_cum_return,
                cum_premiums=self.cum_premiums,
                cum_aave=self.cum_aave,
                cum_payouts=self.cum_payouts,
                cum_pnl=(self.cum_premiums + self.cum_aave) - self.cum_payouts,
                treasury_peak=self.treasury_peak,
                treasury_mdd=t_mdd,
                pool_peak=self.pool_peak,
                pool_mdd=p_mdd,
            ))

        print(f"  Done: {len(self.results)} epochs\n")
        return self.results

    def summary(self):
        if not self.results:
            return
        r = self.results
        last = r[-1]
        days = len(r) * EPOCH_DAYS
        years = days / 365

        initial_senior = self.initial_pool - self.initial_treasury

        # Treasury metrics
        treasury_return = (last.treasury_tvl - self.initial_treasury) / self.initial_treasury * 100
        treasury_cagr = ((last.treasury_tvl / self.initial_treasury) ** (1 / years) - 1) * 100 if years > 0 else 0
        min_treasury_mdd = min(x.treasury_mdd for x in r)

        # Senior metrics
        senior_return = (last.senior_tvl - initial_senior) / initial_senior * 100
        senior_apy = senior_return / years if years > 0 else 0

        # Pool metrics
        min_pool_mdd = min(x.pool_mdd for x in r)

        # Sharpe
        pnls = [x.total_premium_collected + x.pool_aave_yield - x.actual_payout for x in r]
        sharpe = np.mean(pnls) / np.std(pnls) * np.sqrt(52 / EPOCH_DAYS) if np.std(pnls) > 0 else 0
        prof_epochs = sum(1 for p in pnls if p >= 0)

        # Event-based MDD
        events = self._find_event_mdds()

        print(f"  {'='*60}")
        print(f"  PHASE BACKTEST v4.2.0 - {self.cfg.name}")
        print(f"  {'='*60}")
        print(f"  Period:   {r[0].date.strftime('%Y-%m-%d')} -> {last.date.strftime('%Y-%m-%d')} ({years:.1f}y)")
        print(f"  ETH:      ${r[0].eth_price:,.0f} -> ${last.eth_price:,.0f} ({((last.eth_price/r[0].eth_price)-1)*100:+.1f}%)")
        print(f"  Epochs:   {len(r)}")

        print(f"\n  --- Revenue ---")
        print(f"  Premiums:       ${last.cum_premiums:,.0f}")
        print(f"  Aave Yield:     ${last.cum_aave:,.0f}")
        print(f"  Total Revenue:  ${last.cum_premiums + last.cum_aave:,.0f}")
        print(f"  IL Payouts:     ${last.cum_payouts:,.0f}")
        print(f"  Net P&L:        ${last.cum_pnl:,.0f}")

        print(f"\n  --- Treasury ---")
        print(f"  Initial:    ${self.initial_treasury:,.0f}")
        print(f"  Final:      ${last.treasury_tvl:,.0f} ({treasury_return:+.1f}%)")
        print(f"  CAGR:       {treasury_cagr:+.1f}%")
        print(f"  Absorbed:   ${self.total_treasury_abs:,.0f}")
        print(f"  Max MDD:    {min_treasury_mdd:.1f}%")

        print(f"\n  --- Senior Pool ---")
        print(f"  Initial:    ${initial_senior:,.0f}")
        print(f"  Final:      ${last.senior_tvl:,.0f} ({senior_return:+.1f}%)")
        print(f"  APY:        {senior_apy:+.1f}%")

        print(f"\n  --- Pool Overall ---")
        print(f"  Pool MDD:       {min_pool_mdd:.1f}%")
        print(f"  Sharpe:         {sharpe:+.2f}")
        print(f"  Prof Epochs:    {prof_epochs}/{len(r)} ({prof_epochs/len(r)*100:.0f}%)")

        if events:
            print(f"\n  --- Event MDD (Treasury) ---")
            for name, mdd in events.items():
                print(f"  {name:<15} {mdd:+.1f}%")

        print(f"\n  Solvency: {'MAINTAINED' if last.total_pool > 0 else 'FAILED'}")
        print(f"  {'='*60}")

        return {
            "treasury_cagr": treasury_cagr,
            "senior_apy": senior_apy,
            "sharpe": sharpe,
            "pool_mdd": min_pool_mdd,
            "treasury_mdd": min_treasury_mdd,
        }

    def _find_event_mdds(self):
        """주요 이벤트 기간 Treasury MDD 계산"""
        events = {}
        event_periods = [
            ("COVID", "2020-02-01", "2020-04-30"),
            ("LUNA", "2022-04-01", "2022-07-31"),
            ("FTX", "2022-10-01", "2022-12-31"),
            ("Aug2024", "2024-07-01", "2024-09-30"),
        ]

        for name, start, end in event_periods:
            start_dt = pd.Timestamp(start)
            end_dt = pd.Timestamp(end)

            period_results = [x for x in self.results if start_dt <= x.date <= end_dt]
            if not period_results:
                continue

            # Find treasury value at start of period
            pre_period = [x for x in self.results if x.date < start_dt]
            if pre_period:
                peak = pre_period[-1].treasury_tvl
            else:
                peak = self.initial_treasury

            min_val = min(x.treasury_tvl for x in period_results)
            mdd = (min_val - peak) / peak * 100 if peak > 0 else 0
            events[name] = mdd

        return events


# ================================================================
# Charts
# ================================================================
def charts(results, output_dir, title=""):
    if not results:
        return
    os.makedirs(output_dir, exist_ok=True)
    dates = [r.date for r in results]
    BG = "#0a0e1a"; TXT = "#e0e0e0"; G = "#00ff88"; B = "#00d4ff"; R = "#ff4466"; Y = "#ffcc00"; GR = "#1a2040"
    plt.rcParams.update({"figure.facecolor": BG, "axes.facecolor": BG, "axes.edgecolor": GR,
        "text.color": TXT, "axes.labelcolor": TXT, "xtick.color": TXT, "ytick.color": TXT,
        "grid.color": GR, "font.size": 10})

    # 1. ETH + Revenue vs Payout
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(14, 8), sharex=True)
    fig.suptitle(f"{title}ETH Price & Revenue vs Payouts", fontsize=14, color=G)
    a1.plot(dates, [r.eth_price for r in results], color=B, linewidth=1.5)
    a1.fill_between(dates, [r.eth_price for r in results], alpha=0.1, color=B)
    a1.set_ylabel("ETH (USD)"); a1.grid(True, alpha=0.3)
    a2.bar(dates, [r.total_premium_collected + r.pool_aave_yield for r in results],
           width=EPOCH_DAYS, color=G, alpha=0.6, label="Revenue")
    a2.bar(dates, [-r.actual_payout for r in results], width=EPOCH_DAYS,
           color=R, alpha=0.6, label="IL Payout")
    a2.axhline(y=0, color=TXT, linewidth=0.5)
    a2.legend(); a2.set_ylabel("USD/Epoch"); a2.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(f"{output_dir}/01_revenue_payout.png", dpi=150, bbox_inches="tight"); plt.close()

    # 2. Cumulative P&L
    fig, ax = plt.subplots(figsize=(14, 6))
    fig.suptitle(f"{title}Cumulative P&L", fontsize=14, color=G)
    ax.plot(dates, [r.cum_premiums + r.cum_aave for r in results], color=G, linewidth=1.5, label="Revenue")
    ax.plot(dates, [r.cum_payouts for r in results], color=R, linewidth=1.5, label="Payouts")
    ax.plot(dates, [r.cum_pnl for r in results], color=B, linewidth=2, label="Net P&L")
    ax.fill_between(dates, [r.cum_pnl for r in results], alpha=0.15, color=B)
    ax.axhline(y=0, color=TXT, linewidth=0.5)
    ax.legend(); ax.set_ylabel("USD"); ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(f"{output_dir}/02_cumulative_pnl.png", dpi=150, bbox_inches="tight"); plt.close()

    # 3. Treasury + Senior TVL
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(14, 8), sharex=True)
    fig.suptitle(f"{title}Pool Health: Treasury vs Senior", fontsize=14, color=G)
    a1.plot(dates, [r.treasury_tvl for r in results], color=Y, linewidth=1.5, label="Treasury")
    a1.plot(dates, [r.senior_tvl for r in results], color=B, linewidth=1.5, label="Senior")
    a1.plot(dates, [r.total_pool for r in results], color=G, linewidth=1, alpha=0.5, label="Total")
    a1.legend(); a1.set_ylabel("USD"); a1.grid(True, alpha=0.3)
    a2.plot(dates, [r.treasury_mdd for r in results], color=R, linewidth=1.5, label="Treasury MDD %")
    a2.plot(dates, [r.pool_mdd for r in results], color=Y, linewidth=1, label="Pool MDD %")
    a2.axhline(y=0, color=TXT, linewidth=0.5)
    a2.legend(); a2.set_ylabel("MDD %"); a2.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(f"{output_dir}/03_pool_health.png", dpi=150, bbox_inches="tight"); plt.close()

    # 4. Senior Cumulative Return
    fig, ax = plt.subplots(figsize=(14, 6))
    fig.suptitle(f"{title}Senior Pool Return", fontsize=14, color=G)
    ax.plot(dates, [r.senior_cum_return_pct for r in results], color=G, linewidth=2, label="Senior Return %")
    # Reference: 7% APY line
    target_returns = [(i * EPOCH_DAYS / 365) * 7 for i in range(len(results))]
    ax.plot(dates, target_returns, color=Y, linewidth=1, linestyle="--", label="Target 7% APY")
    ax.legend(); ax.set_ylabel("Cumulative Return %"); ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(f"{output_dir}/04_senior_return.png", dpi=150, bbox_inches="tight"); plt.close()

    print(f"  Charts -> {output_dir}/")


# ================================================================
# Run
# ================================================================
def run_phase(key):
    cfg = PHASES[key]
    prices = fetch_eth_prices(cfg.data_days)
    bt = PhaseBacktester(cfg)
    results = bt.run(prices)
    metrics = bt.summary()
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results", f"v420_{key}")
    charts(results, out, f"[{cfg.name}] ")
    return bt, results, metrics


def run_all():
    print(f"\n{'='*65}")
    print(f"  BELTA PHASE BACKTEST v4.2.0 (CLAUDE.md Spec)")
    print(f"{'='*65}")

    all_r = {}
    for k in PHASES:
        bt, res, metrics = run_phase(k)
        all_r[k] = (bt, res, metrics)

    print(f"\n{'='*80}")
    print(f"  v4.2.0 PHASE COMPARISON")
    print(f"{'='*80}")
    print(f"  {'Phase':<30} {'Treasury CAGR':>14} {'Senior APY':>11} {'Sharpe':>8} {'Pool MDD':>10} {'Tres MDD':>10}")
    print(f"  {'-'*83}")

    for k, (bt, res, m) in all_r.items():
        if m:
            print(f"  {PHASES[k].name:<30} {m['treasury_cagr']:>+13.1f}% {m['senior_apy']:>+10.1f}% {m['sharpe']:>+7.2f} {m['pool_mdd']:>+9.1f}% {m['treasury_mdd']:>+9.1f}%")

    print(f"  {'='*83}")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        arg = sys.argv[1]
        if arg == "all":
            run_all()
        elif arg in PHASES:
            run_phase(arg)
        else:
            print(f"Unknown: {arg}. Available: {', '.join(PHASES.keys())}, all")
    else:
        run_all()
