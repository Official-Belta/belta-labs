"""
BELTA Labs -- Backtesting Engine V3 (Whitepaper-Accurate Model)
================================================================
Matches CLAUDE.md / Whitepaper assumptions:
  1. Premium = LP fee income x 12% (not position size x 12%)
  2. IL payout = max(0, IL - fee_income) x coverage_cap (net loss only)
  3. LP fee income (22.4% APY) offsets most IL in normal markets
  4. Multi-LP with realistic churn (IL realized on exit only)
  5. Pool sized appropriately for LP coverage capacity

Usage:
  python backtest/engine_v3.py
  python backtest/engine_v3.py [scenario]
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
COVERAGE_CAP = 0.45          # 45% of NET IL (after fee offset)
PREMIUM_RATE = 0.12          # 12% of LP fee income
LP_FEE_APY = 0.224           # 22.4% (ETH/USDC 0.05% pool mid estimate)
EPOCH_DAYS = 7
KINK_UTILIZATION = 0.80
MAX_MULTIPLIER = 3.0
CAP_MULT = 5                 # Pool capacity = 5x TVL
DAILY_PAY_LIMIT = 0.05       # 5% of pool per day
TREASURY_RATIO = 0.20        # 20% of premiums to treasury
SELF_HEAL_RATIO = 0.20
AAVE_BASE_YIELD = 0.05       # 5% Aave base yield for pool


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
    net_il_on_exit: float = 0.0  # IL minus fee offset
    payout_received: float = 0.0


@dataclass
class EpochSnap:
    epoch: int
    date: datetime
    eth_price: float
    price_change_pct: float
    num_active_lps: int
    total_lp_liquidity: float

    # Revenue
    total_fee_generated: float     # All LP fee income this epoch
    total_premium_collected: float # Premiums from all LPs
    premium_to_pool: float
    premium_to_treasury: float
    pool_aave_yield: float         # Aave base yield on pool TVL

    # IL Payouts (only exiting LPs)
    lps_exiting: int
    lps_with_net_il: int          # Exiting LPs where IL > fees
    gross_il: float               # Raw IL of exiting LPs
    fee_offset: float             # Fee income that offset IL
    net_il: float                 # IL after fee offset
    covered_il: float             # After 45% cap
    actual_payout: float          # After pool limits
    treasury_absorbed: float

    # Pool state
    pool_tvl: float
    treasury_buffer: float
    utilization: float
    premium_rate: float

    # Cumulative
    cum_premiums: float
    cum_aave_yield: float
    cum_total_revenue: float      # premiums + aave
    cum_payouts: float
    cum_pnl: float


# ================================================================
# Engine V3
# ================================================================
class BELTABacktesterV3:

    def __init__(self, pool_tvl=1_000_000, treasury=200_000,
                 num_lps=50, avg_lp_size=100_000, lp_size_std=50_000,
                 lp_churn=0.05, lp_fee_apy=LP_FEE_APY):
        self.initial_pool = pool_tvl
        self.initial_treasury = treasury
        self.pool_tvl = pool_tvl
        self.treasury = treasury
        self.num_lps = num_lps
        self.avg_lp = avg_lp_size
        self.lp_std = lp_size_std
        self.churn = lp_churn
        self.lp_fee_apy = lp_fee_apy

        self.lps: list[LP] = []
        self.results: list[EpochSnap] = []
        self.next_id = 0

        self.cum_premiums = 0.0
        self.cum_aave = 0.0
        self.cum_payouts = 0.0
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

    def run(self, prices: pd.DataFrame):
        print(f"\n  {'='*56}")
        print(f"  BELTA V3 Whitepaper-Accurate Backtesting")
        print(f"  {'='*56}")
        print(f"  Pool:       ${self.initial_pool:,.0f}")
        print(f"  Treasury:   ${self.initial_treasury:,.0f}")
        print(f"  LPs:        {self.num_lps} (avg ${self.avg_lp:,.0f})")
        print(f"  LP Fee APY: {self.lp_fee_apy:.1%}")
        print(f"  Premium:    {PREMIUM_RATE:.0%} of fee income")
        print(f"  Coverage:   {COVERAGE_CAP:.0%} of NET IL")
        print(f"  Churn:      {self.churn:.0%}/epoch")
        print()

        ep = prices.resample(f"{EPOCH_DAYS}D").last().dropna()
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

            active = [lp for lp in self.lps if lp.active]
            total_liq = sum(lp.liquidity_usd for lp in active)

            # === 1. LP Fee Income (all active LPs earn fees) ===
            epoch_fee_total = 0
            for lp in active:
                fee = lp.liquidity_usd * self.lp_fee_apy / 365 * EPOCH_DAYS
                lp.total_fee_earned += fee
                epoch_fee_total += fee

            # === 2. Premiums = % of fee income (from CLAUDE.md) ===
            capacity = self.pool_tvl * CAP_MULT
            util = total_liq * COVERAGE_CAP / capacity if capacity > 0 else 0
            util = min(util, 1.0)
            prem_rate = get_premium_rate(util)

            total_prem = 0
            for lp in active:
                lp_fee = lp.liquidity_usd * self.lp_fee_apy / 365 * EPOCH_DAYS
                prem = lp_fee * prem_rate
                lp.total_premium_paid += prem
                total_prem += prem

            prem_to_treasury = total_prem * TREASURY_RATIO
            prem_to_pool = total_prem - prem_to_treasury

            # === 3. Aave base yield on pool TVL ===
            aave_yield = self.pool_tvl * AAVE_BASE_YIELD / 365 * EPOCH_DAYS

            # === 4. LP Churn - exiting LPs realize IL ===
            n_exit = max(1, int(len(active) * self.churn))
            # Oldest LPs exit
            exiting = sorted(active, key=lambda x: x.entry_epoch)[:n_exit]

            gross_il = 0
            fee_offset = 0
            net_il = 0
            lps_with_net_il = 0

            for lp in exiting:
                # Raw IL from entry to now
                ratio = price / lp.entry_price
                raw_il = il_v3(ratio, lp.tick_lower, lp.tick_upper) * lp.liquidity_usd
                lp.il_on_exit = raw_il

                # Fee income earned while in position offsets IL
                lp_fees = lp.total_fee_earned
                lp_net_il = max(0, raw_il - lp_fees)
                lp.net_il_on_exit = lp_net_il

                gross_il += raw_il
                fee_offset += min(raw_il, lp_fees)

                if lp_net_il > 0:
                    net_il += lp_net_il
                    lps_with_net_il += 1

                lp.active = False

            # Coverage cap on net IL
            covered_il = net_il * COVERAGE_CAP

            # Pool daily pay limit
            daily_lim = self.pool_tvl * DAILY_PAY_LIMIT
            epoch_lim = daily_lim * EPOCH_DAYS
            actual_payout = min(covered_il, epoch_lim)

            # Treasury first-loss
            treasury_abs = 0
            if actual_payout > 0 and self.treasury > 0:
                absorb = min(actual_payout * 0.30, self.treasury)
                self.treasury -= absorb
                treasury_abs = absorb
                self.total_treasury_abs += absorb

            pool_payout = min(actual_payout - treasury_abs, self.pool_tvl)

            # Distribute payouts to exiting LPs
            if net_il > 0:
                for lp in exiting:
                    if lp.net_il_on_exit > 0:
                        share = lp.net_il_on_exit / net_il
                        lp.payout_received = actual_payout * share

            # === 5. Update pool ===
            self.pool_tvl -= pool_payout
            self.pool_tvl += prem_to_pool + aave_yield
            self.treasury += prem_to_treasury

            # Self-healing
            if self.treasury < self.initial_treasury * 0.5:
                heal = prem_to_pool * SELF_HEAL_RATIO
                self.treasury += heal
                self.pool_tvl -= heal

            self.cum_premiums += total_prem
            self.cum_aave += aave_yield
            self.cum_payouts += actual_payout

            # New LPs replace departed
            for _ in range(n_exit):
                noise = np.random.uniform(0.98, 1.02)
                self.lps.append(self._new_lp(price * noise, epoch))

            # Record
            self.results.append(EpochSnap(
                epoch=epoch, date=date, eth_price=price,
                price_change_pct=pchg*100,
                num_active_lps=len([l for l in self.lps if l.active]),
                total_lp_liquidity=total_liq,
                total_fee_generated=epoch_fee_total,
                total_premium_collected=total_prem,
                premium_to_pool=prem_to_pool,
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
                pool_tvl=self.pool_tvl,
                treasury_buffer=self.treasury,
                utilization=util*100,
                premium_rate=prem_rate*100,
                cum_premiums=self.cum_premiums,
                cum_aave_yield=self.cum_aave,
                cum_total_revenue=self.cum_premiums + self.cum_aave,
                cum_payouts=self.cum_payouts,
                cum_pnl=(self.cum_premiums + self.cum_aave) - self.cum_payouts,
            ))

        print(f"  Done: {len(self.results)} epochs\n")
        return self.results

    def summary(self):
        if not self.results: return
        r = self.results
        last = r[-1]
        days = len(r) * EPOCH_DAYS

        total_rev = last.cum_total_revenue
        uw_return = last.cum_pnl / self.initial_pool * 100
        uw_apy = uw_return / (days/365)

        pnls = [x.total_premium_collected + x.pool_aave_yield - x.actual_payout for x in r]
        sharpe = np.mean(pnls) / np.std(pnls) * np.sqrt(52/EPOCH_DAYS) if np.std(pnls) > 0 else 0
        prof_epochs = sum(1 for p in pnls if p >= 0)

        # LP analysis
        all_exited = [lp for lp in self.lps if not lp.active]
        lps_net_positive = sum(1 for lp in all_exited if lp.payout_received > lp.total_premium_paid)
        avg_lp_prem = np.mean([lp.total_premium_paid for lp in all_exited]) if all_exited else 0
        avg_lp_fee = np.mean([lp.total_fee_earned for lp in all_exited]) if all_exited else 0
        avg_lp_il = np.mean([lp.il_on_exit for lp in all_exited]) if all_exited else 0
        avg_lp_payout = np.mean([lp.payout_received for lp in all_exited]) if all_exited else 0

        print(f"  {'='*56}")
        print(f"  BELTA V3 RESULTS (Whitepaper Model)")
        print(f"  {'='*56}")
        print(f"  Period: {r[0].date.strftime('%Y-%m-%d')} -> {last.date.strftime('%Y-%m-%d')}")
        print(f"  ETH:    ${r[0].eth_price:,.0f} -> ${last.eth_price:,.0f} ({((last.eth_price/r[0].eth_price)-1)*100:+.1f}%)")
        print(f"  Epochs: {len(r)} ({days}d)")

        print(f"\n  --- Revenue Sources ---")
        print(f"  LP Premiums:        ${last.cum_premiums:,.0f}")
        print(f"  Aave Pool Yield:    ${last.cum_aave_yield:,.0f}")
        print(f"  Total Revenue:      ${total_rev:,.0f}")

        print(f"\n  --- IL Payouts ---")
        print(f"  Total Payouts:      ${last.cum_payouts:,.0f}")
        print(f"  Treasury Absorbed:  ${self.total_treasury_abs:,.0f}")
        print(f"  Avg Gross IL/epoch: ${np.mean([x.gross_il for x in r]):,.0f}")
        print(f"  Avg Fee Offset:     ${np.mean([x.fee_offset for x in r]):,.0f} ({np.mean([x.fee_offset/(x.gross_il+0.01)*100 for x in r]):.0f}% of IL)")
        print(f"  Avg Net IL/epoch:   ${np.mean([x.net_il for x in r]):,.0f}")
        print(f"  Avg Payout/epoch:   ${np.mean([x.actual_payout for x in r]):,.0f}")

        print(f"\n  --- Net P&L ---")
        print(f"  Net P&L:            ${last.cum_pnl:,.0f}")
        print(f"  Profitable Epochs:  {prof_epochs}/{len(r)} ({prof_epochs/len(r)*100:.0f}%)")

        print(f"\n  --- Pool Health ---")
        print(f"  Pool TVL:   ${self.initial_pool:,.0f} -> ${last.pool_tvl:,.0f} ({((last.pool_tvl/self.initial_pool)-1)*100:+.1f}%)")
        print(f"  Treasury:   ${self.initial_treasury:,.0f} -> ${last.treasury_buffer:,.0f} ({((last.treasury_buffer/self.initial_treasury)-1)*100:+.1f}%)")

        print(f"\n  --- Underwriter Returns ---")
        print(f"  Return:     {uw_return:+.2f}%")
        print(f"  APY:        {uw_apy:+.2f}%")
        print(f"  Sharpe:     {sharpe:+.2f}")

        print(f"\n  --- Average LP (exited, n={len(all_exited)}) ---")
        print(f"  Avg Fee Earned:     ${avg_lp_fee:,.0f}")
        print(f"  Avg Premium Paid:   ${avg_lp_prem:,.0f} ({avg_lp_prem/(avg_lp_fee+0.01)*100:.1f}% of fees)")
        print(f"  Avg Gross IL:       ${avg_lp_il:,.0f}")
        print(f"  Avg Payout:         ${avg_lp_payout:,.0f}")
        print(f"  Avg Net Cost:       ${avg_lp_prem - avg_lp_payout:,.0f}")
        print(f"  LPs Net Positive:   {lps_net_positive}/{len(all_exited)} ({lps_net_positive/max(len(all_exited),1)*100:.0f}%)")

        print(f"\n  Solvency: {'MAINTAINED' if last.pool_tvl > 0 else 'FAILED'}")
        print(f"  {'='*56}")


# ================================================================
# Charts
# ================================================================
def charts(results, output_dir, prefix=""):
    if not results: return
    os.makedirs(output_dir, exist_ok=True)
    dates = [r.date for r in results]
    BG="#0a0e1a"; TXT="#e0e0e0"; G="#00ff88"; B="#00d4ff"; R="#ff4466"; Y="#ffcc00"; GR="#1a2040"
    plt.rcParams.update({"figure.facecolor":BG,"axes.facecolor":BG,"axes.edgecolor":GR,
        "text.color":TXT,"axes.labelcolor":TXT,"xtick.color":TXT,"ytick.color":TXT,
        "grid.color":GR,"font.size":10})

    # 1. Revenue vs Payouts
    fig,(a1,a2)=plt.subplots(2,1,figsize=(14,8),sharex=True)
    fig.suptitle(f"{prefix}Revenue vs IL Payouts",fontsize=14,color=G)
    a1.plot(dates,[r.eth_price for r in results],color=B,linewidth=1.5)
    a1.fill_between(dates,[r.eth_price for r in results],alpha=0.1,color=B)
    a1.set_ylabel("ETH (USD)"); a1.grid(True,alpha=0.3)

    a2.bar(dates,[r.total_premium_collected+r.pool_aave_yield for r in results],
           width=EPOCH_DAYS,color=G,alpha=0.6,label="Revenue (Prem+Aave)")
    a2.bar(dates,[-r.actual_payout for r in results],width=EPOCH_DAYS,
           color=R,alpha=0.6,label="IL Payout")
    a2.axhline(y=0,color=TXT,linewidth=0.5)
    a2.legend(loc="upper left"); a2.set_ylabel("USD/Epoch"); a2.grid(True,alpha=0.3)
    plt.tight_layout()
    plt.savefig(f"{output_dir}/01_revenue_vs_payout.png",dpi=150,bbox_inches="tight"); plt.close()

    # 2. Cumulative P&L
    fig,ax=plt.subplots(figsize=(14,6))
    fig.suptitle(f"{prefix}Cumulative P&L",fontsize=14,color=G)
    ax.plot(dates,[r.cum_total_revenue for r in results],color=G,linewidth=1.5,label="Total Revenue")
    ax.plot(dates,[r.cum_payouts for r in results],color=R,linewidth=1.5,label="Total Payouts")
    ax.plot(dates,[r.cum_pnl for r in results],color=B,linewidth=2,label="Net P&L")
    ax.fill_between(dates,[r.cum_pnl for r in results],alpha=0.15,color=B)
    ax.axhline(y=0,color=TXT,linewidth=0.5)
    ax.legend(loc="upper left"); ax.set_ylabel("USD"); ax.grid(True,alpha=0.3)
    plt.tight_layout()
    plt.savefig(f"{output_dir}/02_cumulative_pnl.png",dpi=150,bbox_inches="tight"); plt.close()

    # 3. IL Breakdown (gross vs fee offset vs net)
    fig,(a1,a2)=plt.subplots(2,1,figsize=(14,8),sharex=True)
    fig.suptitle(f"{prefix}IL Breakdown: Gross -> Fee Offset -> Net",fontsize=14,color=G)
    a1.bar(dates,[r.gross_il for r in results],width=EPOCH_DAYS,color=R,alpha=0.4,label="Gross IL")
    a1.bar(dates,[r.fee_offset for r in results],width=EPOCH_DAYS,color=G,alpha=0.6,label="Fee Offset")
    a1.bar(dates,[r.net_il for r in results],width=EPOCH_DAYS,color=Y,alpha=0.8,label="Net IL (claimable)")
    a1.legend(loc="upper left"); a1.set_ylabel("USD"); a1.grid(True,alpha=0.3)

    a2.plot(dates,[r.pool_tvl for r in results],color=B,linewidth=1.5,label="Pool TVL")
    a2.plot(dates,[r.treasury_buffer for r in results],color=Y,linewidth=1.5,label="Treasury")
    a2.legend(loc="upper left"); a2.set_ylabel("USD"); a2.grid(True,alpha=0.3)
    plt.tight_layout()
    plt.savefig(f"{output_dir}/03_il_breakdown.png",dpi=150,bbox_inches="tight"); plt.close()

    # 4. LP Economics
    fig,ax=plt.subplots(figsize=(14,6))
    fig.suptitle(f"{prefix}LP Economics: Fee Income vs Premium Cost",fontsize=14,color=G)
    ax.bar(dates,[r.total_fee_generated for r in results],width=EPOCH_DAYS,
           color=G,alpha=0.5,label="LP Fee Income")
    ax.bar(dates,[-r.total_premium_collected for r in results],width=EPOCH_DAYS,
           color=Y,alpha=0.5,label="Premium Cost")
    net_lp = [r.total_fee_generated - r.total_premium_collected for r in results]
    ax.plot(dates,net_lp,color=B,linewidth=2,label="LP Net (Fee - Premium)")
    ax.axhline(y=0,color=TXT,linewidth=0.5)
    ax.legend(loc="upper left"); ax.set_ylabel("USD/Epoch"); ax.grid(True,alpha=0.3)
    plt.tight_layout()
    plt.savefig(f"{output_dir}/04_lp_economics.png",dpi=150,bbox_inches="tight"); plt.close()

    print(f"  Charts -> {output_dir}/")


# ================================================================
# Scenarios
# ================================================================
SCENARIOS = {
    "phase1": {
        "name": "Phase 1-2 Single Pool ($100K)",
        "days": 365,
        "pool_tvl": 100_000,
        "treasury": 20_000,
        "num_lps": 10,
        "avg_lp": 30_000,
        "churn": 0.05,
    },
    "phase3": {
        "name": "Phase 3 Open Market ($10M)",
        "days": 365,
        "pool_tvl": 10_000_000,
        "treasury": 2_000_000,
        "num_lps": 100,
        "avg_lp": 200_000,
        "churn": 0.04,
    },
    "phase4": {
        "name": "Phase 4 DEX ($20M)",
        "days": 365,
        "pool_tvl": 20_000_000,
        "treasury": 4_000_000,
        "num_lps": 200,
        "avg_lp": 300_000,
        "churn": 0.03,
    },
    "phase5": {
        "name": "Phase 5 Global ($170M)",
        "days": 365,
        "pool_tvl": 170_000_000,
        "treasury": 34_000_000,
        "num_lps": 500,
        "avg_lp": 500_000,
        "churn": 0.02,
    },
}


def run_scenario(key):
    s = SCENARIOS[key]
    print(f"\n  SCENARIO: {s['name']}")
    prices = fetch_eth_prices(s["days"])
    bt = BELTABacktesterV3(
        pool_tvl=s["pool_tvl"], treasury=s["treasury"],
        num_lps=s["num_lps"], avg_lp_size=s["avg_lp"],
        lp_churn=s["churn"],
    )
    results = bt.run(prices)
    bt.summary()
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results", f"v3_{key}")
    charts(results, out, f"[{s['name']}] ")
    return bt, results


def run_all():
    print(f"\n{'='*60}")
    print(f"  BELTA V3 WHITEPAPER-ACCURATE BACKTESTING")
    print(f"{'='*60}")

    all_r = {}
    for k in SCENARIOS:
        bt, res = run_scenario(k)
        all_r[k] = (bt, res)

    print(f"\n{'='*70}")
    print(f"  V3 SCENARIO COMPARISON (Whitepaper Model)")
    print(f"{'='*70}")
    print(f"  {'Scenario':<30} {'Net P&L':>12} {'UW APY':>8} {'Prof%':>7} {'Sharpe':>8} {'Pool':>8}")
    print(f"  {'-'*73}")

    for k,(bt,res) in all_r.items():
        if res:
            last = res[-1]
            days = len(res)*EPOCH_DAYS
            apy = (last.cum_pnl/bt.initial_pool)/(days/365)*100
            pnls = [x.total_premium_collected+x.pool_aave_yield-x.actual_payout for x in res]
            prof = sum(1 for p in pnls if p>=0)/len(res)*100
            sharpe = np.mean(pnls)/np.std(pnls)*np.sqrt(52/EPOCH_DAYS) if np.std(pnls)>0 else 0
            pool_chg = ((last.pool_tvl/bt.initial_pool)-1)*100
            print(f"  {SCENARIOS[k]['name']:<30} ${last.cum_pnl:>10,.0f} {apy:>+7.1f}% {prof:>6.0f}% {sharpe:>+7.2f} {pool_chg:>+7.1f}%")

    print(f"  {'='*73}")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        arg = sys.argv[1]
        if arg == "all": run_all()
        elif arg in SCENARIOS: run_scenario(arg)
        else: print(f"Unknown: {arg}")
    else:
        run_all()
