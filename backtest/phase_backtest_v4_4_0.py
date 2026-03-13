"""
BELTA IL Hedge Protocol -Multi-LP Cohort Backtest v4.4.0
==========================================================
실제 온체인 데이터 기반 LP 세그먼트 모델:

출처:
 - BIS Working Paper 1227 (2024): 정교한 투자자(7% of LPs) → TVL의 80% 지배
 - Uniswap v3 Dominance (Uniswap Labs): 포지션의 2/3가 1일 이상 보유
 - BlockBeats / arxiv 2111.09192: 평균 보유기간 ~35일, 70% LP 손실 상태
 - Harvard Strategic LP Paper: 좁은 범위일수록 IL ↑, 리밸런싱 비용 ↑

LP 세그먼트 정의:
 A. 기관/정교한 MM  (7% of LPs, 80% TVL) -narrow range, 7~30일 주기 리밸런싱
 B. 액티브 리테일  (20% of LPs, 15% TVL) -medium range, 30~90일
 C. 패시브 리테일  (73% of LPs,  5% TVL) -wide/full range, 90일+, 패닉 이탈

현실 반영 요소:
 - TVL이 epoch 0에 전부 들어오지 않음 → 성장 곡선 적용
 - 변동성 급등 시 리테일 패닉 이탈 (TVL −10~30%)
 - 기관은 오히려 기회로 인식해 재진입
 - BELTA 가입률: 기관 30% / 액티브 리테일 15% / 패시브 5%
"""

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.font_manager as fm
import matplotlib.patches as mpatches
import warnings
warnings.filterwarnings("ignore")

import os as _os
_font_candidates = [
    "/usr/share/fonts/opentype/noto/NotoSansCJK-DemiLight.ttc",
    "C:/Windows/Fonts/malgun.ttf",
    "C:/Windows/Fonts/NanumGothic.ttf",
]
for _f in _font_candidates:
    if _os.path.exists(_f):
        fm.fontManager.addfont(_f)
        plt.rcParams["font.family"] = fm.FontProperties(fname=_f).get_name()
        break
plt.rcParams["axes.unicode_minus"] = False

np.random.seed(42)

# ═══════════════════════════════════════════════
# 1. 가격 시뮬레이션 (2020~2025, 5년)
# ═══════════════════════════════════════════════
WAYPOINTS = [
    ("2020-01-01",  130), ("2020-03-13",   88), ("2021-01-01",  730),
    ("2021-05-12", 4150), ("2021-11-10", 4800), ("2022-06-18",  900),
    ("2022-11-09", 1150), ("2023-06-01", 1900), ("2024-03-12", 4000),
    ("2025-03-01", 2200),
]
dates_dt = pd.date_range("2020-01-01", "2025-03-01", freq="D")
N = len(dates_dt)
wp_d = [pd.Timestamp(w[0]) for w in WAYPOINTS]
wp_p = [w[1] for w in WAYPOINTS]

# 기저 가격 보간
from scipy import stats as sst
base = np.zeros(N)
for i, d in enumerate(dates_dt):
    idx = max(j for j, wd in enumerate(wp_d) if wd <= d)
    if idx < len(wp_d) - 1:
        t0, t1 = wp_d[idx], wp_d[idx+1]
        p0, p1 = wp_p[idx], wp_p[idx+1]
        r = (d - t0).days / max((t1 - t0).days, 1)
        base[i] = p0 * (p1 / p0) ** r
    else:
        base[i] = wp_p[-1]

# t-분포 노이즈
df_t = 4; scale = np.sqrt(df_t / (df_t - 2))
prices = base.copy()
for i in range(1, N):
    noise = sst.t.rvs(df=df_t) * 0.045 / scale
    jump  = (np.random.normal(-0.05, 0.12) if np.random.random() < 0.015 else 0.0)
    total = np.clip(noise + jump, -0.15, 0.15)
    prices[i] = (base[i] * (1 + total*0.3) + prices[i-1] * (1 + total*0.7)) / 2
    prices[i] = max(prices[i], 1.0)

# 주간 수익률 (에포크별 변동성 계산용)
weekly_ret = np.array([
    (prices[min(i+7, N-1)] - prices[i]) / prices[i]
    for i in range(0, N, 7)
])
n_epochs = len(weekly_ret)

# ═══════════════════════════════════════════════
# 2. LP 세그먼트 파라미터 (온체인 데이터 기반)
# ═══════════════════════════════════════════════
LP_SEGMENTS = {
    "institutional": {
        "tvl_share":    0.80,   # BIS Paper: 80% TVL
        "lp_share":     0.07,   # BIS Paper: 7% of LPs
        "il_multiplier": 2.8,   # narrow range → IL 증폭 2.8x vs full range
        "belta_adoption": 0.30, # BELTA 가입률 (추정)
        "avg_hold_days": 21,    # 평균 포지션 보유 21일 (리밸런싱 주기)
        "panic_sensitivity": 0.05,  # 패닉 이탈 거의 없음
        "entry_speed": 0.40,    # TVL의 40%가 첫 에포크 진입
        "color": "#c8a96e",
        "label": "기관/MM (7% LPs, 80% TVL)",
    },
    "active_retail": {
        "tvl_share":    0.15,
        "lp_share":     0.20,
        "il_multiplier": 1.5,
        "belta_adoption": 0.15,
        "avg_hold_days": 45,
        "panic_sensitivity": 0.20,
        "entry_speed": 0.25,
        "color": "#3498db",
        "label": "액티브 리테일 (20% LPs, 15% TVL)",
    },
    "passive_retail": {
        "tvl_share":    0.05,
        "lp_share":     0.73,
        "il_multiplier": 0.7,   # wide range → IL 감소
        "belta_adoption": 0.05,
        "avg_hold_days": 120,
        "panic_sensitivity": 0.40,
        "entry_speed": 0.10,
        "color": "#e74c3c",
        "label": "패시브 리테일 (73% LPs, 5% TVL)",
    },
}

# ═══════════════════════════════════════════════
# 3. 프로토콜 파라미터 (v4.3.0 기준)
# ═══════════════════════════════════════════════
COVERAGE_CAP  = 0.35
LP_FEE_MID    = 0.224
LP_RATE       = 0.12
PROTO_FEE     = 0.15
AAVE_APY      = 0.05
DAILY_LIMIT   = 0.05
EPOCH_DAYS    = 7

PHASES = [
    {"name": "Phase 1~2", "dual": False, "pool": 2_000_000,  "target_lp_tvl": 10_000_000,  "n_epochs": 130, "apy": 0.06},
    {"name": "Phase 3~4", "dual": True,  "pool": 10_000_000, "target_lp_tvl": 50_000_000,  "n_epochs": 130, "senior_apy": 0.07, "tr": 0.20},
]

# ═══════════════════════════════════════════════
# 4. 현실적 LP TVL 동학 함수
# ═══════════════════════════════════════════════
def compute_active_tvl(epoch, n_epochs, target_tvl, seg_params, weekly_rets):
    """
    각 LP 세그먼트의 에포크별 실제 활성 TVL 계산
    - 진입: logistic 성장 곡선
    - 이탈: 변동성 급등 시 패닉 exit
    - 기관: 하락 시 재진입 (contrarian)
    """
    seg_tvl = {}
    for seg_name, seg in seg_params.items():
        base_tvl = target_tvl * seg["tvl_share"] * seg["belta_adoption"]
        tvl_hist = np.zeros(n_epochs)
        current = 0.0

        for ep in range(n_epochs):
            # 진입 (logistic)
            t = ep / n_epochs
            growth = 1 / (1 + np.exp(-10 * (t - seg["entry_speed"])))
            target = base_tvl * growth

            # 패닉 이탈
            if ep < len(weekly_rets):
                ret = weekly_rets[ep]
                if ret < -0.10:  # 10% 이상 하락
                    panic = seg["panic_sensitivity"] * abs(ret) / 0.10
                    # 기관은 오히려 재진입
                    if seg_name == "institutional":
                        current *= (1 + 0.05 * abs(ret) / 0.10)
                    else:
                        current *= (1 - panic * 0.5)

            # 자연 이탈 (홀딩 주기 기반 churn)
            weekly_churn = EPOCH_DAYS / seg["avg_hold_days"]
            current = current * (1 - weekly_churn) + target * weekly_churn

            # 상한선
            current = min(current, base_tvl * 1.1)
            tvl_hist[ep] = max(current, 0)

        seg_tvl[seg_name] = tvl_hist
    return seg_tvl

# ═══════════════════════════════════════════════
# 5. 에포크별 IL 계산 (세그먼트별 IL 배율 적용)
# ═══════════════════════════════════════════════
def v2_il(r):
    """V2 IL: r = price_end / price_start"""
    if r <= 0: return 0.0
    return abs(2 * np.sqrt(r) / (1 + r) - 1)

def epoch_il_rate(ep, weekly_rets, seg_mult):
    """
    에포크 IL = V2_IL(주간 가격변동) × V3 range 배율
    - 기관/MM(narrow 2.8x): 범위 좁아 IL 증폭, 단 자주 리밸런싱
    - 액티브 리테일(1.5x): 중간 범위
    - 패시브 리테일(0.7x): 넓은 범위 → IL 완화
    """
    if ep >= len(weekly_rets):
        return v2_il(1.0) * seg_mult
    r = 1 + weekly_rets[ep]
    base = v2_il(max(r, 0.01))
    return min(base * seg_mult, 0.45)

# ═══════════════════════════════════════════════
# 6. 시뮬레이션 실행
# ═══════════════════════════════════════════════
def run_phase(phase_cfg, ep_offset=0):
    n_ep   = phase_cfg["n_epochs"]
    pool   = phase_cfg["pool"]
    target = phase_cfg["target_lp_tvl"]
    rets   = weekly_ret[ep_offset:ep_offset + n_ep]

    if phase_cfg["dual"]:
        treasury = pool * phase_cfg["tr"]
        senior   = pool * (1 - phase_cfg["tr"])
        s_apy    = phase_cfg["senior_apy"]
    else:
        treasury = pool
        senior   = 0.0
        s_apy    = phase_cfg["apy"]

    # 세그먼트별 TVL 동학
    seg_tvl = compute_active_tvl(
        ep_offset, n_ep, target, LP_SEGMENTS, rets
    )

    # 히스토리
    t_hist   = [treasury]
    s_hist   = [senior]
    tvl_hist = [0.0]

    metrics = {
        "total_prem": 0, "total_il": 0, "total_aave": 0,
        "total_belta": 0, "panic_events": 0,
    }

    for ep in range(n_ep):
        # 활성 TVL (세그먼트 합산)
        active_tvl = sum(seg_tvl[s][ep] for s in seg_tvl)
        tvl_hist.append(active_tvl)

        # 패닉 이벤트 감지
        if ep < len(rets) and rets[ep] < -0.10:
            metrics["panic_events"] += 1

        # IL 지급 계산 (세그먼트별 가중 평균 IL multiplier)
        total_il_ep = 0.0
        for seg_name, seg in LP_SEGMENTS.items():
            seg_tvl_ep = seg_tvl[seg_name][ep]
            il_rate = epoch_il_rate(ep, rets, seg["il_multiplier"])
            total_il_ep += seg_tvl_ep * il_rate * COVERAGE_CAP

        # 프리미엄 수입
        fee_gross = active_tvl * LP_FEE_MID * LP_RATE / (365 / EPOCH_DAYS)
        net_prem  = fee_gross * (1 - PROTO_FEE)
        belta_fee = fee_gross * PROTO_FEE

        # Aave yield
        aave_t = treasury * AAVE_APY * EPOCH_DAYS / 365
        aave_s = senior  * AAVE_APY * EPOCH_DAYS / 365 if phase_cfg["dual"] else 0

        # Senior 지급
        senior_pay = senior * s_apy * EPOCH_DAYS / 365 if phase_cfg["dual"] else 0

        # Daily limit cap
        payout = min(total_il_ep, (treasury + senior) * DAILY_LIMIT * EPOCH_DAYS)

        # Pool 업데이트
        metrics["total_prem"]  += net_prem
        metrics["total_il"]    += payout
        metrics["total_aave"]  += aave_t
        metrics["total_belta"] += belta_fee

        if phase_cfg["dual"]:
            treasury += net_prem + aave_t
            senior   += aave_s - senior_pay
            if payout <= treasury:
                treasury -= payout
            else:
                overflow  = payout - treasury
                treasury  = 0
                senior   -= overflow
            treasury = max(treasury, 0)
            senior   = max(senior,   0)
        else:
            treasury += net_prem + aave_t - payout
            treasury  = max(treasury, 0)

        t_hist.append(treasury)
        s_hist.append(senior)

    # 성과 계산
    years     = n_ep * EPOCH_DAYS / 365
    init_t    = phase_cfg["pool"] * (phase_cfg.get("tr", 1.0) if phase_cfg["dual"] else 1.0)
    final_t   = t_hist[-1]
    t_cagr    = (final_t / max(init_t, 1)) ** (1 / max(years, 0.1)) - 1

    t_arr = np.array(t_hist)
    peak  = np.maximum.accumulate(t_arr)
    mdd   = ((t_arr - peak) / np.maximum(peak, 1)).min() * 100

    avg_tvl   = np.mean(tvl_hist[1:])
    loss_ratio = metrics["total_il"] / max(metrics["total_prem"] + metrics["total_aave"], 1)

    return {
        "name":        phase_cfg["name"],
        "t_cagr":      t_cagr * 100,
        "s_apy":       s_apy * 100,
        "mdd":         mdd,
        "loss_ratio":  loss_ratio,
        "avg_tvl":     avg_tvl,
        "target_tvl":  target,
        "tvl_util":    avg_tvl / target * 100,  # TVL 달성률
        "panic_events":metrics["panic_events"],
        "total_il":    metrics["total_il"],
        "total_prem":  metrics["total_prem"],
        "belta_income":metrics["total_belta"],
        "t_hist":      t_hist,
        "s_hist":      s_hist,
        "tvl_hist":    tvl_hist,
        "seg_tvl":     seg_tvl,
    }

# ═══════════════════════════════════════════════
# 7. 결과 출력
# ═══════════════════════════════════════════════
results = []
ep_off  = 0
for ph in PHASES:
    r = run_phase(ph, ep_off)
    results.append(r)
    ep_off += ph["n_epochs"]

print("=" * 75)
print("  BELTA Multi-LP Cohort Backtest v4.4.0")
print("  (실제 온체인 LP 행동 패턴 반영, 2020~2025)")
print("=" * 75)
print()
print("【 LP 세그먼트 구성 (BIS/Uniswap Labs 실측 기반) 】")
print(f"  {'세그먼트':<18} {'LP 비중':>8} {'TVL 비중':>8} {'BELTA 가입률':>12} {'평균보유일':>10}")
print(f"  {'-'*60}")
for sn, sp in LP_SEGMENTS.items():
    print(f"  {sp['label'][:18]:<18} {sp['lp_share']*100:>7.0f}% {sp['tvl_share']*100:>7.0f}%"
          f" {sp['belta_adoption']*100:>11.0f}% {sp['avg_hold_days']:>9}일")

print()
print("【 Phase별 성과 】")
print(f"  {'Phase':<12} {'T-CAGR':>8} {'Pool-MDD':>10} {'S-APY':>8} {'IL비율':>8} "
      f"{'TVL달성율':>10} {'패닉횟수':>8} {'BELTA수입':>12}")
print(f"  {'-'*80}")
for r in results:
    print(f"  {r['name']:<12} {r['t_cagr']:>+7.1f}% {r['mdd']:>+9.1f}% "
          f"{r['s_apy']:>7.1f}% {r['loss_ratio']:>7.2f}x "
          f"{r['tvl_util']:>9.1f}% {r['panic_events']:>7}회 "
          f"${r['belta_income']:>10,.0f}")

print()
print("【 단일 주체 모델 vs 멀티 코호트 모델 비교 】")
print(f"  {'항목':<22} {'단일 주체 (v4.3.0)':>18} {'멀티 코호트 (v4.4.0)':>18} {'차이':>10}")
print(f"  {'-'*70}")
comparisons = [
    ("Phase 1~2 T-CAGR",   "+9.2%",  f"{results[0]['t_cagr']:+.1f}%",  ""),
    ("Phase 3~4 T-CAGR",  "+20.9%",  f"{results[1]['t_cagr']:+.1f}%",  ""),
    ("IL/수입 비율",         "0.60x",  f"{results[0]['loss_ratio']:.2f}x", ""),
    ("TVL 달성률",          "100%",   f"{results[0]['tvl_util']:.1f}%",  "← 핵심 차이"),
    ("패닉 이탈 반영",        "없음",   "있음",                            "← 신규 추가"),
    ("기관 재진입 반영",      "없음",   "있음",                            "← 신규 추가"),
]
for row in comparisons:
    print(f"  {row[0]:<22} {row[1]:>18} {row[2]:>18} {row[3]:>10}")

# ═══════════════════════════════════════════════
# 8. 시각화
# ═══════════════════════════════════════════════
fig = plt.figure(figsize=(16, 18))
fig.suptitle("BELTA Multi-LP Cohort Model (v4.4.0)\n실제 LP 행동 패턴 반영 -BIS/Uniswap Labs 온체인 데이터 기반",
             fontsize=13, fontweight="bold", y=0.98)

gs = fig.add_gridspec(4, 2, hspace=0.45, wspace=0.35)

# ─── (A) LP 세그먼트 구성 파이차트 ───────────────
ax_pie1 = fig.add_subplot(gs[0, 0])
ax_pie2 = fig.add_subplot(gs[0, 1])

seg_labels = ["기관/MM", "액티브\n리테일", "패시브\n리테일"]
colors_pie  = ["#c8a96e", "#3498db", "#e74c3c"]

lp_shares  = [0.07, 0.20, 0.73]
tvl_shares = [0.80, 0.15, 0.05]

ax_pie1.pie(lp_shares,  labels=seg_labels, colors=colors_pie, autopct="%1.0f%%", startangle=90,
            wedgeprops={"edgecolor":"white","linewidth":1.5})
ax_pie1.set_title("LP 수 비중 (7/20/73%)\n출처: BIS Working Paper 1227", fontsize=9)

ax_pie2.pie(tvl_shares, labels=seg_labels, colors=colors_pie, autopct="%1.0f%%", startangle=90,
            wedgeprops={"edgecolor":"white","linewidth":1.5})
ax_pie2.set_title("TVL 비중 (80/15/5%)\n출처: BIS Working Paper 1227", fontsize=9)

# ─── (B) Phase 1~2 세그먼트별 TVL 동학 ───────────
ax_tvl1 = fig.add_subplot(gs[1, 0])
r1 = results[0]
n1 = len(r1["tvl_hist"]) - 1
ax_tvl1.stackplot(range(n1),
    [r1["seg_tvl"]["institutional"][:n1],
     r1["seg_tvl"]["active_retail"][:n1],
     r1["seg_tvl"]["passive_retail"][:n1]],
    labels=["기관/MM", "액티브 리테일", "패시브 리테일"],
    colors=["#c8a96e","#3498db","#e74c3c"], alpha=0.8)
ax_tvl1.axhline(PHASES[0]["target_lp_tvl"] * sum(
    LP_SEGMENTS[s]["tvl_share"] * LP_SEGMENTS[s]["belta_adoption"]
    for s in LP_SEGMENTS), color="black", linestyle="--", linewidth=1, label="BELTA 잠재 TVL")
ax_tvl1.set_title("Phase 1~2 | 세그먼트별 BELTA 가입 TVL 동학", fontsize=10)
ax_tvl1.set_ylabel("활성 TVL ($)")
ax_tvl1.legend(fontsize=8, loc="upper left")
ax_tvl1.grid(True, alpha=0.3)
ax_tvl1.yaxis.set_major_formatter(
    plt.FuncFormatter(lambda x, _: f"${x/1e6:.1f}M"))

# ─── (C) Phase 3~4 세그먼트별 TVL 동학 ───────────
ax_tvl2 = fig.add_subplot(gs[1, 1])
r2 = results[1]
n2 = len(r2["tvl_hist"]) - 1
ax_tvl2.stackplot(range(n2+1),
    [list(r2["seg_tvl"]["institutional"][:n2]) + [0],
     list(r2["seg_tvl"]["active_retail"][:n2]) + [0],
     list(r2["seg_tvl"]["passive_retail"][:n2]) + [0]],
    labels=["기관/MM", "액티브 리테일", "패시브 리테일"],
    colors=["#c8a96e","#3498db","#e74c3c"], alpha=0.8)
ax_tvl2.set_title("Phase 3~4 | 세그먼트별 BELTA 가입 TVL 동학", fontsize=10)
ax_tvl2.set_ylabel("활성 TVL ($)")
ax_tvl2.legend(fontsize=8, loc="upper left")
ax_tvl2.grid(True, alpha=0.3)
ax_tvl2.yaxis.set_major_formatter(
    plt.FuncFormatter(lambda x, _: f"${x/1e6:.1f}M"))

# ─── (D) ETH 가격 + 패닉 이탈 이벤트 ─────────────
ax_eth = fig.add_subplot(gs[2, 0])
ep_prices = prices[::7][:n_epochs]
ax_eth.plot(ep_prices, color="#c8a96e", linewidth=1.5, label="ETH 가격")
# 패닉 구간 강조
for ep, ret in enumerate(weekly_ret[:n_epochs]):
    if ret < -0.10:
        ax_eth.axvspan(ep, ep+1, color="red", alpha=0.25)
ax_eth.set_title("ETH 가격 및 패닉 이탈 구간 (빨간색)", fontsize=10)
ax_eth.set_ylabel("ETH Price ($)")
ax_eth.legend(fontsize=8)
ax_eth.grid(True, alpha=0.3)
panic_patch = mpatches.Patch(color="red", alpha=0.3, label=f"패닉 구간 (−10%+)")
ax_eth.legend(handles=[panic_patch], fontsize=8)

# ─── (E) Pool 잔액 변동 (단일 vs 멀티) ───────────
ax_pool = fig.add_subplot(gs[2, 1])

# 단일 모델 재실행 (비교용)
def run_single_model(phase_cfg, ep_offset=0):
    n_ep = phase_cfg["n_epochs"]
    pool = phase_cfg["pool"]
    lp_tvl = phase_cfg["target_lp_tvl"]
    rets = weekly_ret[ep_offset:ep_offset + n_ep]
    treasury = pool * (phase_cfg.get("tr", 1.0) if phase_cfg["dual"] else 1.0)
    senior   = pool * (1 - phase_cfg.get("tr", 1.0)) if phase_cfg["dual"] else 0.0
    s_apy    = phase_cfg.get("senior_apy", phase_cfg.get("apy", 0.06))
    t_hist   = [treasury]
    for ep in range(n_ep):
        il_ep   = max(0, abs(rets[ep]) if ep < len(rets) else 0.02) * 0.5
        fee_ep  = lp_tvl * LP_FEE_MID * LP_RATE / (365/7)
        net_ep  = fee_ep * (1 - PROTO_FEE)
        aave_t  = treasury * AAVE_APY * 7/365
        aave_s  = senior   * AAVE_APY * 7/365 if phase_cfg["dual"] else 0
        s_pay   = senior   * s_apy    * 7/365 if phase_cfg["dual"] else 0
        payout  = min(lp_tvl * il_ep * COVERAGE_CAP,
                      (treasury+senior) * DAILY_LIMIT * 7)
        if phase_cfg["dual"]:
            treasury += net_ep + aave_t
            senior   += aave_s - s_pay
            if payout <= treasury: treasury -= payout
            else: senior -= (payout-treasury); treasury = 0
        else:
            treasury += net_ep + aave_t - payout
        treasury = max(treasury, 0); senior = max(senior, 0)
        t_hist.append(treasury)
    return t_hist

single_t = []
ep_off = 0
for ph in PHASES:
    h = run_single_model(ph, ep_off)
    single_t.extend(h)
    ep_off += ph["n_epochs"]

multi_t = results[0]["t_hist"] + results[1]["t_hist"][1:]
ax_pool.plot(np.array(single_t)/1e6, color="#95a5a6", linewidth=1.5,
             linestyle="--", label="단일 주체 모델 (v4.3.0)")
ax_pool.plot(np.array(multi_t)/1e6,  color="#27ae60", linewidth=2,
             label="멀티 코호트 모델 (v4.4.0)")
# Phase 경계
ax_pool.axvline(PHASES[0]["n_epochs"], color="black", linestyle=":", alpha=0.5)
ax_pool.set_title("Treasury Pool 잔액 비교 (단일 vs 멀티)", fontsize=10)
ax_pool.set_ylabel("Treasury ($M)")
ax_pool.legend(fontsize=8)
ax_pool.grid(True, alpha=0.3)

# ─── (F) 핵심 차이 요약 표 ────────────────────────
ax_tbl = fig.add_subplot(gs[3, :])
ax_tbl.axis("off")

table_data = [
    ["항목", "단일 주체 모델", "멀티 코호트 모델", "현실 반영 근거"],
    ["LP TVL 진입", "t=0에 전량 진입", "코호트별 성장 곡선", "신규 프로토콜 TVL 성장 패턴"],
    ["기관 LP 비중", "미구분", "7% LPs → 80% TVL", "BIS Working Paper 1227"],
    ["패닉 이탈", "없음", "−10%+ 하락 시 리테일 이탈", "온체인 mint/burn 이벤트 분석"],
    ["기관 재진입", "없음", "하락 시 contrarian 매수", "Market maker 행동 패턴"],
    ["IL 배율", "단일 (1x)", "기관 2.8x / 리테일 0.7x", "narrow vs wide range IL 차이"],
    ["Phase 1~2 TVL 달성률", "100% (가정)", f"{results[0]['tvl_util']:.0f}%", "현실적 초기 채택률 반영"],
    ["Phase 3~4 TVL 달성률", "100% (가정)", f"{results[1]['tvl_util']:.0f}%", "성장 후 높은 채택률"],
]

tbl = ax_tbl.table(
    cellText=table_data[1:],
    colLabels=table_data[0],
    loc="center",
    cellLoc="center",
)
tbl.auto_set_font_size(False)
tbl.set_fontsize(8.5)
tbl.scale(1, 1.5)
for (row, col), cell in tbl.get_celld().items():
    if row == 0:
        cell.set_facecolor("#1a2a4a")
        cell.set_text_props(color="white", fontweight="bold")
    elif row % 2 == 0:
        cell.set_facecolor("#f5f5f5")
    if col == 3:
        cell.set_text_props(color="#666", style="italic")

ax_tbl.set_title("단일 주체 모델 vs 멀티 코호트 모델 -핵심 차이", fontsize=11, fontweight="bold", pad=12)

out_dir = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "results")
_os.makedirs(out_dir, exist_ok=True)
out = _os.path.join(out_dir, "backtest_v440_multi_lp.png")
plt.savefig(out, dpi=150, bbox_inches="tight")
plt.close()
print(f"\nchart saved: {out}")
