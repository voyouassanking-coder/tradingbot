#!/usr/bin/env python3
"""Backtest Python replicant la logique CORRIGEE de SOSFinancial_PRO.mq5
   sur des donnees M15 BTCUSDm.

   Strategie :
     - D1 filtre tendance : EMA21>EMA50>EMA200, prix>EMA200, RSI>55, ADX>20
     - H4 confirmation    : EMA21>EMA50, prix>Kinjun, RSI>52, ADX>15
     - H1 signal entree   : EMA21>EMA50, prix>Kinjun, prix>EMA21, RSI>50
     - Filtres PRO        : volume (tickvol H1 actuel >= moyenne 4 precedentes),
                            Heiken Ashi color H1, Fibonacci OFF par defaut
     - Risque 1%, SL = ATR(H1) * 1.0, TP = SL * 1.5
     - Partial close 50% a +150 USD, BE a +150 USD avec offset 5 USD
     - Spread max 30 USD (BTC), session 8-21 broker, cooldown 300s
     - Daily DD 20%

   Corrections appliquees vs EA original :
     - Symbole BTCUSDm accepte
     - Spread / Partial / BE en USD (pas en pips Forex)
     - Indicateurs lus sur barre fermee (shift=1)
     - Kinjun(26) sur barre fermee
     - Heiken Ashi avec formule recursive standard
     - Pas de filling FOK code en dur
     - Stats win/loss par trade (pas par deal)
"""
import argparse
import os
import sys
import json
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.dates as mdates


# ============================================================
# Parametres (defauts EA, convertis en USD pour BTC)
# ============================================================
INITIAL_BALANCE     = 10_000.0
RISK_PCT            = 1.0
RR                  = 1.5
ATR_SL_MULT         = 1.0

PARTIAL_USD         = 150.0     # ex InpPartialPips=150 -> 150 USD distance prix
PARTIAL_RATIO       = 0.5
BE_OFFSET_USD       = 5.0       # ex InpBreakEvenPips=5 -> 5 USD au-dela du BE
USE_PARTIAL         = True
USE_BE              = True

MAX_SPREAD_USD      = 30.0      # ex InpMaxSpreadPips=30 -> 30 USD
COOLDOWN_SEC        = 300
SESSION_START_H     = 8
SESSION_END_H       = 21
SKIP_WEEKEND        = False     # BTC trade 24/7 chez la plupart des brokers
SKIP_FRIDAY_LATE    = False     # idem

USE_VOLUME_FILTER   = True
USE_HA_FILTER       = True
USE_FIB_FILTER      = False     # OFF par defaut dans l'EA

# Seuils
D1_RSI_UP, D1_RSI_DN = 55.0, 45.0
D1_ADX_MIN           = 20.0
H4_RSI_UP, H4_RSI_DN = 52.0, 48.0
H4_ADX_MIN           = 15.0
H1_RSI_BUY, H1_RSI_SELL = 50.0, 50.0

# Indicateurs
EMA21_P, EMA50_P, EMA200_P = 21, 50, 200
RSI_P, ADX_P, ATR_P, KINJUN_P = 21, 14, 14, 26

MAX_DD_PCT           = 20.0

# Contrat BTC standard : 1 lot = 1 BTC -> P&L par lot par USD de move = 1 USD
CONTRACT_SIZE_PER_LOT = 1.0
VOLUME_MIN            = 0.01
VOLUME_STEP           = 0.01


# ============================================================
# Indicateurs
# ============================================================
def ema(s, n):
    return s.ewm(span=n, adjust=False).mean()

def wilder(s, n):
    # Wilder smoothing = EMA avec alpha = 1/n
    return s.ewm(alpha=1.0/n, adjust=False).mean()

def rsi(close, n=21):
    delta = close.diff()
    gain = delta.clip(lower=0)
    loss = -delta.clip(upper=0)
    avg_gain = wilder(gain, n)
    avg_loss = wilder(loss, n)
    rs = avg_gain / avg_loss.replace(0, np.nan)
    return (100 - 100 / (1 + rs)).fillna(50)

def true_range(high, low, close):
    prev_close = close.shift(1)
    return pd.concat([
        (high - low),
        (high - prev_close).abs(),
        (low - prev_close).abs()
    ], axis=1).max(axis=1)

def atr(high, low, close, n=14):
    return wilder(true_range(high, low, close), n)

def adx(high, low, close, n=14):
    up = high.diff()
    down = -low.diff()
    plus_dm  = pd.Series(np.where((up > down) & (up > 0), up, 0.0), index=high.index)
    minus_dm = pd.Series(np.where((down > up) & (down > 0), down, 0.0), index=high.index)
    tr = true_range(high, low, close)
    atr_v = wilder(tr, n).replace(0, np.nan)
    plus_di  = 100 * wilder(plus_dm, n) / atr_v
    minus_di = 100 * wilder(minus_dm, n) / atr_v
    dx = (100 * (plus_di - minus_di).abs() / (plus_di + minus_di)).fillna(0)
    return wilder(dx, n).fillna(0)

def kinjun(high, low, n=26):
    return (high.rolling(n).max() + low.rolling(n).min()) / 2.0

def heiken_ashi(o, h, l, c):
    ha_close = (o + h + l + c) / 4.0
    ha_open = np.empty(len(o))
    ha_open[0] = (o.iloc[0] + c.iloc[0]) / 2.0
    closes = ha_close.values
    for i in range(1, len(o)):
        ha_open[i] = (ha_open[i-1] + closes[i-1]) / 2.0
    return pd.Series(ha_open, index=o.index), ha_close


# ============================================================
# Chargement et resampling
# ============================================================
def load_m15(path):
    print(f"[load] Chargement {os.path.basename(path)} ...")
    df = pd.read_csv(path, parse_dates=["datetime"])
    df = df.set_index("datetime").sort_index()
    df = df[~df.index.duplicated(keep="first")]
    # Conversion spread points -> USD (BTC : 1 point = 0.01 USD)
    df["spread_usd"] = df["spread"] * 0.01
    print(f"        {len(df):,} bougies M15  {df.index[0]} -> {df.index[-1]}")
    return df

def resample_ohlc(df, rule):
    out = df.resample(rule, label="right", closed="right").agg({
        "open": "first", "high": "max", "low": "min", "close": "last",
        "tick_volume": "sum", "spread": "mean", "spread_usd": "mean"
    }).dropna()
    return out

def compute_indicators(df, label):
    df["ema21"]  = ema(df["close"], EMA21_P)
    df["ema50"]  = ema(df["close"], EMA50_P)
    df["ema200"] = ema(df["close"], EMA200_P)
    df["rsi"]    = rsi(df["close"], RSI_P)
    df["adx"]    = adx(df["high"], df["low"], df["close"], ADX_P)
    df["atr"]    = atr(df["high"], df["low"], df["close"], ATR_P)
    df["kinjun"] = kinjun(df["high"], df["low"], KINJUN_P)
    print(f"[indi] {label} : ATR moyen={df['atr'].mean():.2f} USD")
    return df


# ============================================================
# Helpers de logique strategique (utilisent shift=1 = barre fermee)
# ============================================================
def d1_trend(d1_row):
    if pd.isna(d1_row["ema200"]) or pd.isna(d1_row["adx"]):
        return 0
    ema21, ema50, ema200 = d1_row["ema21"], d1_row["ema50"], d1_row["ema200"]
    price, r, a = d1_row["close"], d1_row["rsi"], d1_row["adx"]
    if ema21 > ema50 > ema200 and price > ema200 and r > D1_RSI_UP and a > D1_ADX_MIN:
        return 1
    if ema21 < ema50 < ema200 and price < ema200 and r < D1_RSI_DN and a > D1_ADX_MIN:
        return -1
    return 0

def h4_trend(h4_row):
    if pd.isna(h4_row["ema50"]) or pd.isna(h4_row["adx"]) or pd.isna(h4_row["kinjun"]):
        return 0
    ema21, ema50, k = h4_row["ema21"], h4_row["ema50"], h4_row["kinjun"]
    price, r, a = h4_row["close"], h4_row["rsi"], h4_row["adx"]
    if ema21 > ema50 and price > k and r > H4_RSI_UP and a > H4_ADX_MIN:
        return 1
    if ema21 < ema50 and price < k and r < H4_RSI_DN and a > H4_ADX_MIN:
        return -1
    return 0

def h1_signal(h1_row):
    if pd.isna(h1_row["ema50"]) or pd.isna(h1_row["kinjun"]):
        return 0
    ema21, ema50, k = h1_row["ema21"], h1_row["ema50"], h1_row["kinjun"]
    price, r = h1_row["close"], h1_row["rsi"]
    if ema21 > ema50 and price > k and price > ema21 and r > H1_RSI_BUY:
        return 1
    if ema21 < ema50 and price < k and price < ema21 and r < H1_RSI_SELL:
        return -1
    return 0

def volume_ok(h1_row):
    if not USE_VOLUME_FILTER:
        return True
    if pd.isna(h1_row["vol_avg4"]):
        return True
    return h1_row["tick_volume"] >= h1_row["vol_avg4"]

def ha_ok(direction, h1_row):
    if not USE_HA_FILTER:
        return True
    if pd.isna(h1_row["ha_open"]) or pd.isna(h1_row["ha_close"]):
        return True
    bullish = h1_row["ha_close"] > h1_row["ha_open"]
    return bullish if direction > 0 else (not bullish)

def session_ok(ts):
    if SKIP_WEEKEND and ts.weekday() >= 5:
        return False
    if SKIP_FRIDAY_LATE and ts.weekday() == 4 and ts.hour >= 17:
        return False
    return SESSION_START_H <= ts.hour < SESSION_END_H


# ============================================================
# Lot sizing
# ============================================================
def calc_lots(balance, sl_distance_usd):
    if sl_distance_usd <= 0:
        return 0.0
    risk_money = balance * RISK_PCT / 100.0
    raw = risk_money / (sl_distance_usd * CONTRACT_SIZE_PER_LOT)
    # Arrondi au pas inferieur
    lots = np.floor(raw / VOLUME_STEP) * VOLUME_STEP
    if lots < VOLUME_MIN:
        lots = VOLUME_MIN
    return round(lots, 2)


# ============================================================
# Backtest
# ============================================================
def run_backtest(m15_path, out_dir):
    m15 = load_m15(m15_path)

    print("[resample] H1 / H4 / D1 depuis M15 ...")
    h1 = resample_ohlc(m15, "1h")
    h4 = resample_ohlc(m15, "4h")
    d1 = resample_ohlc(m15, "1D")

    d1 = compute_indicators(d1, "D1")
    h4 = compute_indicators(h4, "H4")
    h1 = compute_indicators(h1, "H1")

    # Heiken Ashi sur H1
    h1["ha_open"], h1["ha_close"] = heiken_ashi(h1["open"], h1["high"], h1["low"], h1["close"])

    # Volume moyenne 4 precedentes (donc shift=1 deja inclus via rolling)
    h1["vol_avg4"] = h1["tick_volume"].shift(1).rolling(4).mean()

    # Precalcul des biais sur barre FERMEE (shift=1) — ie. on regarde la barre N-1
    d1_trend_arr = d1.apply(d1_trend, axis=1).shift(1).reindex(m15.index, method="ffill")
    h4_trend_arr = h4.apply(h4_trend, axis=1).shift(1).reindex(m15.index, method="ffill")
    h1_signal_arr = h1.apply(h1_signal, axis=1).shift(1).reindex(m15.index, method="ffill")

    h1_atr_arr = h1["atr"].shift(1).reindex(m15.index, method="ffill")
    h1_volok   = h1.apply(volume_ok, axis=1).shift(1).reindex(m15.index, method="ffill")
    # Pour HA, on calcule dans la boucle car depend du sens

    # Etat
    balance = INITIAL_BALANCE
    equity_curve = []
    equity_dates = []
    trades = []     # liste de dict
    daily_anchor_date = None
    daily_anchor_balance = balance
    daily_locked = False

    position = None  # dict si ouvert
    cooldown_until = None

    bar_count = 0
    n_bars = len(m15)

    for ts, bar in m15.iterrows():
        bar_count += 1
        # Daily DD reset
        if daily_anchor_date != ts.date():
            daily_anchor_date = ts.date()
            daily_anchor_balance = balance
            daily_locked = False

        # ====== Gestion position ouverte ======
        if position is not None:
            high, low = bar["high"], bar["low"]
            is_buy = position["dir"] > 0

            # Detecter hit SL et TP dans cette bougie M15
            # Convention pessimiste : si SL et TP touches dans meme bar, on assume SL d'abord
            sl_hit = (low <= position["sl"]) if is_buy else (high >= position["sl"])
            tp_hit = (high >= position["tp"]) if is_buy else (low <= position["tp"])

            # Excursion favorable pour partial / BE
            favorable = (high - position["entry"]) if is_buy else (position["entry"] - low)

            # 1) Partial close (si pas encore fait)
            if USE_PARTIAL and not position["partial_done"] and favorable >= PARTIAL_USD:
                close_vol = max(VOLUME_MIN, np.floor(position["lots"] * PARTIAL_RATIO / VOLUME_STEP) * VOLUME_STEP)
                close_vol = round(close_vol, 2)
                if close_vol < position["lots"]:
                    # P&L de la partial : on assume execution au prix d'entree + PARTIAL_USD (favorable atteint)
                    partial_price = position["entry"] + (PARTIAL_USD if is_buy else -PARTIAL_USD)
                    pnl = (partial_price - position["entry"]) * close_vol * CONTRACT_SIZE_PER_LOT
                    if not is_buy:
                        pnl = -pnl
                    # Spread est paye une seule fois (round trip / 2 pour fraction fermee)
                    pnl -= position["entry_spread"] * close_vol * (close_vol / position["lots"])
                    balance += pnl
                    position["lots"] -= close_vol
                    position["partial_pnl"] = pnl
                    position["partial_done"] = True
                    # BE arme
                    if USE_BE:
                        be_sl = position["entry"] + (BE_OFFSET_USD if is_buy else -BE_OFFSET_USD)
                        position["sl"] = be_sl

            # 2) Si SL hit (apres eventuelle modif BE)
            sl_hit = (low <= position["sl"]) if is_buy else (high >= position["sl"])
            tp_hit = (high >= position["tp"]) if is_buy else (low <= position["tp"])

            exit_price = None
            exit_reason = None
            if sl_hit and tp_hit:
                # Pessimiste : SL d'abord
                exit_price = position["sl"]
                exit_reason = "SL"
            elif sl_hit:
                exit_price = position["sl"]
                exit_reason = "SL"
            elif tp_hit:
                exit_price = position["tp"]
                exit_reason = "TP"

            if exit_price is not None:
                pnl_main = (exit_price - position["entry"]) * position["lots"] * CONTRACT_SIZE_PER_LOT
                if not is_buy:
                    pnl_main = -pnl_main
                # Spread aller-retour deja paye partiellement a l'entree, on paie le restant a la sortie
                pnl_main -= position["entry_spread"] * position["lots"]
                balance += pnl_main

                total_pnl = pnl_main + position.get("partial_pnl", 0.0)
                trades.append({
                    "open_time": position["open_time"],
                    "close_time": ts,
                    "direction": "BUY" if is_buy else "SELL",
                    "entry": position["entry"],
                    "exit": exit_price,
                    "lots": position["initial_lots"],
                    "pnl": total_pnl,
                    "reason": exit_reason,
                    "had_partial": position["partial_done"],
                    "balance_after": balance,
                })
                position = None
                cooldown_until = ts + pd.Timedelta(seconds=COOLDOWN_SEC)

        # Equity = balance (positions valorisees a la cloture, simplification)
        equity_curve.append(balance)
        equity_dates.append(ts)

        if position is None and not daily_locked:
            # ====== Verifie filtres et signal ======
            if cooldown_until is not None and ts < cooldown_until:
                continue
            if not session_ok(ts):
                continue
            if pd.isna(h1_atr_arr.loc[ts]) or h1_atr_arr.loc[ts] <= 0:
                continue
            if bar["spread_usd"] > MAX_SPREAD_USD:
                continue

            # Daily DD check
            dd_pct = (daily_anchor_balance - balance) / daily_anchor_balance * 100.0
            if dd_pct >= MAX_DD_PCT:
                daily_locked = True
                continue

            d1t = d1_trend_arr.loc[ts]
            h4t = h4_trend_arr.loc[ts]
            h1s = h1_signal_arr.loc[ts]
            if pd.isna(d1t) or pd.isna(h4t) or pd.isna(h1s):
                continue
            d1t, h4t, h1s = int(d1t), int(h4t), int(h1s)

            direction = 0
            if d1t == 1 and h4t == 1 and h1s == 1:
                direction = 1
            elif d1t == -1 and h4t == -1 and h1s == -1:
                direction = -1
            if direction == 0:
                continue

            # Filtres PRO
            if not h1_volok.loc[ts]:
                continue
            # HA filter : trouver dernier H1 row <= ts
            h1_idx = h1.index.searchsorted(ts, side="right") - 1
            if h1_idx > 0:
                h1_row = h1.iloc[h1_idx - 1]  # shift=1
                if not ha_ok(direction, h1_row):
                    continue

            # Entree
            atr_h1 = h1_atr_arr.loc[ts]
            sl_dist = atr_h1 * ATR_SL_MULT
            if sl_dist < 10:
                continue
            entry = bar["close"]  # close de la bougie M15 courante
            sl = entry - sl_dist if direction > 0 else entry + sl_dist
            tp = entry + sl_dist * RR if direction > 0 else entry - sl_dist * RR
            lots = calc_lots(balance, sl_dist)
            if lots < VOLUME_MIN:
                continue

            position = {
                "open_time": ts,
                "dir": direction,
                "entry": entry,
                "sl": sl,
                "tp": tp,
                "lots": lots,
                "initial_lots": lots,
                "entry_spread": bar["spread_usd"],
                "partial_done": False,
                "partial_pnl": 0.0,
            }

    print(f"[done] {bar_count:,} bougies parcourues, {len(trades)} trades")

    # ============================================================
    # Metriques
    # ============================================================
    eq = pd.Series(equity_curve, index=pd.DatetimeIndex(equity_dates))
    eq_max = eq.cummax()
    dd = (eq - eq_max) / eq_max * 100.0
    max_dd_pct = -dd.min() if len(dd) else 0.0
    max_dd_usd = (eq_max - eq).max()

    final_balance = balance
    net_profit = final_balance - INITIAL_BALANCE
    pct_return = net_profit / INITIAL_BALANCE * 100.0

    pnls = pd.Series([t["pnl"] for t in trades])
    n_trades = len(pnls)
    n_wins = int((pnls > 0).sum())
    n_losses = int((pnls < 0).sum())
    win_rate = (n_wins / n_trades * 100.0) if n_trades else 0.0
    gross_profit = pnls[pnls > 0].sum() if n_trades else 0.0
    gross_loss   = -pnls[pnls < 0].sum() if n_trades else 0.0
    profit_factor = (gross_profit / gross_loss) if gross_loss > 0 else float("inf") if gross_profit > 0 else 0.0
    avg_win = pnls[pnls > 0].mean() if n_wins else 0.0
    avg_loss = pnls[pnls < 0].mean() if n_losses else 0.0
    expectancy = pnls.mean() if n_trades else 0.0

    n_buys = sum(1 for t in trades if t["direction"] == "BUY")
    n_sells = sum(1 for t in trades if t["direction"] == "SELL")
    by_reason = {}
    for t in trades:
        by_reason[t["reason"]] = by_reason.get(t["reason"], 0) + 1

    metrics = {
        "period_start": str(eq.index[0]) if len(eq) else None,
        "period_end": str(eq.index[-1]) if len(eq) else None,
        "initial_balance": INITIAL_BALANCE,
        "final_balance": round(final_balance, 2),
        "net_profit_usd": round(net_profit, 2),
        "return_pct": round(pct_return, 2),
        "trades": n_trades,
        "buys": n_buys,
        "sells": n_sells,
        "wins": n_wins,
        "losses": n_losses,
        "win_rate_pct": round(win_rate, 2),
        "gross_profit": round(gross_profit, 2),
        "gross_loss": round(gross_loss, 2),
        "profit_factor": round(profit_factor, 3) if profit_factor != float("inf") else "inf",
        "avg_win": round(avg_win, 2),
        "avg_loss": round(avg_loss, 2),
        "expectancy_per_trade": round(expectancy, 2),
        "max_drawdown_pct": round(max_dd_pct, 2),
        "max_drawdown_usd": round(max_dd_usd, 2),
        "exits_by_reason": by_reason,
    }

    # ============================================================
    # Sauvegarde
    # ============================================================
    os.makedirs(out_dir, exist_ok=True)
    metrics_path = os.path.join(out_dir, "metrics.json")
    with open(metrics_path, "w") as f:
        json.dump(metrics, f, indent=2, default=str)

    trades_df = pd.DataFrame(trades)
    if len(trades_df):
        trades_df.to_csv(os.path.join(out_dir, "trades.csv"), index=False)

    # Plot equity curve
    fig, axes = plt.subplots(2, 1, figsize=(12, 7), sharex=True,
                             gridspec_kw={"height_ratios": [3, 1]})
    axes[0].plot(eq.index, eq.values, linewidth=1.2, color="#1f77b4", label="Equity")
    axes[0].axhline(INITIAL_BALANCE, color="grey", linewidth=0.8, linestyle="--", label="Solde initial")
    axes[0].set_title(f"SOSFinancial PRO (corrige) — BTCUSDm — {eq.index[0].date()} -> {eq.index[-1].date()}",
                       fontsize=12, fontweight="bold")
    axes[0].set_ylabel("Equity (USD)")
    axes[0].legend(loc="upper left")
    axes[0].grid(True, alpha=0.3)

    axes[1].fill_between(eq.index, dd.values, 0, color="#d62728", alpha=0.5)
    axes[1].set_ylabel("Drawdown (%)")
    axes[1].set_xlabel("Date")
    axes[1].grid(True, alpha=0.3)
    axes[1].xaxis.set_major_locator(mdates.MonthLocator(interval=3))
    axes[1].xaxis.set_major_formatter(mdates.DateFormatter("%Y-%m"))

    # Annotation metriques
    txt = (
        f"Net profit: {net_profit:+,.2f} USD ({pct_return:+.2f}%)\n"
        f"Trades: {n_trades}  (W:{n_wins} / L:{n_losses}  WR:{win_rate:.1f}%)\n"
        f"Profit factor: {metrics['profit_factor']}\n"
        f"Max DD: -{max_dd_pct:.2f}%  ({max_dd_usd:,.2f} USD)"
    )
    axes[0].text(0.99, 0.02, txt, transform=axes[0].transAxes,
                 ha="right", va="bottom", fontsize=9, family="monospace",
                 bbox=dict(boxstyle="round,pad=0.4", facecolor="white", alpha=0.85, edgecolor="grey"))

    fig.tight_layout()
    eq_path = os.path.join(out_dir, "equity_curve.png")
    fig.savefig(eq_path, dpi=130)
    plt.close(fig)

    return metrics, eq_path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--m15", required=True, help="Chemin CSV M15")
    parser.add_argument("--out", default="backtest_results", help="Dossier sortie")
    args = parser.parse_args()

    metrics, eq_path = run_backtest(args.m15, args.out)

    print("\n================ RESULTATS ================")
    for k, v in metrics.items():
        print(f"  {k:<22}: {v}")
    print(f"\n  Equity curve  : {eq_path}")
    print("==========================================\n")


if __name__ == "__main__":
    main()
