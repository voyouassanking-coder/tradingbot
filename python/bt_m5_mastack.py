#!/usr/bin/env python3
"""Backtester M5 — strategie PURE : 6 moyennes mobiles + Kijun26.
   Aucune autre confluence (pas de RSI/ADX/Ichimoku multi-TF).

   Stack haussier : EMA5>EMA8>EMA21>SMA55>SMA100>SMA200  (inverse = baissier)
   Kijun26 : confirmation (prix du bon cote + Kijun cote SMA200).

   Lot fixe 0.01 pour mesurer l'edge pur (independant du capital).
"""
import numpy as np
import pandas as pd


def ema(s, n): return s.ewm(span=n, adjust=False).mean()
def sma(s, n): return s.rolling(n).mean()
def wilder(s, n): return s.ewm(alpha=1.0/n, adjust=False).mean()
def kijun(h, l, n): return (h.rolling(n).max() + l.rolling(n).min())/2.0
def true_range(h,l,c):
    pc=c.shift(1); return pd.concat([(h-l),(h-pc).abs(),(l-pc).abs()],axis=1).max(axis=1)
def atr(h,l,c,n): return wilder(true_range(h,l,c), n)


DEFAULT = dict(
    lot            = 0.01,       # lot fixe (edge pur)
    contract_per_lot = 1.0,      # 1 lot = 1 BTC -> 1 USD / USD de move / lot
    atr_p          = 14,
    atr_sl_mult    = 1.5,
    rr             = 2.0,
    use_kijun      = True,       # exiger confirmation Kijun
    entry          = "fresh",    # "fresh" | "pullback" | "always"
    exit_mode      = "sltp",     # "sltp" | "stack_break" | "sltp_or_break"
    pullback_atr   = 0.5,        # tolerance pullback vers EMA8 (x ATR)
    cooldown_bars  = 3,          # bougies M5 d'attente apres sortie
    use_session    = False,
    sess_start     = 8,
    sess_end       = 21,
    max_spread_usd = 30.0,
    time_stop_bars = None,       # fermeture forcee apres N bougies (None=off)
)


def load(path):
    df = pd.read_csv(path, parse_dates=["datetime"]).set_index("datetime").sort_index()
    df = df[~df.index.duplicated(keep="first")]
    df["spread_usd"] = df["spread"]*0.01
    return df


def prepare(df):
    d = df.copy()
    d["ema5"]=ema(d["close"],5); d["ema8"]=ema(d["close"],8); d["ema21"]=ema(d["close"],21)
    d["sma55"]=sma(d["close"],55); d["sma100"]=sma(d["close"],100); d["sma200"]=sma(d["close"],200)
    d["kijun"]=kijun(d["high"],d["low"],26)
    d["atr"]=atr(d["high"],d["low"],d["close"],DEFAULT["atr_p"])

    up = ((d["ema5"]>d["ema8"])&(d["ema8"]>d["ema21"])&(d["ema21"]>d["sma55"])
          &(d["sma55"]>d["sma100"])&(d["sma100"]>d["sma200"]))
    dn = ((d["ema5"]<d["ema8"])&(d["ema8"]<d["ema21"])&(d["ema21"]<d["sma55"])
          &(d["sma55"]<d["sma100"])&(d["sma100"]<d["sma200"]))
    kij_up = (d["close"]>d["kijun"])&(d["kijun"]>d["sma200"])
    kij_dn = (d["close"]<d["kijun"])&(d["kijun"]<d["sma200"])

    d["stack_raw"] = np.where(up,1,np.where(dn,-1,0))
    d["stack_kij"] = np.where(up&kij_up,1,np.where(dn&kij_dn,-1,0))
    return d


def run(d, cfg, start=None, end=None):
    c = dict(DEFAULT); c.update(cfg)
    stack_col = "stack_kij" if c["use_kijun"] else "stack_raw"

    o=d["open"].values; h=d["high"].values; l=d["low"].values; cl=d["close"].values
    atr_a=d["atr"].values; spread=d["spread_usd"].values
    ema8=d["ema8"].values; ema21=d["ema21"].values
    stack=d[stack_col].values
    times=d.index

    i0,i1=0,len(d)
    if start is not None: i0=int(times.searchsorted(pd.Timestamp(start),side="left"))
    if end   is not None: i1=int(times.searchsorted(pd.Timestamp(end),side="right"))

    trades=[]; pnl_cum=0.0; eq=[]; eq_t=[]
    pos=None; cooldown_until=-1

    for i in range(max(i0,1), i1):
        # gestion position
        if pos is not None:
            is_buy=pos["dir"]>0
            sl_hit=(l[i]<=pos["sl"]) if is_buy else (h[i]>=pos["sl"])
            tp_hit=(h[i]>=pos["tp"]) if is_buy else (l[i]<=pos["tp"])
            exit_px=None; reason=None
            if c["exit_mode"] in ("sltp","sltp_or_break"):
                if sl_hit: exit_px=pos["sl"]; reason="SL"
                elif tp_hit: exit_px=pos["tp"]; reason="TP"
            if exit_px is None and c["exit_mode"] in ("stack_break","sltp_or_break"):
                # sortie si alignement perdu (sur barre fermee i-1)
                if stack[i-1]!=pos["dir"]:
                    exit_px=o[i]; reason="BREAK"
            if exit_px is None and c["time_stop_bars"] is not None:
                if i-pos["i_open"]>=c["time_stop_bars"]:
                    exit_px=o[i]; reason="TIME"
            if exit_px is not None:
                g=(exit_px-pos["entry"])*c["lot"]*c["contract_per_lot"]*(1 if is_buy else -1)
                g-=pos["spread"]*c["lot"]
                pnl_cum+=g
                trades.append(dict(t=times[i],dir="B" if is_buy else "S",pnl=g,reason=reason,
                                   bars=i-pos["i_open"]))
                pos=None; cooldown_until=i+c["cooldown_bars"]

        eq.append(pnl_cum); eq_t.append(times[i])

        if pos is None and i>cooldown_until:
            ts=times[i]
            if c["use_session"] and not (c["sess_start"]<=ts.hour<c["sess_end"]): continue
            if spread[i]>c["max_spread_usd"]: continue
            if np.isnan(atr_a[i]) or atr_a[i]<=0: continue
            d_now=stack[i-1]               # barre fermee
            if d_now==0: continue
            # trigger
            take=False
            if c["entry"]=="always":
                take=True
            elif c["entry"]=="fresh":
                take = (stack[i-2]!=d_now)  # nouvelle apparition de l'alignement
            elif c["entry"]=="pullback":
                # aligne + le prix est revenu proche EMA8 puis repart
                if d_now>0:
                    near = l[i-1] <= ema8[i-1] + atr_a[i]*c["pullback_atr"]
                    resume = cl[i-1] > ema8[i-1]
                    take = near and resume
                else:
                    near = h[i-1] >= ema8[i-1] - atr_a[i]*c["pullback_atr"]
                    resume = cl[i-1] < ema8[i-1]
                    take = near and resume
            if not take: continue

            entry=o[i]; sld=atr_a[i]*c["atr_sl_mult"]
            if sld<10: continue
            sl=entry-sld if d_now>0 else entry+sld
            tp=entry+sld*c["rr"] if d_now>0 else entry-sld*c["rr"]
            pos=dict(dir=int(d_now),entry=entry,sl=sl,tp=tp,spread=spread[i],i_open=i)

    return _metrics(trades, eq, eq_t), trades


def _metrics(trades, eq, eq_t):
    p=pd.Series([t["pnl"] for t in trades])
    n=len(p); w=int((p>0).sum()); ls=int((p<0).sum())
    gp=p[p>0].sum() if n else 0.0; gl=-p[p<0].sum() if n else 0.0
    pf=(gp/gl) if gl>0 else (999.0 if gp>0 else 0.0)
    eqs=pd.Series(eq, index=pd.DatetimeIndex(eq_t)) if eq else pd.Series([0.0])
    # drawdown sur PnL cumule (lot fixe) en USD
    dd=(eqs.cummax()-eqs).max()
    return dict(
        net=round(p.sum(),2) if n else 0.0,
        trades=n, wins=w, losses=ls,
        wr=round(w/n*100,2) if n else 0.0,
        pf=round(pf,3),
        avg_win=round(p[p>0].mean(),2) if w else 0.0,
        avg_loss=round(p[p<0].mean(),2) if ls else 0.0,
        expectancy=round(p.mean(),3) if n else 0.0,
        max_dd_usd=round(dd,2),
        median_bars=int(np.median([t["bars"] for t in trades])) if n else 0,
    )
