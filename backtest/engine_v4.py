"""
BELTA Labs -- Backtesting Engine V4 (3-Layer Hedging Model)
=============================================================
V3 + 3 Revenue/Hedging Layers:
  Layer 1: Dynamic Fee -- volatility-scaled swap fees (+3~8% APY)
  Layer 2: Aave Yield  -- idle pool+treasury funds earn Aave yield
  Layer 3: Perps Hedge -- short ETH perps offset 50-70% of IL payouts

Usage:
  python backtest/engine_v4.py
  python backtest/engine_v4.py [scenario]
  python backtest/engine_v4.py compare   # V3 vs V4 side-by-side
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
# Protocol Parameters (from CLAUDE.md)
# ================================================================
COVERAGE_CAP = 0.45
PREMIUM_RATE = 0.12
LP_FEE_APY = 0.224
EPOCH_DAYS = 7
KINK_UTILIZATION = 0.80
MAX_MULTIPLIER = 3.0
CAP_MULT = 5
DAILY_PAY_LIMIT = 0.05
TREASURY_RATIO = 0.20
SELF_HEAL_RATIO = 0.20
AAVE_BASE_YIELD = 0.05

# === Layer 1: Dynamic Fee Parameters ===
# Volatility-based fee scaling: fee_apy = base_fee_apy * vol_multiplier
# Low vol (<30%):  0.7x base -> ~15.7% APY
# Med vol (30-60%): 1.0x base -> 22.4% APY (unchanged)
# High vol (>60%): 1.5-2.5x base -> 33.6-56% APY
DYNAMIC_FEE_ENABLED = True
VOL_LOW_THRESHOLD = 0.30    # 30% annualized vol
VOL_HIGH_THRESHOLD = 0.60   # 60% annualized vol
FEE_LOW_MULT = 0.7          # Low vol: fees drop (less volume too)
FEE_HIGH_MULT = 2.0         # High vol: fees spike (LVR recapture)
FEE_MAX_MULT = 2.5          # Cap

# === Layer 2: Aave Yield Parameters ===
AAVE_ENABLED = True
AAVE_POOL_IDLE_RATIO = 0.70   # 70% of pool idle -> Aave
AAVE_TREASURY_RATIO = 0.70    # 70% of treasury -> Aave
AAVE_YIELD_RATE = 0.05        # 5% APR on deposited funds

# === Layer 3: Perps Hedge Parameters ===
PERPS_HEDGE_ENABLED = True
HEDGE_RATIO = 0.50             # Hedge 50% of hedged LP value
HEDGE_EFFECTIVENESS = 0.60     # 60% of IL offset (imperfect hedge)
PERPS_FUNDING_COST = 0.03      # 3% annualized funding cost
PERPS_REBALANCE_COST = 0.005   # 0.5% annualized rebalance cost


# ================================================================
# Data
# ================================================================
def fetch_eth_prices(days: int = 365) -> pd.DataFrame:
    print(f"  Fetching ETH prices ({days}d)...")
    url = "https://api.coingecko.com/api/v3/coins/ethereum/market_chart"
    params = {"vs_currency": "usd", "days": days, "interval": "daily"}
    try:
        resp = requests.get(url, params=params, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        prices = data.get("prices", [])
        if not prices:
            raise ValueError("empty")
        df = pd.DataFrame(prices, columns=["timestamp", "price"])
        df["date"] = pd.to_datetime(df["timestamp"], unit="ms")
        df = df[["date", "price"]].set_index("date")
        print(f"  OK: {len(df)} pts, ${df['price'].iloc[0]:.0f} -> ${df['price'].iloc[-1]:.0f}")
        return df
    except Exception as e:
        print(f"  API fail ({e}), using synthetic")
        return _gen(days)


def _gen(days):
    np.random.seed(42)
    dates = pd.date_range(end=datetime.now(), periods=days, freq="D")
    log_ret = np.random.normal(0, 0.80 * np.sqrt(1/365), days)
    prices = 2000 * np.exp(np.cumsum(log_ret))
    return pd.DataFrame({"price": prices}, index=dates)


# ================================================================
# Volatility Estimation
# ================================================================
def compute_realized_vol(prices: pd.Series, window: int = 30) -> pd.Series:
    """Annualized realized volatility from daily returns."""
    log_ret = np.log(prices / prices.shift(1))
    vol = log_ret.rolling(window=window).std() * np.sqrt(365)
    return vol.fillna(0.40)  # Default 40% if insufficient data


# ================================================================
# IL Math
# ================================================================
def il_v2(price_ratio):
    if price_ratio <= 0: return 0.0
    sr = math.sqrt(price_ratio)
    return abs(2 * sr / (1 + price_ratio) - 1)


def il_v3(price_ratio, tick_lower, tick_upper):
    if price_ratio <= 0: return 0.0
    pa = 1.0001 ** tick_lower
    pb = 1.0001 ** tick_upper
    if pa >= pb: return 0.0
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


@dataclass
class EpochSnap:
    epoch: int
    date: datetime
    eth_price: float
    price_change_pct: float
    realized_vol: float
    num_active_lps: int
    total_lp_liquidity: float

    # Revenue
    total_fee_generated: float
    dynamic_fee_mult: float        # Layer 1 multiplier
    total_premium_collected: float
    premium_to_pool: float
    premium_to_treasury: float
    pool_aave_yield: float         # Layer 2: pool Aave yield
    treasury_aave_yield: float     # Layer 2: treasury Aave yield

    # IL Payouts
    lps_exiting: int
    lps_with_net_il: int
    gross_il: float
    fee_offset: float
    net_il: float
    covered_il: float
    hedge_offset: float            # Layer 3: perps hedge offset
    actual_payout: float
    treasury_absorbed: float

    # Hedge costs
    hedge_funding_cost: float      # Layer 3: perps funding
    hedge_rebalance_cost: float    # Layer 3: rebalance cost

    # Pool state
    pool_tvl: float
    treasury_buffer: float
    utilization: float
    premium_rate: float

    # Cumulative
    cum_premiums: float
    cum_aave_yield: float
    cum_dynamic_fee_bonus: float   # Layer 1: extra fee revenue vs baseline
    cum_hedge_savings: float       # Layer 3: IL offset from hedging
    cum_hedge_costs: float         # Layer 3: funding + rebalance costs
    cum_total_revenue: float
    cum_payouts: float
    cum_pnl: float


# ================================================================
# Engine V4
# ================================================================
class BELTABacktesterV4:

    def __init__(self, pool_tvl=1_000_000, treasury=200_000,
                 num_lps=50, avg_lp_size=100_000, lp_size_std=50_000,
                 lp_churn=0.05, lp_fee_apy=LP_FEE_APY,
                 enable_dynamic_fee=True, enable_aave=True, enable_hedge=True):
        self.initial_pool = pool_tvl
        self.initial_treasury = treasury
        self.pool_tvl = pool_tvl
        self.treasury = treasury
        self.num_lps = num_lps
        self.avg_lp = avg_lp_size
        self.lp_std = lp_size_std
        self.churn = lp_churn
        self.lp_fee_apy = lp_fee_apy

        # Layer toggles
        self.dynamic_fee = enable_dynamic_fee
        self.aave = enable_aave
        self.hedge = enable_hedge

        self.lps: list[LP] = []
        self.results: list[EpochSnap] = []
        self.next_id = 0

        self.cum_premiums = 0.0
        self.cum_aave = 0.0
        self.cum_payouts = 0.0
        self.cum_dfee_bonus = 0.0
        self.cum_hedge_savings = 0.0
        self.cum_hedge_costs = 0.0
        self.total_treasury_abs = 0.0

    def _new_lp(self, price, epoch):
        size = max(10_000, np.random.normal(self.avg_lp, self.lp_std))
        w = random.choice([2000, 3000, 4000, 6000, 8000])
        h = w // 2
        tl = -(h // 60) * 60
        tu = (h // 60) * 60
        lp = LP(id=self.next_id, liquidity_usd=size, entry_price=price,
                entry_epoch=epoch, tick_lower=tl, tick_upper=tu)
        self.next_id += 1
        return lp

    def _get_dynamic_fee_mult(self, vol):
        """Layer 1: Fee multiplier based on realized volatility."""
        if not self.dynamic_fee:
            return 1.0
        if vol <= VOL_LOW_THRESHOLD:
            return FEE_LOW_MULT + (1.0 - FEE_LOW_MULT) * (vol / VOL_LOW_THRESHOLD)
        elif vol <= VOL_HIGH_THRESHOLD:
            t = (vol - VOL_LOW_THRESHOLD) / (VOL_HIGH_THRESHOLD - VOL_LOW_THRESHOLD)
            return 1.0 + (FEE_HIGH_MULT - 1.0) * t
        else:
            t = min((vol - VOL_HIGH_THRESHOLD) / 0.40, 1.0)
            return FEE_HIGH_MULT + (FEE_MAX_MULT - FEE_HIGH_MULT) * t

    def run(self, prices: pd.DataFrame):
        layers = []
        if self.dynamic_fee: layers.append("DynamicFee")
        if self.aave: layers.append("AaveYield")
        if self.hedge: layers.append("PerpsHedge")

        print(f"\n  {'='*56}")
        print(f"  BELTA V4 -- 3-Layer Hedging Model")
        print(f"  Layers: {', '.join(layers) if layers else 'NONE (baseline)'}")
        print(f"  {'='*56}")
        print(f"  Pool:       ${self.initial_pool:,.0f}")
        print(f"  Treasury:   ${self.initial_treasury:,.0f}")
        print(f"  LPs:        {self.num_lps} (avg ${self.avg_lp:,.0f})")
        print()

        # Compute vol from daily prices
        daily_vol = compute_realized_vol(prices["price"])

        ep = prices.resample(f"{EPOCH_DAYS}D").last().dropna()
        vol_ep = daily_vol.resample(f"{EPOCH_DAYS}D").last().fillna(0.40)
        p0 = ep["price"].iloc[0]

        np.random.seed(42)
        random.seed(42)
        for _ in range(self.num_lps):
            noise = np.random.uniform(0.95, 1.05)
            self.lps.append(self._new_lp(p0 * noise, 0))

        for i in range(1, len(ep)):
            epoch = i
            price = ep["price"].iloc[i]
            prev = ep["price"].iloc[i-1]
            date = ep.index[i]
            pchg = (price - prev) / prev

            # Realized vol for this epoch
            vol = vol_ep.iloc[i] if i < len(vol_ep) else 0.40

            active = [lp for lp in self.lps if lp.active]
            total_liq = sum(lp.liquidity_usd for lp in active)

            # === Layer 1: Dynamic Fee Multiplier ===
            fee_mult = self._get_dynamic_fee_mult(vol)
            effective_fee_apy = self.lp_fee_apy * fee_mult

            # === 1. LP Fee Income (with dynamic fee) ===
            epoch_fee_total = 0
            baseline_fee_total = 0
            for lp in active:
                fee = lp.liquidity_usd * effective_fee_apy / 365 * EPOCH_DAYS
                baseline = lp.liquidity_usd * self.lp_fee_apy / 365 * EPOCH_DAYS
                lp.total_fee_earned += fee
                epoch_fee_total += fee
                baseline_fee_total += baseline

            dfee_bonus = epoch_fee_total - baseline_fee_total

            # === 2. Premiums ===
            capacity = self.pool_tvl * CAP_MULT
            util = total_liq * COVERAGE_CAP / capacity if capacity > 0 else 0
            util = min(util, 1.0)
            prem_rate = get_premium_rate(util)

            total_prem = 0
            for lp in active:
                lp_fee = lp.liquidity_usd * effective_fee_apy / 365 * EPOCH_DAYS
                prem = lp_fee * prem_rate
                lp.total_premium_paid += prem
                total_prem += prem

            prem_to_treasury = total_prem * TREASURY_RATIO
            prem_to_pool = total_prem - prem_to_treasury

            # === Layer 2: Aave Yield ===
            pool_aave = 0
            treasury_aave = 0
            if self.aave:
                pool_idle = self.pool_tvl * AAVE_POOL_IDLE_RATIO
                pool_aave = pool_idle * AAVE_YIELD_RATE / 365 * EPOCH_DAYS
                treasury_idle = self.treasury * AAVE_TREASURY_RATIO
                treasury_aave = treasury_idle * AAVE_YIELD_RATE / 365 * EPOCH_DAYS
            else:
                pool_aave = self.pool_tvl * AAVE_BASE_YIELD / 365 * EPOCH_DAYS

            # === 4. LP Churn ===
            n_exit = max(1, int(len(active) * self.churn))
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

            covered_il = net_il * COVERAGE_CAP

            # === Layer 3: Perps Hedge Offset ===
            hedge_offset = 0
            hedge_funding = 0
            hedge_rebalance = 0
            if self.hedge and covered_il > 0:
                # Hedge offsets portion of IL payout
                hedge_offset = covered_il * HEDGE_EFFECTIVENESS
                # Costs
                hedge_notional = total_liq * HEDGE_RATIO
                hedge_funding = hedge_notional * PERPS_FUNDING_COST / 365 * EPOCH_DAYS
                hedge_rebalance = hedge_notional * PERPS_REBALANCE_COST / 365 * EPOCH_DAYS

            # Net payout after hedge offset
            payout_after_hedge = max(0, covered_il - hedge_offset)

            daily_lim = self.pool_tvl * DAILY_PAY_LIMIT
            epoch_lim = daily_lim * EPOCH_DAYS
            actual_payout = min(payout_after_hedge, epoch_lim)

            # Treasury first-loss
            treasury_abs = 0
            if actual_payout > 0 and self.treasury > 0:
                absorb = min(actual_payout * 0.30, self.treasury)
                self.treasury -= absorb
                treasury_abs = absorb
                self.total_treasury_abs += absorb

            pool_payout = min(actual_payout - treasury_abs, self.pool_tvl)

            # Distribute payouts
            if net_il > 0:
                for lp in exiting:
                    if lp.net_il_on_exit > 0:
                        share = lp.net_il_on_exit / net_il
                        lp.payout_received = actual_payout * share

            # === 5. Update pool ===
            self.pool_tvl -= pool_payout
            self.pool_tvl += prem_to_pool + pool_aave
            self.pool_tvl -= (hedge_funding + hedge_rebalance)  # Hedge costs from pool
            self.treasury += prem_to_treasury + treasury_aave

            # Self-healing
            if self.treasury < self.initial_treasury * 0.5:
                heal = prem_to_pool * SELF_HEAL_RATIO
                self.treasury += heal
                self.pool_tvl -= heal

            self.cum_premiums += total_prem
            self.cum_aave += pool_aave + treasury_aave
            self.cum_payouts += actual_payout
            self.cum_dfee_bonus += dfee_bonus
            self.cum_hedge_savings += hedge_offset
            self.cum_hedge_costs += hedge_funding + hedge_rebalance

            # New LPs
            for _ in range(n_exit):
                noise = np.random.uniform(0.98, 1.02)
                self.lps.append(self._new_lp(price * noise, epoch))

            total_rev = self.cum_premiums + self.cum_aave + self.cum_dfee_bonus

            self.results.append(EpochSnap(
                epoch=epoch, date=date, eth_price=price,
                price_change_pct=pchg*100, realized_vol=vol,
                num_active_lps=len([l for l in self.lps if l.active]),
                total_lp_liquidity=total_liq,
                total_fee_generated=epoch_fee_total,
                dynamic_fee_mult=fee_mult,
                total_premium_collected=total_prem,
                premium_to_pool=prem_to_pool,
                premium_to_treasury=prem_to_treasury,
                pool_aave_yield=pool_aave,
                treasury_aave_yield=treasury_aave,
                lps_exiting=n_exit, lps_with_net_il=lps_with_net_il,
                gross_il=gross_il, fee_offset=fee_offset,
                net_il=net_il, covered_il=covered_il,
                hedge_offset=hedge_offset,
                actual_payout=actual_payout,
                treasury_absorbed=treasury_abs,
                hedge_funding_cost=hedge_funding,
                hedge_rebalance_cost=hedge_rebalance,
                pool_tvl=self.pool_tvl,
                treasury_buffer=self.treasury,
                utilization=util*100, premium_rate=prem_rate*100,
                cum_premiums=self.cum_premiums,
                cum_aave_yield=self.cum_aave,
                cum_dynamic_fee_bonus=self.cum_dfee_bonus,
                cum_hedge_savings=self.cum_hedge_savings,
                cum_hedge_costs=self.cum_hedge_costs,
                cum_total_revenue=total_rev,
                cum_payouts=self.cum_payouts,
                cum_pnl=total_rev - self.cum_payouts - self.cum_hedge_costs,
            ))

        print(f"  Done: {len(self.results)} epochs\n")
        return self.results

    def summary(self):
        if not self.results: return
        r = self.results
        last = r[-1]
        days = len(r) * EPOCH_DAYS

        total_rev = last.cum_total_revenue
        net_pnl = last.cum_pnl
        uw_return = net_pnl / self.initial_pool * 100
        uw_apy = uw_return / (days/365)

        pnls = [x.total_premium_collected + x.pool_aave_yield + x.treasury_aave_yield
                - x.actual_payout - x.hedge_funding_cost - x.hedge_rebalance_cost
                for x in r]
        sharpe = np.mean(pnls) / np.std(pnls) * np.sqrt(52/EPOCH_DAYS) if np.std(pnls) > 0 else 0
        prof_epochs = sum(1 for p in pnls if p >= 0)

        all_exited = [lp for lp in self.lps if not lp.active]
        avg_lp_prem = np.mean([lp.total_premium_paid for lp in all_exited]) if all_exited else 0
        avg_lp_fee = np.mean([lp.total_fee_earned for lp in all_exited]) if all_exited else 0
        avg_lp_il = np.mean([lp.il_on_exit for lp in all_exited]) if all_exited else 0
        avg_lp_payout = np.mean([lp.payout_received for lp in all_exited]) if all_exited else 0

        print(f"  {'='*60}")
        print(f"  BELTA V4 RESULTS (3-Layer Hedging)")
        print(f"  {'='*60}")
        print(f"  Period: {r[0].date.strftime('%Y-%m-%d')} -> {last.date.strftime('%Y-%m-%d')}")
        print(f"  ETH:    ${r[0].eth_price:,.0f} -> ${last.eth_price:,.0f} ({((last.eth_price/r[0].eth_price)-1)*100:+.1f}%)")
        print(f"  Epochs: {len(r)} ({days}d)")

        print(f"\n  --- Revenue Sources ---")
        print(f"  LP Premiums:          ${last.cum_premiums:,.0f}")
        print(f"  Aave Yield (total):   ${last.cum_aave_yield:,.0f}")
        print(f"  Dynamic Fee Bonus:    ${last.cum_dynamic_fee_bonus:,.0f}  [Layer 1]")
        print(f"  Total Revenue:        ${total_rev:,.0f}")

        print(f"\n  --- IL Payouts ---")
        print(f"  Total Payouts:        ${last.cum_payouts:,.0f}")
        print(f"  Hedge IL Offset:      ${last.cum_hedge_savings:,.0f}  [Layer 3]")
        print(f"  Hedge Costs:          ${last.cum_hedge_costs:,.0f}  [Layer 3]")
        print(f"  Treasury Absorbed:    ${self.total_treasury_abs:,.0f}")
        print(f"  Avg Fee Offset:       {np.mean([x.fee_offset/(x.gross_il+0.01)*100 for x in r]):.0f}% of IL")

        print(f"\n  --- Net P&L ---")
        print(f"  Net P&L:              ${net_pnl:,.0f}")
        print(f"  Profitable Epochs:    {prof_epochs}/{len(r)} ({prof_epochs/len(r)*100:.0f}%)")

        print(f"\n  --- Pool Health ---")
        print(f"  Pool TVL:   ${self.initial_pool:,.0f} -> ${last.pool_tvl:,.0f} ({((last.pool_tvl/self.initial_pool)-1)*100:+.1f}%)")
        print(f"  Treasury:   ${self.initial_treasury:,.0f} -> ${last.treasury_buffer:,.0f}")

        print(f"\n  --- Underwriter Returns ---")
        print(f"  Return:     {uw_return:+.2f}%")
        print(f"  APY:        {uw_apy:+.2f}%")
        print(f"  Sharpe:     {sharpe:+.2f}")

        print(f"\n  --- Layer Contribution ---")
        baseline_rev = last.cum_premiums + last.cum_aave_yield
        print(f"  Without layers:  ${baseline_rev - last.cum_payouts:,.0f}")
        print(f"  + Dynamic Fee:   +${last.cum_dynamic_fee_bonus:,.0f}")
        print(f"  + Hedge Savings: +${last.cum_hedge_savings:,.0f}")
        print(f"  - Hedge Costs:   -${last.cum_hedge_costs:,.0f}")
        print(f"  = Final P&L:     ${net_pnl:,.0f}")

        print(f"\n  Solvency: {'MAINTAINED' if last.pool_tvl > 0 else 'FAILED'}")
        print(f"  {'='*60}")


# ================================================================
# Charts
# ================================================================
def charts(results, output_dir, prefix=""):
    if not results: return
    os.makedirs(output_dir, exist_ok=True)
    dates = [r.date for r in results]
    BG="#0a0e1a"; TXT="#e0e0e0"; G="#00ff88"; B="#00d4ff"; R="#ff4466"; Y="#ffcc00"; P="#bb66ff"; GR="#1a2040"
    plt.rcParams.update({"figure.facecolor":BG,"axes.facecolor":BG,"axes.edgecolor":GR,
        "text.color":TXT,"axes.labelcolor":TXT,"xtick.color":TXT,"ytick.color":TXT,
        "grid.color":GR,"font.size":10})

    # 1. Revenue vs Payouts + Hedge
    fig,(a1,a2)=plt.subplots(2,1,figsize=(14,8),sharex=True)
    fig.suptitle(f"{prefix}Revenue vs IL Payouts (3-Layer)",fontsize=14,color=G)
    a1.plot(dates,[r.eth_price for r in results],color=B,linewidth=1.5)
    a12 = a1.twinx()
    a12.plot(dates,[r.realized_vol*100 for r in results],color=Y,linewidth=1,alpha=0.5,label="Vol%")
    a12.set_ylabel("Realized Vol %",color=Y)
    a1.set_ylabel("ETH (USD)"); a1.grid(True,alpha=0.3)

    rev = [r.total_premium_collected+r.pool_aave_yield+r.treasury_aave_yield for r in results]
    a2.bar(dates,rev,width=EPOCH_DAYS,color=G,alpha=0.6,label="Revenue")
    a2.bar(dates,[-r.actual_payout for r in results],width=EPOCH_DAYS,color=R,alpha=0.6,label="Payout")
    a2.bar(dates,[r.hedge_offset for r in results],width=EPOCH_DAYS,color=P,alpha=0.4,label="Hedge Offset")
    a2.axhline(y=0,color=TXT,linewidth=0.5)
    a2.legend(loc="upper left"); a2.set_ylabel("USD/Epoch"); a2.grid(True,alpha=0.3)
    plt.tight_layout()
    plt.savefig(f"{output_dir}/01_revenue_vs_payout.png",dpi=150,bbox_inches="tight"); plt.close()

    # 2. Cumulative P&L with layer breakdown
    fig,ax=plt.subplots(figsize=(14,6))
    fig.suptitle(f"{prefix}Cumulative P&L (Layer Breakdown)",fontsize=14,color=G)
    ax.plot(dates,[r.cum_total_revenue for r in results],color=G,linewidth=1.5,label="Total Revenue")
    ax.plot(dates,[r.cum_payouts for r in results],color=R,linewidth=1.5,label="Total Payouts")
    ax.plot(dates,[r.cum_pnl for r in results],color=B,linewidth=2,label="Net P&L")
    ax.fill_between(dates,[r.cum_pnl for r in results],alpha=0.15,color=B)
    ax.plot(dates,[r.cum_dynamic_fee_bonus for r in results],color=Y,linewidth=1,linestyle="--",label="DynFee Bonus")
    ax.plot(dates,[r.cum_hedge_savings for r in results],color=P,linewidth=1,linestyle="--",label="Hedge Savings")
    ax.axhline(y=0,color=TXT,linewidth=0.5)
    ax.legend(loc="upper left"); ax.set_ylabel("USD"); ax.grid(True,alpha=0.3)
    plt.tight_layout()
    plt.savefig(f"{output_dir}/02_cumulative_pnl.png",dpi=150,bbox_inches="tight"); plt.close()

    # 3. Dynamic Fee Multiplier
    fig,(a1,a2)=plt.subplots(2,1,figsize=(14,8),sharex=True)
    fig.suptitle(f"{prefix}Layer 1: Dynamic Fee Effect",fontsize=14,color=G)
    a1.plot(dates,[r.realized_vol*100 for r in results],color=Y,linewidth=1.5,label="Realized Vol %")
    a1.axhline(y=30,color=G,linewidth=0.5,alpha=0.5,linestyle="--")
    a1.axhline(y=60,color=R,linewidth=0.5,alpha=0.5,linestyle="--")
    a1.legend(); a1.set_ylabel("Vol %"); a1.grid(True,alpha=0.3)

    a2.plot(dates,[r.dynamic_fee_mult for r in results],color=B,linewidth=1.5,label="Fee Multiplier")
    a2.axhline(y=1.0,color=TXT,linewidth=0.5)
    a2.fill_between(dates,[r.dynamic_fee_mult for r in results],1.0,alpha=0.2,color=B)
    a2.legend(); a2.set_ylabel("Multiplier"); a2.grid(True,alpha=0.3)
    plt.tight_layout()
    plt.savefig(f"{output_dir}/03_dynamic_fee.png",dpi=150,bbox_inches="tight"); plt.close()

    # 4. Pool + Treasury Health
    fig,ax=plt.subplots(figsize=(14,6))
    fig.suptitle(f"{prefix}Pool & Treasury Health",fontsize=14,color=G)
    ax.plot(dates,[r.pool_tvl for r in results],color=B,linewidth=1.5,label="Pool TVL")
    ax.plot(dates,[r.treasury_buffer for r in results],color=Y,linewidth=1.5,label="Treasury")
    ax.legend(); ax.set_ylabel("USD"); ax.grid(True,alpha=0.3)
    plt.tight_layout()
    plt.savefig(f"{output_dir}/04_pool_health.png",dpi=150,bbox_inches="tight"); plt.close()

    print(f"  Charts -> {output_dir}/")


# ================================================================
# Scenarios
# ================================================================
SCENARIOS = {
    "phase1": {
        "name": "Phase 1-2 ($100K)",
        "days": 365, "pool_tvl": 100_000, "treasury": 20_000,
        "num_lps": 10, "avg_lp": 30_000, "churn": 0.05,
    },
    "phase3": {
        "name": "Phase 3 ($10M)",
        "days": 365, "pool_tvl": 10_000_000, "treasury": 2_000_000,
        "num_lps": 100, "avg_lp": 200_000, "churn": 0.04,
    },
    "phase4": {
        "name": "Phase 4 ($20M)",
        "days": 365, "pool_tvl": 20_000_000, "treasury": 4_000_000,
        "num_lps": 200, "avg_lp": 300_000, "churn": 0.03,
    },
    "phase5": {
        "name": "Phase 5 ($170M)",
        "days": 365, "pool_tvl": 170_000_000, "treasury": 34_000_000,
        "num_lps": 500, "avg_lp": 500_000, "churn": 0.02,
    },
}


def run_scenario(key, layers=True):
    s = SCENARIOS[key]
    print(f"\n  SCENARIO: {s['name']} {'(3-Layer)' if layers else '(Baseline)'}")
    prices = fetch_eth_prices(s["days"])
    bt = BELTABacktesterV4(
        pool_tvl=s["pool_tvl"], treasury=s["treasury"],
        num_lps=s["num_lps"], avg_lp_size=s["avg_lp"],
        lp_churn=s["churn"],
        enable_dynamic_fee=layers,
        enable_aave=layers,
        enable_hedge=layers,
    )
    results = bt.run(prices)
    bt.summary()
    suffix = "v4" if layers else "v4_baseline"
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results", f"{suffix}_{key}")
    charts(results, out, f"[{s['name']}] ")
    return bt, results


def run_all():
    print(f"\n{'='*60}")
    print(f"  BELTA V4 -- 3-LAYER HEDGING BACKTESTING")
    print(f"{'='*60}")

    all_r = {}
    for k in SCENARIOS:
        bt, res = run_scenario(k)
        all_r[k] = (bt, res)

    print(f"\n{'='*75}")
    print(f"  V4 SCENARIO COMPARISON (3-Layer Model)")
    print(f"{'='*75}")
    print(f"  {'Scenario':<25} {'Net P&L':>12} {'UW APY':>8} {'Prof%':>7} {'Sharpe':>8} {'Pool':>8}")
    print(f"  {'-'*68}")

    for k,(bt,res) in all_r.items():
        if res:
            last = res[-1]
            days = len(res)*EPOCH_DAYS
            apy = (last.cum_pnl/bt.initial_pool)/(days/365)*100
            pnls = [x.total_premium_collected+x.pool_aave_yield+x.treasury_aave_yield
                    -x.actual_payout-x.hedge_funding_cost-x.hedge_rebalance_cost for x in res]
            prof = sum(1 for p in pnls if p>=0)/len(res)*100
            sharpe = np.mean(pnls)/np.std(pnls)*np.sqrt(52/EPOCH_DAYS) if np.std(pnls)>0 else 0
            pool_chg = ((last.pool_tvl/bt.initial_pool)-1)*100
            print(f"  {SCENARIOS[k]['name']:<25} ${last.cum_pnl:>10,.0f} {apy:>+7.1f}% {prof:>6.0f}% {sharpe:>+7.2f} {pool_chg:>+7.1f}%")

    print(f"  {'='*68}")


def run_compare():
    """Run V3-equivalent (no layers) vs V4 (3 layers) side-by-side."""
    print(f"\n{'='*75}")
    print(f"  V3 vs V4 COMPARISON")
    print(f"{'='*75}")

    results = {}
    for k in SCENARIOS:
        s = SCENARIOS[k]
        prices = fetch_eth_prices(s["days"])

        # V3 equivalent: no layers
        bt3 = BELTABacktesterV4(
            pool_tvl=s["pool_tvl"], treasury=s["treasury"],
            num_lps=s["num_lps"], avg_lp_size=s["avg_lp"], lp_churn=s["churn"],
            enable_dynamic_fee=False, enable_aave=False, enable_hedge=False,
        )
        r3 = bt3.run(prices)

        # V4: all layers
        bt4 = BELTABacktesterV4(
            pool_tvl=s["pool_tvl"], treasury=s["treasury"],
            num_lps=s["num_lps"], avg_lp_size=s["avg_lp"], lp_churn=s["churn"],
            enable_dynamic_fee=True, enable_aave=True, enable_hedge=True,
        )
        r4 = bt4.run(prices)

        results[k] = (bt3, r3, bt4, r4)

    print(f"\n{'='*85}")
    print(f"  {'Scenario':<25} {'V3 P&L':>12} {'V3 APY':>8} | {'V4 P&L':>12} {'V4 APY':>8} {'Improv':>8}")
    print(f"  {'-'*78}")

    for k,(bt3,r3,bt4,r4) in results.items():
        if r3 and r4:
            l3 = r3[-1]; l4 = r4[-1]
            d3 = len(r3)*EPOCH_DAYS; d4 = len(r4)*EPOCH_DAYS
            apy3 = (l3.cum_pnl/bt3.initial_pool)/(d3/365)*100
            apy4 = (l4.cum_pnl/bt4.initial_pool)/(d4/365)*100
            diff = apy4 - apy3
            print(f"  {SCENARIOS[k]['name']:<25} ${l3.cum_pnl:>10,.0f} {apy3:>+7.1f}% | ${l4.cum_pnl:>10,.0f} {apy4:>+7.1f}% {diff:>+7.1f}%")

    print(f"  {'='*78}")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        arg = sys.argv[1]
        if arg == "all": run_all()
        elif arg == "compare": run_compare()
        elif arg in SCENARIOS: run_scenario(arg)
        else: print(f"Unknown: {arg}")
    else:
        run_all()
