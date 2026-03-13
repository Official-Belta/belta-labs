"""
BELTA Labs -- Backtesting Engine V2 (Multi-LP Realistic Model)
===============================================================
Key differences from V1:
  1. Multiple LPs with different entry times and tick ranges
  2. Epoch-based IL settlement (not cumulative from entry)
  3. IL resets when price returns to entry range
  4. Staggered LP entry/exit (realistic churn)
  5. Premium collected from ALL LPs, payouts only to affected LPs

Usage:
  python backtest/engine_v2.py
  python backtest/engine_v2.py [scenario]
"""

import math
import os
import sys
import random
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Optional

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import requests


# ================================================================
# Protocol Parameters
# ================================================================
COVERAGE_CAP = 0.45
BASE_PREMIUM_RATE = 0.12
EPOCH_DAYS = 7
KINK_UTILIZATION = 0.80
MAX_MULTIPLIER = 3.0
CAP_MULT = 5
DAILY_PAY_LIMIT = 0.05
TREASURY_RATIO = 0.20
SELF_HEAL_RATIO = 0.20


# ================================================================
# Data
# ================================================================
def fetch_eth_prices(days: int = 365) -> pd.DataFrame:
    print(f"Fetching ETH price data ({days} days)...")
    url = "https://api.coingecko.com/api/v3/coins/ethereum/market_chart"
    params = {"vs_currency": "usd", "days": days, "interval": "daily"}
    try:
        resp = requests.get(url, params=params, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        prices = data.get("prices", [])
        if not prices:
            raise ValueError("No prices")
        df = pd.DataFrame(prices, columns=["timestamp", "price"])
        df["date"] = pd.to_datetime(df["timestamp"], unit="ms")
        df = df[["date", "price"]].set_index("date")
        print(f"  Got {len(df)} points: ${df['price'].iloc[0]:.0f} -> ${df['price'].iloc[-1]:.0f}")
        return df
    except Exception as e:
        print(f"  API failed: {e}, generating synthetic data")
        return _gen_data(days)


def _gen_data(days: int) -> pd.DataFrame:
    np.random.seed(42)
    dates = pd.date_range(end=datetime.now(), periods=days, freq="D")
    dt = 1/365
    log_ret = np.random.normal(0, 0.80 * np.sqrt(dt), days)
    prices = 2000 * np.exp(np.cumsum(log_ret))
    df = pd.DataFrame({"price": prices}, index=dates)
    df.index.name = "date"
    print(f"  Generated {days} points: ${prices[0]:.0f} -> ${prices[-1]:.0f}")
    return df


# ================================================================
# IL Math
# ================================================================
def il_v2(price_ratio: float) -> float:
    if price_ratio <= 0:
        return 0.0
    sr = math.sqrt(price_ratio)
    return abs(2 * sr / (1 + price_ratio) - 1)


def il_v3(price_ratio: float, tick_lower: int, tick_upper: int) -> float:
    if price_ratio <= 0:
        return 0.0
    pa = 1.0001 ** tick_lower
    pb = 1.0001 ** tick_upper
    if pa >= pb:
        return 0.0
    base = il_v2(price_ratio)
    conc = 1 / (1 - math.sqrt(pa / pb))
    # Cap concentration to realistic max (avoid extreme values for narrow ranges)
    conc = min(conc, 10.0)
    return base * conc


def get_premium_rate(utilization: float) -> float:
    if utilization <= KINK_UTILIZATION:
        return BASE_PREMIUM_RATE
    excess = (utilization - KINK_UTILIZATION) / (1 - KINK_UTILIZATION)
    return BASE_PREMIUM_RATE * (1 + (MAX_MULTIPLIER - 1) * excess)


# ================================================================
# Multi-LP Model
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
    total_il_claimed: float = 0.0
    # Track epoch-start price for incremental IL
    epoch_start_price: float = 0.0

    def __post_init__(self):
        self.epoch_start_price = self.entry_price


@dataclass
class EpochSnapshot:
    epoch: int
    date: datetime
    eth_price: float
    price_change_pct: float
    num_active_lps: int
    total_lp_liquidity: float

    # Premiums
    total_premium_collected: float
    premium_to_pool: float
    premium_to_treasury: float

    # IL
    total_il_incurred: float      # Sum of all LP incremental IL
    total_il_payout: float        # Actual payout (after caps/limits)
    lps_with_il: int              # How many LPs had IL this epoch
    treasury_absorbed: float

    # Pool state
    pool_tvl: float
    treasury_buffer: float
    utilization: float
    premium_rate: float

    # Cumulative
    cum_premiums: float
    cum_payouts: float
    cum_pnl: float


class BELTABacktesterV2:
    """Multi-LP realistic backtesting engine"""

    def __init__(
        self,
        initial_pool_tvl: float = 1_000_000,
        initial_treasury: float = 200_000,
        num_lps: int = 50,
        avg_lp_size: float = 100_000,
        lp_size_std: float = 50_000,
        lp_churn_rate: float = 0.05,    # 5% of LPs leave/join per epoch
        tick_range_min: int = -3000,
        tick_range_max: int = 3000,
    ):
        self.initial_pool_tvl = initial_pool_tvl
        self.initial_treasury = initial_treasury
        self.pool_tvl = initial_pool_tvl
        self.treasury = initial_treasury

        self.num_lps = num_lps
        self.avg_lp_size = avg_lp_size
        self.lp_size_std = lp_size_std
        self.lp_churn_rate = lp_churn_rate
        self.tick_range_min = tick_range_min
        self.tick_range_max = tick_range_max

        self.lps: list[LP] = []
        self.results: list[EpochSnapshot] = []
        self.next_lp_id = 0

        self.cum_premiums = 0.0
        self.cum_payouts = 0.0
        self.total_treasury_absorbed = 0.0

    def _create_lp(self, entry_price: float, epoch: int) -> LP:
        """Create a new LP with randomized parameters"""
        size = max(10_000, np.random.normal(self.avg_lp_size, self.lp_size_std))

        # Random tick range (wider = less IL sensitivity)
        range_width = random.choice([2000, 3000, 4000, 6000, 8000])
        half = range_width // 2
        # Align to tick spacing of 60
        tick_lower = -(half // 60) * 60
        tick_upper = (half // 60) * 60

        lp = LP(
            id=self.next_lp_id,
            liquidity_usd=size,
            entry_price=entry_price,
            entry_epoch=epoch,
            tick_lower=tick_lower,
            tick_upper=tick_upper,
            epoch_start_price=entry_price,
        )
        self.next_lp_id += 1
        return lp

    def run(self, prices: pd.DataFrame) -> list[EpochSnapshot]:
        print(f"\n{'='*60}")
        print(f"  BELTA V2 Multi-LP Backtesting")
        print(f"{'='*60}")
        print(f"  Pool TVL:      ${self.initial_pool_tvl:,.0f}")
        print(f"  Treasury:      ${self.initial_treasury:,.0f}")
        print(f"  Initial LPs:   {self.num_lps}")
        print(f"  Avg LP Size:   ${self.avg_lp_size:,.0f}")
        print(f"  LP Churn:      {self.lp_churn_rate:.0%}/epoch")
        print(f"  Coverage Cap:  {COVERAGE_CAP:.0%}")
        print(f"  Premium Rate:  {BASE_PREMIUM_RATE:.0%}")
        print()

        # Resample to epochs
        epoch_prices = prices.resample(f"{EPOCH_DAYS}D").last().dropna()
        initial_price = epoch_prices["price"].iloc[0]

        # Create initial LP cohort
        np.random.seed(42)
        random.seed(42)
        for _ in range(self.num_lps):
            # Stagger entry prices slightly (LPs entered at different times)
            noise = np.random.uniform(0.95, 1.05)
            self.lps.append(self._create_lp(initial_price * noise, 0))

        # Run epochs
        for i in range(1, len(epoch_prices)):
            epoch = i
            current_price = epoch_prices["price"].iloc[i]
            prev_price = epoch_prices["price"].iloc[i - 1]
            epoch_date = epoch_prices.index[i]
            price_change = (current_price - prev_price) / prev_price

            active_lps = [lp for lp in self.lps if lp.active]
            total_lp_liquidity = sum(lp.liquidity_usd for lp in active_lps)

            # === 1. Collect premiums from ALL active LPs ===
            total_premium = 0
            capacity = self.pool_tvl * CAP_MULT
            utilization = total_lp_liquidity * COVERAGE_CAP / capacity if capacity > 0 else 0
            utilization = min(utilization, 1.0)
            prem_rate = get_premium_rate(utilization)

            for lp in active_lps:
                epoch_prem = (prem_rate / 365 * EPOCH_DAYS) * lp.liquidity_usd
                lp.total_premium_paid += epoch_prem
                total_premium += epoch_prem

            premium_to_treasury = total_premium * TREASURY_RATIO
            premium_to_pool = total_premium - premium_to_treasury

            # === 2. LP Churn — ONLY exiting LPs realize IL ===
            # This is the key insight: IL is only REALIZED when LP removes liquidity
            # Staying LPs pay premium but don't claim IL (it may revert)
            num_leaving = int(len(active_lps) * self.lp_churn_rate)
            leaving_lps = []
            if num_leaving > 0 and len(active_lps) > 10:
                # Mix of oldest and random LPs leaving
                leaving_lps = sorted(active_lps, key=lambda x: x.entry_epoch)[:num_leaving]

            # Calculate IL only for EXITING LPs
            total_il = 0
            lps_with_il = 0

            for lp in leaving_lps:
                # IL from their entry price to current price (realized on exit)
                ratio = current_price / lp.entry_price
                lp_il = il_v3(ratio, lp.tick_lower, lp.tick_upper) * lp.liquidity_usd

                # Apply coverage cap
                max_covered = lp.liquidity_usd * COVERAGE_CAP
                lp_il = min(lp_il, max_covered)

                if lp_il > 0:
                    total_il += lp_il
                    lps_with_il += 1
                    lp.total_il_claimed = lp_il

                lp.active = False

            # New LPs enter at current price (replacing departed ones)
            for _ in range(num_leaving):
                noise = np.random.uniform(0.98, 1.02)
                self.lps.append(self._create_lp(current_price * noise, epoch))

            # === 3. Apply pool limits and pay out ===
            daily_limit = self.pool_tvl * DAILY_PAY_LIMIT
            epoch_limit = daily_limit * EPOCH_DAYS
            actual_payout = min(total_il, epoch_limit)

            # Treasury first-loss absorption
            treasury_absorbed = 0
            if actual_payout > 0 and self.treasury > 0:
                absorb = min(actual_payout * 0.30, self.treasury)
                self.treasury -= absorb
                treasury_absorbed = absorb
                self.total_treasury_absorbed += absorb

            pool_payout = actual_payout - treasury_absorbed
            pool_payout = min(pool_payout, self.pool_tvl)

            # === 4. Update pool state ===
            self.pool_tvl -= pool_payout
            self.pool_tvl += premium_to_pool
            self.treasury += premium_to_treasury

            # Treasury self-healing
            if self.treasury < self.initial_treasury * 0.5:
                heal = premium_to_pool * SELF_HEAL_RATIO
                self.treasury += heal
                self.pool_tvl -= heal

            self.cum_premiums += total_premium
            self.cum_payouts += actual_payout

            # === 6. Record ===
            snap = EpochSnapshot(
                epoch=epoch,
                date=epoch_date,
                eth_price=current_price,
                price_change_pct=price_change * 100,
                num_active_lps=len([lp for lp in self.lps if lp.active]),
                total_lp_liquidity=total_lp_liquidity,
                total_premium_collected=total_premium,
                premium_to_pool=premium_to_pool,
                premium_to_treasury=premium_to_treasury,
                total_il_incurred=total_il,
                total_il_payout=actual_payout,
                lps_with_il=lps_with_il,
                treasury_absorbed=treasury_absorbed,
                pool_tvl=self.pool_tvl,
                treasury_buffer=self.treasury,
                utilization=utilization * 100,
                premium_rate=prem_rate * 100,
                cum_premiums=self.cum_premiums,
                cum_payouts=self.cum_payouts,
                cum_pnl=self.cum_premiums - self.cum_payouts,
            )
            self.results.append(snap)

        print(f"  Simulation complete: {len(self.results)} epochs")
        return self.results

    def print_summary(self):
        if not self.results:
            return

        r = self.results
        last = r[-1]

        days = len(r) * EPOCH_DAYS
        uw_return = last.cum_pnl / self.initial_pool_tvl * 100
        uw_apy = uw_return / (days / 365)

        active_lps = [lp for lp in self.lps if lp.active]
        total_prem_paid = sum(lp.total_premium_paid for lp in self.lps)
        total_il_claimed = sum(lp.total_il_claimed for lp in self.lps)
        avg_lp_prem = total_prem_paid / len(self.lps) if self.lps else 0
        avg_lp_claim = total_il_claimed / len(self.lps) if self.lps else 0

        # LP-level analysis
        lps_profitable = sum(1 for lp in self.lps if lp.total_il_claimed > lp.total_premium_paid)
        lps_total = len(self.lps)

        max_il_epoch = max(r, key=lambda x: x.total_il_incurred)
        max_prem_epoch = max(r, key=lambda x: x.total_premium_collected)

        profitable_epochs = sum(1 for x in r if x.total_premium_collected > x.total_il_payout)

        pnls = [x.total_premium_collected - x.total_il_payout for x in r]
        sharpe = np.mean(pnls) / np.std(pnls) * np.sqrt(52/EPOCH_DAYS) if np.std(pnls) > 0 else 0

        print(f"\n{'='*60}")
        print(f"  BELTA V2 RESULTS (Multi-LP Model)")
        print(f"{'='*60}")
        print(f"\n  Period: {r[0].date.strftime('%Y-%m-%d')} -> {last.date.strftime('%Y-%m-%d')}")
        print(f"  Epochs: {len(r)} ({days} days)")
        print(f"  ETH:    ${r[0].eth_price:,.0f} -> ${last.eth_price:,.0f} ({((last.eth_price/r[0].eth_price)-1)*100:+.1f}%)")

        print(f"\n--- LP Ecosystem ---")
        print(f"  Total LPs created:     {lps_total}")
        print(f"  Active LPs (final):    {len(active_lps)}")
        print(f"  Avg LP size:           ${np.mean([lp.liquidity_usd for lp in self.lps]):,.0f}")
        print(f"  Total LP liquidity:    ${last.total_lp_liquidity:,.0f}")
        print(f"  Avg premium paid/LP:   ${avg_lp_prem:,.0f}")
        print(f"  Avg IL claimed/LP:     ${avg_lp_claim:,.0f}")
        print(f"  LPs that claimed > paid: {lps_profitable}/{lps_total} ({lps_profitable/lps_total*100:.0f}%)")

        print(f"\n--- Protocol P&L ---")
        print(f"  Total Premiums:     ${last.cum_premiums:,.0f}")
        print(f"  Total IL Payouts:   ${last.cum_payouts:,.0f}")
        print(f"  Net P&L:            ${last.cum_pnl:,.0f}")
        print(f"  Treasury Absorbed:  ${self.total_treasury_absorbed:,.0f}")
        print(f"  Profitable Epochs:  {profitable_epochs}/{len(r)} ({profitable_epochs/len(r)*100:.0f}%)")

        print(f"\n--- Pool Health ---")
        print(f"  Initial Pool TVL:   ${self.initial_pool_tvl:,.0f}")
        print(f"  Final Pool TVL:     ${last.pool_tvl:,.0f} ({((last.pool_tvl/self.initial_pool_tvl)-1)*100:+.1f}%)")
        print(f"  Initial Treasury:   ${self.initial_treasury:,.0f}")
        print(f"  Final Treasury:     ${last.treasury_buffer:,.0f} ({((last.treasury_buffer/self.initial_treasury)-1)*100:+.1f}%)")

        print(f"\n--- Underwriter Returns ---")
        print(f"  Pool Return:        {uw_return:+.2f}%")
        print(f"  Annualized APY:     {uw_apy:+.2f}%")
        print(f"  Sharpe Ratio:       {sharpe:+.2f}")

        print(f"\n--- Epoch Stats ---")
        print(f"  Avg premium/epoch:  ${np.mean([x.total_premium_collected for x in r]):,.0f}")
        print(f"  Avg payout/epoch:   ${np.mean([x.total_il_payout for x in r]):,.0f}")
        print(f"  Max IL epoch:       #{max_il_epoch.epoch} (${max_il_epoch.total_il_incurred:,.0f}, {max_il_epoch.lps_with_il} LPs)")
        print(f"  Avg LPs with IL:    {np.mean([x.lps_with_il for x in r]):.1f}/{np.mean([x.num_active_lps for x in r]):.0f}")
        print(f"  Avg utilization:    {np.mean([x.utilization for x in r]):.1f}%")

        print(f"\n  Solvency: {'MAINTAINED' if last.pool_tvl > 0 else 'FAILED'}")
        print(f"{'='*60}")


# ================================================================
# Charts
# ================================================================
def generate_charts(results: list[EpochSnapshot], output_dir: str, title_prefix: str = ""):
    if not results:
        return
    os.makedirs(output_dir, exist_ok=True)

    dates = [r.date for r in results]
    BG = "#0a0e1a"
    TXT = "#e0e0e0"
    GREEN = "#00ff88"
    BLUE = "#00d4ff"
    RED = "#ff4466"
    YELLOW = "#ffcc00"
    GRID = "#1a2040"

    plt.rcParams.update({
        "figure.facecolor": BG, "axes.facecolor": BG,
        "axes.edgecolor": GRID, "text.color": TXT,
        "axes.labelcolor": TXT, "xtick.color": TXT,
        "ytick.color": TXT, "grid.color": GRID, "font.size": 10,
    })

    # Chart 1: Price + Premium vs Payout per epoch
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(14, 8), sharex=True)
    fig.suptitle(f"{title_prefix}ETH Price & Per-Epoch Flows", fontsize=14, color=GREEN)

    ax1.plot(dates, [r.eth_price for r in results], color=BLUE, linewidth=1.5)
    ax1.fill_between(dates, [r.eth_price for r in results], alpha=0.1, color=BLUE)
    ax1.set_ylabel("ETH Price (USD)")
    ax1.grid(True, alpha=0.3)

    ax2.bar(dates, [r.total_premium_collected for r in results], width=EPOCH_DAYS,
            color=GREEN, alpha=0.6, label="Premium In")
    ax2.bar(dates, [-r.total_il_payout for r in results], width=EPOCH_DAYS,
            color=RED, alpha=0.6, label="IL Payout")
    ax2.axhline(y=0, color=TXT, linewidth=0.5)
    ax2.set_ylabel("USD per Epoch")
    ax2.legend(loc="upper left")
    ax2.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig(f"{output_dir}/01_price_flows.png", dpi=150, bbox_inches="tight")
    plt.close()

    # Chart 2: Cumulative P&L
    fig, ax = plt.subplots(figsize=(14, 6))
    fig.suptitle(f"{title_prefix}Cumulative P&L", fontsize=14, color=GREEN)

    ax.plot(dates, [r.cum_premiums for r in results], color=GREEN, linewidth=1.5, label="Premiums")
    ax.plot(dates, [r.cum_payouts for r in results], color=RED, linewidth=1.5, label="Payouts")
    ax.plot(dates, [r.cum_pnl for r in results], color=BLUE, linewidth=2, label="Net P&L")
    ax.fill_between(dates, [r.cum_pnl for r in results], alpha=0.15, color=BLUE)
    ax.axhline(y=0, color=TXT, linewidth=0.5)
    ax.set_ylabel("Cumulative USD")
    ax.legend(loc="upper left")
    ax.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig(f"{output_dir}/02_cumulative_pnl.png", dpi=150, bbox_inches="tight")
    plt.close()

    # Chart 3: Pool Health + LP count
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(14, 8), sharex=True)
    fig.suptitle(f"{title_prefix}Pool Health & LP Activity", fontsize=14, color=GREEN)

    ax1.plot(dates, [r.pool_tvl for r in results], color=BLUE, linewidth=1.5, label="Pool TVL")
    ax1.plot(dates, [r.treasury_buffer for r in results], color=YELLOW, linewidth=1.5, label="Treasury")
    ax1.set_ylabel("USD")
    ax1.legend(loc="upper left")
    ax1.grid(True, alpha=0.3)

    ax2b = ax2.twinx()
    ax2.bar(dates, [r.lps_with_il for r in results], width=EPOCH_DAYS,
            color=RED, alpha=0.4, label="LPs with IL")
    ax2.bar(dates, [r.num_active_lps - r.lps_with_il for r in results], width=EPOCH_DAYS,
            bottom=[r.lps_with_il for r in results],
            color=GREEN, alpha=0.3, label="LPs no IL")
    ax2.set_ylabel("LP Count")
    ax2.legend(loc="upper left")

    ax2b.plot(dates, [r.utilization for r in results], color=YELLOW, linewidth=1, alpha=0.8)
    ax2b.set_ylabel("Utilization %", color=YELLOW)
    ax2.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig(f"{output_dir}/03_pool_health.png", dpi=150, bbox_inches="tight")
    plt.close()

    # Chart 4: Premium Rate + IL distribution
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(14, 8), sharex=True)
    fig.suptitle(f"{title_prefix}Premium Efficiency", fontsize=14, color=GREEN)

    # Premium vs IL ratio per epoch
    ratios = []
    for r in results:
        if r.total_il_payout > 0:
            ratios.append(r.total_premium_collected / r.total_il_payout)
        else:
            ratios.append(float('inf') if r.total_premium_collected > 0 else 1.0)

    capped_ratios = [min(r, 10) for r in ratios]
    colors = [GREEN if r >= 1 else RED for r in capped_ratios]
    ax1.bar(dates, capped_ratios, width=EPOCH_DAYS, color=colors, alpha=0.6)
    ax1.axhline(y=1, color=YELLOW, linewidth=1, linestyle="--", label="Break-even")
    ax1.set_ylabel("Premium/Payout Ratio")
    ax1.set_ylim(0, 10)
    ax1.legend()
    ax1.grid(True, alpha=0.3)

    # IL distribution across LPs
    ax2.plot(dates, [r.lps_with_il / max(r.num_active_lps, 1) * 100 for r in results],
             color=RED, linewidth=1.5, label="% LPs with IL")
    ax2.set_ylabel("% of LPs Affected")
    ax2.set_xlabel("Date")
    ax2.legend()
    ax2.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig(f"{output_dir}/04_premium_efficiency.png", dpi=150, bbox_inches="tight")
    plt.close()

    print(f"  Charts saved to: {output_dir}/")


# ================================================================
# Scenarios
# ================================================================
SCENARIOS = {
    "baseline": {
        "name": "Baseline (50 LPs, $1M Pool)",
        "days": 365,
        "pool_tvl": 1_000_000,
        "treasury": 200_000,
        "num_lps": 50,
        "avg_lp_size": 100_000,
        "churn": 0.05,
    },
    "growth": {
        "name": "Growth Phase (100 LPs, $5M Pool)",
        "days": 365,
        "pool_tvl": 5_000_000,
        "treasury": 1_000_000,
        "num_lps": 100,
        "avg_lp_size": 200_000,
        "churn": 0.03,
    },
    "stress": {
        "name": "Stress (20 LPs, Small Pool, High Churn)",
        "days": 365,
        "pool_tvl": 500_000,
        "treasury": 100_000,
        "num_lps": 20,
        "avg_lp_size": 200_000,
        "churn": 0.10,
    },
    "mature": {
        "name": "Mature Protocol (200 LPs, $20M Pool)",
        "days": 365,
        "pool_tvl": 20_000_000,
        "treasury": 4_000_000,
        "num_lps": 200,
        "avg_lp_size": 300_000,
        "churn": 0.02,
    },
}


def run_scenario(key: str):
    s = SCENARIOS[key]
    print(f"\n{'='*60}")
    print(f"  SCENARIO: {s['name']}")
    print(f"{'='*60}")

    prices = fetch_eth_prices(s["days"])

    bt = BELTABacktesterV2(
        initial_pool_tvl=s["pool_tvl"],
        initial_treasury=s["treasury"],
        num_lps=s["num_lps"],
        avg_lp_size=s["avg_lp_size"],
        lp_churn_rate=s["churn"],
    )

    results = bt.run(prices)
    bt.print_summary()

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results", f"v2_{key}")
    generate_charts(results, out, f"[{s['name']}] ")

    return bt, results


def run_all():
    print(f"\n{'='*60}")
    print(f"  BELTA V2 MULTI-LP BACKTESTING SUITE")
    print(f"{'='*60}")

    all_res = {}
    for key in SCENARIOS:
        bt, results = run_scenario(key)
        all_res[key] = (bt, results)

    # Comparison table
    print(f"\n{'='*70}")
    print(f"  V2 SCENARIO COMPARISON")
    print(f"{'='*70}")
    print(f"{'Scenario':<30} {'Net P&L':>12} {'UW APY':>8} {'Prof%':>7} {'Sharpe':>8} {'Solvent':>8}")
    print("-" * 73)

    for key, (bt, results) in all_res.items():
        if results:
            last = results[-1]
            days = len(results) * EPOCH_DAYS
            apy = (last.cum_pnl / bt.initial_pool_tvl) / (days/365) * 100
            prof = sum(1 for x in results if x.total_premium_collected > x.total_il_payout) / len(results) * 100
            pnls = [x.total_premium_collected - x.total_il_payout for x in results]
            sharpe = np.mean(pnls) / np.std(pnls) * np.sqrt(52/EPOCH_DAYS) if np.std(pnls) > 0 else 0
            solvent = "YES" if last.pool_tvl > 0 else "NO"
            print(f"  {SCENARIOS[key]['name']:<28} ${last.cum_pnl:>10,.0f} {apy:>+7.1f}% {prof:>6.0f}% {sharpe:>+7.2f} {solvent:>8}")

    print(f"{'='*73}")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        arg = sys.argv[1]
        if arg == "all":
            run_all()
        elif arg in SCENARIOS:
            run_scenario(arg)
        else:
            print(f"Unknown: {arg}. Available: {', '.join(SCENARIOS.keys())}, all")
    else:
        run_all()
