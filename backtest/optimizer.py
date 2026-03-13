"""
BELTA Labs -- Parameter Optimizer
==================================
Grid search + sensitivity analysis to find optimal protocol parameters
that balance LP coverage with underwriter profitability.

Tunable Parameters:
  1. COVERAGE_CAP: 10% ~ 60%
  2. BASE_PREMIUM_RATE: 5% ~ 40%
  3. KINK_UTILIZATION: 50% ~ 90%
  4. MAX_MULTIPLIER: 2x ~ 5x
  5. TREASURY_RATIO: 10% ~ 30%

Optimization Target:
  - Underwriter APY > 0% (profitable)
  - LP savings > 50% vs unhedged
  - Pool solvency maintained
  - Sharpe ratio maximized

Usage:
  python backtest/optimizer.py
"""

import itertools
import math
import os
import sys
from dataclasses import dataclass

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

# Import engine
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import engine


# ================================================================
# Parameter Grid
# ================================================================
PARAM_GRID = {
    "coverage_cap":     [0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45],
    "base_premium":     [0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40],
    "kink_utilization":  [0.70, 0.80, 0.90],
    "max_multiplier":    [2.0, 3.0, 4.0],
    "treasury_ratio":    [0.15, 0.20, 0.25],
}

# Focused grid for faster iteration
FOCUSED_GRID = {
    "coverage_cap":     [0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45],
    "base_premium":     [0.12, 0.18, 0.24, 0.30, 0.36],
    "kink_utilization":  [0.80],
    "max_multiplier":    [3.0],
    "treasury_ratio":    [0.20],
}


@dataclass
class OptimizationResult:
    """Single parameter combination result"""
    coverage_cap: float
    base_premium: float
    kink_utilization: float
    max_multiplier: float
    treasury_ratio: float

    uw_apy: float           # Underwriter annualized return
    lp_savings_pct: float   # LP savings vs unhedged (%)
    sharpe: float           # Sharpe ratio
    max_il_pct: float       # Max IL experienced
    pool_solvent: bool      # Pool remained solvent
    final_pool_pct: float   # Final pool TVL as % of initial
    final_treasury_pct: float
    profitable_epochs_pct: float
    net_pnl: float


def run_single(prices: pd.DataFrame, params: dict,
               pool_tvl=1_000_000, treasury=200_000, lp_size=500_000) -> OptimizationResult:
    """Run simulation with specific parameters"""

    # Override global params
    engine.COVERAGE_CAP = params["coverage_cap"]
    engine.BASE_PREMIUM_RATE = params["base_premium"]
    engine.KINK_UTILIZATION = params["kink_utilization"]
    engine.MAX_MULTIPLIER = params["max_multiplier"]
    engine.TREASURY_RATIO = params["treasury_ratio"]

    bt = engine.BELTABacktester(
        initial_pool_tvl=pool_tvl,
        initial_treasury=treasury,
        lp_position_size=lp_size,
    )

    results = bt.run(prices)

    if not results:
        return OptimizationResult(
            **params, uw_apy=0, lp_savings_pct=0, sharpe=0,
            max_il_pct=0, pool_solvent=False, final_pool_pct=0,
            final_treasury_pct=0, profitable_epochs_pct=0, net_pnl=0
        )

    last = results[-1]
    days = len(results) * engine.EPOCH_DAYS

    # UW APY
    uw_return = last.cumulative_pnl / pool_tvl
    uw_apy = uw_return / (days / 365) * 100

    # LP savings
    max_il_usd = max(r.il_usd for r in results)
    hedged_loss = max_il_usd - bt.lp.il_claimed + bt.lp.premiums_paid
    lp_savings = (1 - hedged_loss / max_il_usd) * 100 if max_il_usd > 0 else 0

    # Sharpe
    pnls = [r.pool_pnl for r in results]
    sharpe = (np.mean(pnls) / np.std(pnls) * np.sqrt(52 / engine.EPOCH_DAYS)) if np.std(pnls) > 0 else 0

    max_il = max(r.il_v3 for r in results)
    profitable = sum(1 for r in results if r.pool_pnl >= 0) / len(results) * 100

    return OptimizationResult(
        coverage_cap=params["coverage_cap"],
        base_premium=params["base_premium"],
        kink_utilization=params["kink_utilization"],
        max_multiplier=params["max_multiplier"],
        treasury_ratio=params["treasury_ratio"],
        uw_apy=uw_apy,
        lp_savings_pct=lp_savings,
        sharpe=sharpe,
        max_il_pct=max_il,
        pool_solvent=last.pool_tvl > 0,
        final_pool_pct=(last.pool_tvl / pool_tvl) * 100,
        final_treasury_pct=(last.treasury_buffer / treasury) * 100,
        profitable_epochs_pct=profitable,
        net_pnl=last.cumulative_pnl,
    )


# ================================================================
# Grid Search
# ================================================================
def grid_search(prices: pd.DataFrame, grid: dict = None, top_n: int = 20) -> list[OptimizationResult]:
    """Run grid search over parameter combinations"""

    if grid is None:
        grid = FOCUSED_GRID

    keys = list(grid.keys())
    values = list(grid.values())
    combos = list(itertools.product(*values))

    print(f"\n{'='*60}")
    print(f"  BELTA PARAMETER OPTIMIZATION")
    print(f"{'='*60}")
    print(f"  Parameters: {len(keys)}")
    print(f"  Combinations: {len(combos)}")
    print(f"  Running...\n")

    all_results = []
    for i, combo in enumerate(combos):
        params = dict(zip(keys, combo))
        result = run_single(prices, params)
        all_results.append(result)

        if (i + 1) % 10 == 0 or i == len(combos) - 1:
            pct = (i + 1) / len(combos) * 100
            print(f"  [{pct:5.1f}%] {i+1}/{len(combos)} combinations tested")

    # Sort by composite score
    def score(r: OptimizationResult) -> float:
        """
        Composite score:
          - UW must be profitable (heavy penalty if not)
          - LP savings matters
          - Pool solvency is required
          - Sharpe is bonus
        """
        if not r.pool_solvent:
            return -1e6

        s = 0
        # UW profitability (most important)
        s += r.uw_apy * 3.0
        # LP savings (important)
        s += r.lp_savings_pct * 1.0
        # Sharpe (bonus)
        s += r.sharpe * 5.0
        # Pool health (bonus)
        s += (r.final_pool_pct - 100) * 0.5

        # Penalty for negative UW return
        if r.uw_apy < 0:
            s += r.uw_apy * 2.0  # extra penalty

        return s

    all_results.sort(key=score, reverse=True)

    # Print top results
    print(f"\n{'='*60}")
    print(f"  TOP {top_n} PARAMETER COMBINATIONS")
    print(f"{'='*60}")
    print(f"{'#':>3} {'Cap':>5} {'Prem':>5} {'Kink':>5} {'Mult':>5} {'Tres':>5} | {'UW APY':>8} {'LP Sav':>7} {'Sharpe':>7} {'Pool%':>7}")
    print("-" * 80)

    for i, r in enumerate(all_results[:top_n]):
        marker = " ***" if r.uw_apy > 0 and r.lp_savings_pct > 30 else ""
        print(f"{i+1:3d} {r.coverage_cap:5.0%} {r.base_premium:5.0%} {r.kink_utilization:5.0%} {r.max_multiplier:5.1f} {r.treasury_ratio:5.0%} | "
              f"{r.uw_apy:+7.1f}% {r.lp_savings_pct:6.1f}% {r.sharpe:+6.2f} {r.final_pool_pct:6.1f}%{marker}")

    # Find sweet spot
    sweet_spot = None
    for r in all_results:
        if r.uw_apy > 0 and r.lp_savings_pct > 30 and r.pool_solvent:
            sweet_spot = r
            break

    if sweet_spot:
        print(f"\n{'='*60}")
        print(f"  OPTIMAL PARAMETERS FOUND")
        print(f"{'='*60}")
        print(f"  Coverage Cap:      {sweet_spot.coverage_cap:.0%}")
        print(f"  Base Premium Rate: {sweet_spot.base_premium:.0%}")
        print(f"  Kink Utilization:  {sweet_spot.kink_utilization:.0%}")
        print(f"  Max Multiplier:    {sweet_spot.max_multiplier:.1f}x")
        print(f"  Treasury Ratio:    {sweet_spot.treasury_ratio:.0%}")
        print(f"  ---")
        print(f"  UW APY:            {sweet_spot.uw_apy:+.2f}%")
        print(f"  LP Savings:        {sweet_spot.lp_savings_pct:.1f}%")
        print(f"  Sharpe Ratio:      {sweet_spot.sharpe:+.2f}")
        print(f"  Pool Health:       {sweet_spot.final_pool_pct:.1f}%")
        print(f"  Profitable Epochs: {sweet_spot.profitable_epochs_pct:.0f}%")
        print(f"{'='*60}")
    else:
        print("\n  No combination found with UW APY > 0 AND LP savings > 30%")
        print("  Consider expanding the grid or adjusting pool/LP ratios")

    return all_results


# ================================================================
# Sensitivity Analysis (2D Heatmaps)
# ================================================================
def sensitivity_analysis(prices: pd.DataFrame, output_dir: str):
    """Generate 2D heatmaps for key parameter pairs"""

    os.makedirs(output_dir, exist_ok=True)

    BG_COLOR = "#0a0e1a"
    TEXT_COLOR = "#e0e0e0"

    plt.rcParams.update({
        "figure.facecolor": BG_COLOR,
        "axes.facecolor": BG_COLOR,
        "text.color": TEXT_COLOR,
        "axes.labelcolor": TEXT_COLOR,
        "xtick.color": TEXT_COLOR,
        "ytick.color": TEXT_COLOR,
        "font.size": 10,
    })

    # ---- Heatmap 1: Coverage Cap vs Premium Rate (UW APY) ----
    caps = [0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50]
    prems = [0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40]

    print("\n  Generating heatmap: Coverage Cap vs Premium Rate...")

    uw_apy_grid = np.zeros((len(prems), len(caps)))
    lp_sav_grid = np.zeros((len(prems), len(caps)))

    for i, prem in enumerate(prems):
        for j, cap in enumerate(caps):
            params = {
                "coverage_cap": cap,
                "base_premium": prem,
                "kink_utilization": 0.80,
                "max_multiplier": 3.0,
                "treasury_ratio": 0.20,
            }
            r = run_single(prices, params)
            uw_apy_grid[i, j] = r.uw_apy
            lp_sav_grid[i, j] = r.lp_savings_pct

    # UW APY Heatmap
    fig, ax = plt.subplots(figsize=(12, 8))
    im = ax.imshow(uw_apy_grid, cmap="RdYlGn", aspect="auto",
                   vmin=-30, vmax=30)

    ax.set_xticks(range(len(caps)))
    ax.set_xticklabels([f"{c:.0%}" for c in caps])
    ax.set_yticks(range(len(prems)))
    ax.set_yticklabels([f"{p:.0%}" for p in prems])
    ax.set_xlabel("Coverage Cap")
    ax.set_ylabel("Base Premium Rate")
    ax.set_title("Underwriter APY (%) by Coverage Cap x Premium Rate", color="#00ff88", fontsize=13)

    # Add text annotations
    for i in range(len(prems)):
        for j in range(len(caps)):
            val = uw_apy_grid[i, j]
            color = "white" if abs(val) > 15 else "black"
            ax.text(j, i, f"{val:+.1f}", ha="center", va="center", fontsize=8, color=color)

    # Mark break-even line
    cbar = plt.colorbar(im, ax=ax)
    cbar.set_label("UW APY (%)", color=TEXT_COLOR)
    cbar.ax.yaxis.set_tick_params(color=TEXT_COLOR)
    plt.setp(plt.getp(cbar.ax.axes, 'yticklabels'), color=TEXT_COLOR)

    plt.tight_layout()
    plt.savefig(f"{output_dir}/heatmap_uw_apy.png", dpi=150, bbox_inches="tight")
    plt.close()
    print("  -> heatmap_uw_apy.png saved")

    # LP Savings Heatmap
    fig, ax = plt.subplots(figsize=(12, 8))
    im = ax.imshow(lp_sav_grid, cmap="YlGnBu", aspect="auto", vmin=0, vmax=100)

    ax.set_xticks(range(len(caps)))
    ax.set_xticklabels([f"{c:.0%}" for c in caps])
    ax.set_yticks(range(len(prems)))
    ax.set_yticklabels([f"{p:.0%}" for p in prems])
    ax.set_xlabel("Coverage Cap")
    ax.set_ylabel("Base Premium Rate")
    ax.set_title("LP Savings vs Unhedged (%) by Coverage Cap x Premium Rate", color="#00ff88", fontsize=13)

    for i in range(len(prems)):
        for j in range(len(caps)):
            val = lp_sav_grid[i, j]
            color = "white" if val < 40 else "black"
            ax.text(j, i, f"{val:.0f}%", ha="center", va="center", fontsize=8, color=color)

    cbar = plt.colorbar(im, ax=ax)
    cbar.set_label("LP Savings (%)", color=TEXT_COLOR)
    cbar.ax.yaxis.set_tick_params(color=TEXT_COLOR)
    plt.setp(plt.getp(cbar.ax.axes, 'yticklabels'), color=TEXT_COLOR)

    plt.tight_layout()
    plt.savefig(f"{output_dir}/heatmap_lp_savings.png", dpi=150, bbox_inches="tight")
    plt.close()
    print("  -> heatmap_lp_savings.png saved")

    # ---- Heatmap 3: Combined Score ----
    fig, ax = plt.subplots(figsize=(12, 8))

    # Score: UW profitable AND LP gets good coverage
    combined = np.zeros_like(uw_apy_grid)
    for i in range(len(prems)):
        for j in range(len(caps)):
            uw = uw_apy_grid[i, j]
            lp = lp_sav_grid[i, j]
            # Green zone: UW > 0 AND LP > 30%
            if uw > 0 and lp > 30:
                combined[i, j] = uw + lp * 0.3
            elif uw > 0:
                combined[i, j] = uw * 0.5
            else:
                combined[i, j] = uw

    im = ax.imshow(combined, cmap="RdYlGn", aspect="auto")

    ax.set_xticks(range(len(caps)))
    ax.set_xticklabels([f"{c:.0%}" for c in caps])
    ax.set_yticks(range(len(prems)))
    ax.set_yticklabels([f"{p:.0%}" for p in prems])
    ax.set_xlabel("Coverage Cap")
    ax.set_ylabel("Base Premium Rate")
    ax.set_title("Combined Score (UW Profit + LP Coverage)", color="#00ff88", fontsize=13)

    for i in range(len(prems)):
        for j in range(len(caps)):
            uw = uw_apy_grid[i, j]
            lp = lp_sav_grid[i, j]
            marker = "*" if uw > 0 and lp > 30 else ""
            color = "white" if combined[i, j] < 0 else "black"
            ax.text(j, i, f"{uw:+.0f}/{lp:.0f}{marker}", ha="center", va="center",
                    fontsize=7, color=color)

    cbar = plt.colorbar(im, ax=ax)
    cbar.set_label("Score", color=TEXT_COLOR)
    cbar.ax.yaxis.set_tick_params(color=TEXT_COLOR)
    plt.setp(plt.getp(cbar.ax.axes, 'yticklabels'), color=TEXT_COLOR)

    plt.tight_layout()
    plt.savefig(f"{output_dir}/heatmap_combined.png", dpi=150, bbox_inches="tight")
    plt.close()
    print("  -> heatmap_combined.png saved")

    # ---- Frontier Chart: UW APY vs LP Savings ----
    fig, ax = plt.subplots(figsize=(10, 8))
    ax.set_facecolor(BG_COLOR)

    for i, prem in enumerate(prems):
        xs = [lp_sav_grid[i, j] for j in range(len(caps))]
        ys = [uw_apy_grid[i, j] for j in range(len(caps))]
        ax.plot(xs, ys, 'o-', markersize=6, alpha=0.8, label=f"Prem={prem:.0%}")

    ax.axhline(y=0, color="#ff4466", linewidth=1, linestyle="--", alpha=0.5, label="UW Break-even")
    ax.axvline(x=30, color="#ffcc00", linewidth=1, linestyle="--", alpha=0.5, label="LP Min Savings")

    # Highlight sweet spot zone
    ax.axhspan(0, 50, xmin=0, xmax=1, alpha=0.05, color="#00ff88")
    ax.text(50, 5, "SWEET SPOT", color="#00ff88", fontsize=12, alpha=0.5, ha="center")

    ax.set_xlabel("LP Savings vs Unhedged (%)")
    ax.set_ylabel("Underwriter APY (%)")
    ax.set_title("Efficient Frontier: UW Returns vs LP Protection", color="#00ff88", fontsize=13)
    ax.legend(loc="upper right", fontsize=8)
    ax.grid(True, alpha=0.2)

    plt.tight_layout()
    plt.savefig(f"{output_dir}/frontier.png", dpi=150, bbox_inches="tight")
    plt.close()
    print("  -> frontier.png saved")

    return uw_apy_grid, lp_sav_grid


# ================================================================
# Recommendation Engine
# ================================================================
def recommend_params(all_results: list[OptimizationResult]):
    """Analyze results and provide specific recommendations"""

    profitable = [r for r in all_results if r.uw_apy > 0 and r.pool_solvent]
    balanced = [r for r in profitable if r.lp_savings_pct > 20]

    print(f"\n{'='*60}")
    print(f"  PARAMETER RECOMMENDATIONS")
    print(f"{'='*60}")

    if not profitable:
        print("\n  WARNING: No profitable configuration found!")
        print("  Options:")
        print("    1. Increase base premium rate above 40%")
        print("    2. Lower coverage cap below 15%")
        print("    3. Increase pool TVL relative to LP positions")
        print("    4. Add more revenue sources (swap fees, etc.)")
        return

    # Conservative (highest UW return)
    conservative = max(profitable, key=lambda r: r.uw_apy)
    print(f"\n  [CONSERVATIVE] Max UW Return:")
    print(f"    Coverage Cap:  {conservative.coverage_cap:.0%}")
    print(f"    Premium Rate:  {conservative.base_premium:.0%}")
    print(f"    UW APY:        {conservative.uw_apy:+.1f}%")
    print(f"    LP Savings:    {conservative.lp_savings_pct:.1f}%")

    if balanced:
        # Balanced
        best_balanced = max(balanced, key=lambda r: r.uw_apy + r.lp_savings_pct * 0.3)
        print(f"\n  [BALANCED] Best Trade-off:")
        print(f"    Coverage Cap:  {best_balanced.coverage_cap:.0%}")
        print(f"    Premium Rate:  {best_balanced.base_premium:.0%}")
        print(f"    UW APY:        {best_balanced.uw_apy:+.1f}%")
        print(f"    LP Savings:    {best_balanced.lp_savings_pct:.1f}%")

    # Aggressive (highest LP coverage)
    aggressive = max(profitable, key=lambda r: r.lp_savings_pct)
    print(f"\n  [AGGRESSIVE] Max LP Coverage:")
    print(f"    Coverage Cap:  {aggressive.coverage_cap:.0%}")
    print(f"    Premium Rate:  {aggressive.base_premium:.0%}")
    print(f"    UW APY:        {aggressive.uw_apy:+.1f}%")
    print(f"    LP Savings:    {aggressive.lp_savings_pct:.1f}%")

    # Phase recommendations
    print(f"\n  PHASE RECOMMENDATION:")
    print(f"    Phase 1 (Testnet):   Conservative - build trust")
    print(f"      -> Cap={conservative.coverage_cap:.0%}, Prem={conservative.base_premium:.0%}")
    if balanced:
        print(f"    Phase 2 (Mainnet):   Balanced - attract both sides")
        print(f"      -> Cap={best_balanced.coverage_cap:.0%}, Prem={best_balanced.base_premium:.0%}")
    print(f"    Phase 3 (Scale):     Aggressive - market leadership")
    print(f"      -> Cap={aggressive.coverage_cap:.0%}, Prem={aggressive.base_premium:.0%}")
    print(f"{'='*60}")


# ================================================================
# Main
# ================================================================
if __name__ == "__main__":
    print("Fetching price data...")
    prices = engine.fetch_eth_prices(365)

    # 1. Grid Search
    results = grid_search(prices, FOCUSED_GRID, top_n=20)

    # 2. Sensitivity Analysis
    output_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results", "optimization")
    sensitivity_analysis(prices, output_dir)

    # 3. Recommendations
    recommend_params(results)

    print(f"\nAll optimization results saved to: {output_dir}/")
