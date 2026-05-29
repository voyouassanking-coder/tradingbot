#!/usr/bin/env python3
"""Analyse forensique des trades perdants de la baseline.
   Rejoint chaque trade avec les conditions de marche au moment de l'entree.
"""
import sys
import numpy as np
import pandas as pd

TRADES = "backtest_results/trades.csv"
M15    = sys.argv[1] if len(sys.argv) > 1 else None

def wilder(s, n): return s.ewm(alpha=1.0/n, adjust=False).mean()
def true_range(h, l, c):
    pc = c.shift(1)
    return pd.concat([(h-l), (h-pc).abs(), (l-pc).abs()], axis=1).max(axis=1)
def atr(h, l, c, n=14): return wilder(true_range(h,l,c), n)
def ema(s, n): return s.ewm(span=n, adjust=False).mean()

def main():
    tr = pd.read_csv(TRADES, parse_dates=["open_time", "close_time"])
    tr["hour"] = tr["open_time"].dt.hour
    tr["dow"]  = tr["open_time"].dt.dayofweek  # 0=lundi
    tr["win"]  = tr["pnl"] > 0
    tr["hold_min"] = (tr["close_time"] - tr["open_time"]).dt.total_seconds() / 60

    print("="*64)
    print("ANALYSE DES TRADES — baseline")
    print("="*64)
    print(f"Total trades : {len(tr)}  |  Net PnL : {tr['pnl'].sum():+.2f} USD")
    print(f"Gagnants : {tr['win'].sum()} ({tr['win'].mean()*100:.1f}%)  "
          f"Perdants : {(~tr['win']).sum()}")

    # --- Marche : rejoindre ATR / regime / distance EMA200 ---
    if M15:
        m = pd.read_csv(M15, parse_dates=["datetime"]).set_index("datetime").sort_index()
        m = m[~m.index.duplicated()]
        m["atr14"]  = atr(m["high"], m["low"], m["close"], 14)
        m["ema200"] = ema(m["close"], 200)
        m["atr_pct_price"] = m["atr14"] / m["close"] * 100
        # percentile ATR glissant sur 500 barres
        m["atr_rank"] = m["atr14"].rolling(500, min_periods=50).apply(
            lambda x: (x.iloc[-1] >= x).mean()*100, raw=False)
        # join asof
        tr_sorted = tr.sort_values("open_time")
        joined = pd.merge_asof(tr_sorted, m[["atr14","atr_pct_price","atr_rank","ema200","close"]],
                               left_on="open_time", right_index=True, direction="backward")
        joined["dist_ema200_pct"] = (joined["entry"] - joined["ema200"]) / joined["ema200"] * 100
        tr = joined

    # =============================================================
    # 1) PAR HEURE
    # =============================================================
    print("\n" + "-"*64)
    print("1) PnL PAR HEURE D'ENTREE (heure broker)")
    print("-"*64)
    by_hour = tr.groupby("hour").agg(
        n=("pnl","size"), pnl=("pnl","sum"),
        wr=("win", lambda x: x.mean()*100), avg=("pnl","mean")).round(1)
    print(by_hour.to_string())
    worst_h = by_hour.sort_values("pnl").head(5)
    print(f"\n  >> 5 pires heures (PnL cumule): {list(worst_h.index)}")
    print(f"     PnL cumule de ces heures : {worst_h['pnl'].sum():+.0f} USD")

    # =============================================================
    # 2) PAR JOUR DE SEMAINE
    # =============================================================
    print("\n" + "-"*64)
    print("2) PnL PAR JOUR DE SEMAINE (0=Lun ... 6=Dim)")
    print("-"*64)
    days = ["Lun","Mar","Mer","Jeu","Ven","Sam","Dim"]
    by_dow = tr.groupby("dow").agg(
        n=("pnl","size"), pnl=("pnl","sum"),
        wr=("win", lambda x: x.mean()*100), avg=("pnl","mean")).round(1)
    by_dow.index = [days[i] for i in by_dow.index]
    print(by_dow.to_string())

    # =============================================================
    # 3) PAR DIRECTION
    # =============================================================
    print("\n" + "-"*64)
    print("3) PnL PAR DIRECTION")
    print("-"*64)
    by_dir = tr.groupby("direction").agg(
        n=("pnl","size"), pnl=("pnl","sum"),
        wr=("win", lambda x: x.mean()*100), avg=("pnl","mean")).round(1)
    print(by_dir.to_string())

    # =============================================================
    # 4) CONDITIONS DE MARCHE (si M15 fourni)
    # =============================================================
    if M15:
        print("\n" + "-"*64)
        print("4) PnL PAR REGIME DE VOLATILITE (percentile ATR a l'entree)")
        print("-"*64)
        tr["atr_bucket"] = pd.cut(tr["atr_rank"], [0,25,50,75,100],
                                  labels=["ATR bas (0-25%)","ATR moyen-bas (25-50%)",
                                          "ATR moyen-haut (50-75%)","ATR haut (75-100%)"])
        by_atr = tr.groupby("atr_bucket", observed=True).agg(
            n=("pnl","size"), pnl=("pnl","sum"),
            wr=("win", lambda x: x.mean()*100), avg=("pnl","mean")).round(1)
        print(by_atr.to_string())

        print("\n" + "-"*64)
        print("5) PnL PAR DISTANCE AU EMA200 M15 (force de tendance)")
        print("-"*64)
        tr["trend_bucket"] = pd.cut(tr["dist_ema200_pct"], [-100,-3,-1,1,3,100],
                                    labels=["<-3% (loin sous)","-3..-1%","-1..+1% (plat)",
                                            "+1..+3%",">+3% (loin sur)"])
        by_tr = tr.groupby("trend_bucket", observed=True).agg(
            n=("pnl","size"), pnl=("pnl","sum"),
            wr=("win", lambda x: x.mean()*100), avg=("pnl","mean")).round(1)
        print(by_tr.to_string())

        print("\n" + "-"*64)
        print("6) ATR%prix a l'entree : gagnants vs perdants")
        print("-"*64)
        print(f"  Gagnants : ATR%prix moyen = {tr[tr['win']]['atr_pct_price'].mean():.3f}%")
        print(f"  Perdants : ATR%prix moyen = {tr[~tr['win']]['atr_pct_price'].mean():.3f}%")

    # =============================================================
    # 7) DUREE
    # =============================================================
    print("\n" + "-"*64)
    print("7) DUREE DE DETENTION")
    print("-"*64)
    print(f"  Gagnants : {tr[tr['win']]['hold_min'].median():.0f} min median")
    print(f"  Perdants : {tr[~tr['win']]['hold_min'].median():.0f} min median")

    # =============================================================
    # 8) DISTRIBUTION PERTES
    # =============================================================
    print("\n" + "-"*64)
    print("8) DISTRIBUTION DES PERTES")
    print("-"*64)
    losers = tr[~tr["win"]]
    print(f"  Perte totale : {losers['pnl'].sum():+.0f} USD sur {len(losers)} trades")
    print(f"  Pire trade   : {losers['pnl'].min():+.0f} USD")
    print(f"  10 pires trades cumulent : {losers.nsmallest(10,'pnl')['pnl'].sum():+.0f} USD "
          f"({losers.nsmallest(10,'pnl')['pnl'].sum()/losers['pnl'].sum()*100:.0f}% des pertes)")

if __name__ == "__main__":
    main()
