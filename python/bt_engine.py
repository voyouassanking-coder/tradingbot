#!/usr/bin/env python3
"""Moteur de backtest parametrable pour SOSFinancial (logique corrigee).
   Permet de lancer la baseline et des variantes via un dict de config.
   Chaque amelioration se teste UNE a la fois (on part toujours de la baseline).
"""
import numpy as np
import pandas as pd


# ============================================================
# Config par defaut = BASELINE (params EA d'origine, convertis USD)
# ============================================================
DEFAULT = dict(
    initial_balance = 10_000.0,
    risk_pct        = 1.0,
    rr              = 1.5,
    atr_sl_mult     = 1.0,

    use_partial     = True,
    partial_usd     = 150.0,
    partial_ratio   = 0.5,
    use_be          = True,
    be_offset_usd   = 5.0,

    max_spread_usd  = 30.0,
    cooldown_sec    = 300,
    session_start   = 8,
    session_end     = 21,
    skip_weekend    = False,
    skip_friday_late= False,

    use_volume      = True,
    use_ha          = True,

    d1_rsi_up=55.0, d1_rsi_dn=45.0, d1_adx_min=20.0,
    h4_rsi_up=52.0, h4_rsi_dn=48.0, h4_adx_min=15.0,
    h1_rsi_buy=50.0, h1_rsi_sell=50.0,

    ema21=21, ema50=50, ema200=200,
    rsi_p=21, adx_p=14, atr_p=14, kinjun_p=26,

    max_dd_pct      = 20.0,

    # --- garde-fous risque (nouveaux) ---
    global_dd_stop  = None,   # kill-switch : stop definitif si DD equity depuis pic >= X%
    max_risk_pct_block = None,# skip le trade si risque min-lot > X% equity
    max_risk_usd    = None,   # plafond absolu $ : reduit pas le lot mais skip si min-lot depasse

    # --- knobs des variantes (off par defaut = baseline) ---
    allow_buy       = True,
    allow_sell      = True,
    atr_rank_min    = None,   # filtre volatilite : percentile ATR mini (0-100)
    atr_rank_max    = None,   # percentile ATR maxi
    min_dist_ema200_pct = None,  # |dist EMA200| mini en % (filtre tendance forte)
    exit_on_opposite= False,  # sortie sur signal H1 oppose au lieu de SL/TP fixe
    require_ma_stack= False,  # exiger l'alignement des 6 MA + Kijun (H1)

    contract_per_lot= 1.0,
    vol_min=0.01, vol_step=0.01,
)


def wilder(s, n): return s.ewm(alpha=1.0/n, adjust=False).mean()
def ema(s, n):    return s.ewm(span=n, adjust=False).mean()

def rsi(close, n):
    d = close.diff()
    g = d.clip(lower=0); l = -d.clip(upper=0)
    rs = wilder(g, n) / wilder(l, n).replace(0, np.nan)
    return (100 - 100/(1+rs)).fillna(50)

def true_range(h, l, c):
    pc = c.shift(1)
    return pd.concat([(h-l), (h-pc).abs(), (l-pc).abs()], axis=1).max(axis=1)

def atr(h, l, c, n): return wilder(true_range(h,l,c), n)

def adx(h, l, c, n):
    up = h.diff(); dn = -l.diff()
    pdm = pd.Series(np.where((up>dn)&(up>0), up, 0.0), index=h.index)
    mdm = pd.Series(np.where((dn>up)&(dn>0), dn, 0.0), index=h.index)
    tr = true_range(h,l,c); a = wilder(tr, n).replace(0, np.nan)
    pdi = 100*wilder(pdm,n)/a; mdi = 100*wilder(mdm,n)/a
    dx = (100*(pdi-mdi).abs()/(pdi+mdi)).fillna(0)
    return wilder(dx, n).fillna(0)

def kinjun(h, l, n): return (h.rolling(n).max() + l.rolling(n).min())/2.0

def heiken_ashi(o,h,l,c):
    hc = (o+h+l+c)/4.0
    ho = np.empty(len(o)); ho[0] = (o.iloc[0]+c.iloc[0])/2.0
    cv = hc.values
    for i in range(1, len(o)):
        ho[i] = (ho[i-1]+cv[i-1])/2.0
    return pd.Series(ho, index=o.index), hc


def _resample(df, rule):
    return df.resample(rule, label="right", closed="right").agg({
        "open":"first","high":"max","low":"min","close":"last",
        "tick_volume":"sum","spread_usd":"mean"}).dropna()

def _indis(df, c):
    df["ema21"]=ema(df["close"],c["ema21"]); df["ema50"]=ema(df["close"],c["ema50"])
    df["ema200"]=ema(df["close"],c["ema200"]); df["rsi"]=rsi(df["close"],c["rsi_p"])
    df["adx"]=adx(df["high"],df["low"],df["close"],c["adx_p"])
    df["atr"]=atr(df["high"],df["low"],df["close"],c["atr_p"])
    df["kinjun"]=kinjun(df["high"],df["low"],c["kinjun_p"])
    return df


def load_m15(path):
    df = pd.read_csv(path, parse_dates=["datetime"]).set_index("datetime").sort_index()
    df = df[~df.index.duplicated(keep="first")]
    df["spread_usd"] = df["spread"]*0.01
    return df


def prepare(m15, c):
    h1 = _indis(_resample(m15,"1h"), c)
    h4 = _indis(_resample(m15,"4h"), c)
    d1 = _indis(_resample(m15,"1D"), c)
    h1["ha_open"], h1["ha_close"] = heiken_ashi(h1["open"],h1["high"],h1["low"],h1["close"])
    h1["vol_avg4"] = h1["tick_volume"].shift(1).rolling(4).mean()

    def d1t(r):
        if pd.isna(r["ema200"]) or pd.isna(r["adx"]): return 0
        if r["ema21"]>r["ema50"]>r["ema200"] and r["close"]>r["ema200"] and r["rsi"]>c["d1_rsi_up"] and r["adx"]>c["d1_adx_min"]: return 1
        if r["ema21"]<r["ema50"]<r["ema200"] and r["close"]<r["ema200"] and r["rsi"]<c["d1_rsi_dn"] and r["adx"]>c["d1_adx_min"]: return -1
        return 0
    def h4t(r):
        if pd.isna(r["ema50"]) or pd.isna(r["adx"]) or pd.isna(r["kinjun"]): return 0
        if r["ema21"]>r["ema50"] and r["close"]>r["kinjun"] and r["rsi"]>c["h4_rsi_up"] and r["adx"]>c["h4_adx_min"]: return 1
        if r["ema21"]<r["ema50"] and r["close"]<r["kinjun"] and r["rsi"]<c["h4_rsi_dn"] and r["adx"]>c["h4_adx_min"]: return -1
        return 0
    def h1s(r):
        if pd.isna(r["ema50"]) or pd.isna(r["kinjun"]): return 0
        if r["ema21"]>r["ema50"] and r["close"]>r["kinjun"] and r["close"]>r["ema21"] and r["rsi"]>c["h1_rsi_buy"]: return 1
        if r["ema21"]<r["ema50"] and r["close"]<r["kinjun"] and r["close"]<r["ema21"] and r["rsi"]<c["h1_rsi_sell"]: return -1
        return 0

    idx = m15.index
    d1_arr = d1.apply(d1t,axis=1).shift(1).reindex(idx, method="ffill")
    h4_arr = h4.apply(h4t,axis=1).shift(1).reindex(idx, method="ffill")
    h1_arr = h1.apply(h1s,axis=1).shift(1).reindex(idx, method="ffill")
    atr_arr= h1["atr"].shift(1).reindex(idx, method="ffill")
    vol_ok = (h1["tick_volume"].shift(1) >= h1["vol_avg4"]).reindex(idx, method="ffill")
    ha_bull= (h1["ha_close"].shift(1) > h1["ha_open"].shift(1)).reindex(idx, method="ffill")

    # --- Stack des 6 MA + Kijun sur H1 (demande utilisateur) ---
    # EMA5 > EMA8 > EMA21 > SMA55 > SMA100 > SMA200 (haussier) et inverse (baissier)
    h1["ema5"]   = ema(h1["close"], 5)
    h1["ema8"]   = ema(h1["close"], 8)
    h1["ema21b"] = ema(h1["close"], 21)
    h1["sma55"]  = h1["close"].rolling(55).mean()
    h1["sma100"] = h1["close"].rolling(100).mean()
    h1["sma200"] = h1["close"].rolling(200).mean()
    h1["kijun26"]= kinjun(h1["high"], h1["low"], 26)

    def ma_stack(r):
        vals = [r["ema5"], r["ema8"], r["ema21b"], r["sma55"], r["sma100"], r["sma200"]]
        if any(pd.isna(v) for v in vals) or pd.isna(r["kijun26"]):
            return 0
        # Haussier : strictement empile + prix et Kijun au-dessus de la plus lente
        if (r["ema5"]>r["ema8"]>r["ema21b"]>r["sma55"]>r["sma100"]>r["sma200"]
                and r["close"]>r["kijun26"] and r["kijun26"]>r["sma200"]):
            return 1
        if (r["ema5"]<r["ema8"]<r["ema21b"]<r["sma55"]<r["sma100"]<r["sma200"]
                and r["close"]<r["kijun26"] and r["kijun26"]<r["sma200"]):
            return -1
        return 0
    ma_stack_arr = h1.apply(ma_stack, axis=1).shift(1).reindex(idx, method="ffill")

    # contexte marche M15 pour filtres volatilite/tendance
    m15 = m15.copy()
    m15["atr14"]  = atr(m15["high"],m15["low"],m15["close"],14)
    m15["ema200m"]= ema(m15["close"],200)
    m15["atr_rank"] = m15["atr14"].rolling(500, min_periods=50).apply(
        lambda x:(x.iloc[-1]>=x).mean()*100, raw=False)
    atr_rank = m15["atr_rank"].shift(1)
    dist200  = (m15["close"] - m15["ema200m"]) / m15["ema200m"] * 100
    dist200  = dist200.shift(1)

    return dict(d1=d1_arr, h4=h4_arr, h1=h1_arr, atr=atr_arr,
                vol_ok=vol_ok, ha_bull=ha_bull,
                atr_rank=atr_rank, dist200=dist200,
                ma_stack=ma_stack_arr)


def run(m15, prep, cfg, start=None, end=None):
    """start/end : bornes de dates (incluses) pour backtester une tranche.
       Les indicateurs (prep) sont calcules sur tout l'historique en amont,
       donc pas de lookahead aux frontieres de tranche."""
    c = dict(DEFAULT); c.update(cfg)
    bal = c["initial_balance"]
    eq_curve=[]; eq_dates=[]; trades=[]
    pos=None; cooldown=None
    day_date=None; day_anchor=bal; locked=False
    peak_eq=bal; halted=False   # kill-switch DD global

    d1=prep["d1"].values; h4=prep["h4"].values; h1=prep["h1"].values
    atr_a=prep["atr"].values; vol_ok=prep["vol_ok"].values; ha_bull=prep["ha_bull"].values
    atr_rank=prep["atr_rank"].values; dist200=prep["dist200"].values
    ma_stack=prep["ma_stack"].values

    opens=m15["open"].values; highs=m15["high"].values; lows=m15["low"].values
    closes=m15["close"].values; spreads=m15["spread_usd"].values
    times=m15.index

    # bornes d'index
    i0, i1 = 0, len(m15)
    if start is not None: i0 = int(times.searchsorted(pd.Timestamp(start), side="left"))
    if end   is not None: i1 = int(times.searchsorted(pd.Timestamp(end),   side="right"))

    for i in range(i0, i1):
        ts=times[i]; high=highs[i]; low=lows[i]; close=closes[i]
        if day_date != ts.date():
            day_date=ts.date(); day_anchor=bal; locked=False

        # ---- gestion position ----
        if pos is not None:
            is_buy = pos["dir"]>0
            fav = (high-pos["entry"]) if is_buy else (pos["entry"]-low)
            if c["use_partial"] and not pos["partial_done"] and fav>=c["partial_usd"]:
                cv = max(c["vol_min"], np.floor(pos["lots"]*c["partial_ratio"]/c["vol_step"])*c["vol_step"])
                cv = round(cv,2)
                if cv < pos["lots"]:
                    pp = pos["entry"] + (c["partial_usd"] if is_buy else -c["partial_usd"])
                    pnl = (pp-pos["entry"])*cv*c["contract_per_lot"]*(1 if is_buy else -1)
                    pnl -= pos["entry_spread"]*cv
                    bal += pnl
                    pos["lots"]-=cv; pos["partial_pnl"]=pnl; pos["partial_done"]=True
                    if c["use_be"]:
                        pos["sl"] = pos["entry"] + (c["be_offset_usd"] if is_buy else -c["be_offset_usd"])

            sl_hit = (low<=pos["sl"]) if is_buy else (high>=pos["sl"])
            tp_hit = (high>=pos["tp"]) if is_buy else (low<=pos["tp"])
            exit_px=None; reason=None
            if sl_hit: exit_px=pos["sl"]; reason="SL"
            elif tp_hit: exit_px=pos["tp"]; reason="TP"

            # sortie sur signal oppose (variante)
            if exit_px is None and c["exit_on_opposite"] and not np.isnan(h1[i]):
                cur_sig=int(h1[i])
                if (is_buy and cur_sig==-1) or (not is_buy and cur_sig==1):
                    exit_px=close; reason="OPP"

            if exit_px is not None:
                pnl=(exit_px-pos["entry"])*pos["lots"]*c["contract_per_lot"]*(1 if is_buy else -1)
                pnl-=pos["entry_spread"]*pos["lots"]
                bal+=pnl
                total=pnl+pos.get("partial_pnl",0.0)
                trades.append(dict(open_time=pos["open_time"], close_time=ts,
                    direction="BUY" if is_buy else "SELL", entry=pos["entry"],
                    exit=exit_px, lots=pos["initial_lots"], pnl=total, reason=reason,
                    had_partial=pos["partial_done"]))
                pos=None
                cooldown=ts+pd.Timedelta(seconds=c["cooldown_sec"])

        eq_curve.append(bal); eq_dates.append(ts)

        # kill-switch DD global (sur balance, positions deja a plat ici)
        if bal>peak_eq: peak_eq=bal
        if c["global_dd_stop"] is not None and not halted:
            gdd=(peak_eq-bal)/peak_eq*100.0
            if gdd>=c["global_dd_stop"]: halted=True
        if halted: continue

        if pos is None and not locked:
            if cooldown is not None and ts<cooldown: continue
            # session
            if c["skip_weekend"] and ts.weekday()>=5: continue
            if c["skip_friday_late"] and ts.weekday()==4 and ts.hour>=17: continue
            if not (c["session_start"]<=ts.hour<c["session_end"]): continue
            if np.isnan(atr_a[i]) or atr_a[i]<=0: continue
            if spreads[i]>c["max_spread_usd"]: continue
            dd=(day_anchor-bal)/day_anchor*100.0
            if dd>=c["max_dd_pct"]: locked=True; continue
            if np.isnan(d1[i]) or np.isnan(h4[i]) or np.isnan(h1[i]): continue
            D,H4,H1=int(d1[i]),int(h4[i]),int(h1[i])
            direction=0
            if D==1 and H4==1 and H1==1: direction=1
            elif D==-1 and H4==-1 and H1==-1: direction=-1
            if direction==0: continue
            if direction>0 and not c["allow_buy"]: continue
            if direction<0 and not c["allow_sell"]: continue
            # filtre alignement des 6 MA + Kijun (H1)
            if c["require_ma_stack"]:
                if np.isnan(ma_stack[i]) or int(ma_stack[i]) != direction: continue
            if c["use_volume"] and not bool(vol_ok[i]): continue
            if c["use_ha"]:
                if direction>0 and not bool(ha_bull[i]): continue
                if direction<0 and bool(ha_bull[i]): continue
            # filtre volatilite (variante)
            if c["atr_rank_min"] is not None and (np.isnan(atr_rank[i]) or atr_rank[i]<c["atr_rank_min"]): continue
            if c["atr_rank_max"] is not None and (np.isnan(atr_rank[i]) or atr_rank[i]>c["atr_rank_max"]): continue
            # filtre tendance forte (variante)
            if c["min_dist_ema200_pct"] is not None:
                if np.isnan(dist200[i]): continue
                if direction>0 and dist200[i] < c["min_dist_ema200_pct"]: continue
                if direction<0 and dist200[i] > -c["min_dist_ema200_pct"]: continue

            sld=atr_a[i]*c["atr_sl_mult"]
            if sld<10: continue
            entry=close
            sl=entry-sld if direction>0 else entry+sld
            tp=entry+sld*c["rr"] if direction>0 else entry-sld*c["rr"]
            risk_money=bal*c["risk_pct"]/100.0
            lots=np.floor(risk_money/(sld*c["contract_per_lot"])/c["vol_step"])*c["vol_step"]
            if lots<c["vol_min"]: lots=c["vol_min"]
            lots=round(lots,2)
            # garde-fou : risque reel du lot retenu (lot plancher peut depasser la cible)
            risk_real=sld*lots*c["contract_per_lot"]
            if c["max_risk_usd"] is not None and risk_real>c["max_risk_usd"]: continue
            if c["max_risk_pct_block"] is not None and risk_real>bal*c["max_risk_pct_block"]/100.0: continue
            pos=dict(open_time=ts, dir=direction, entry=entry, sl=sl, tp=tp,
                     lots=lots, initial_lots=lots, entry_spread=spreads[i],
                     partial_done=False, partial_pnl=0.0)

    return _metrics(eq_curve, eq_dates, trades, c["initial_balance"]), trades


def _metrics(eq_curve, eq_dates, trades, init):
    eq=pd.Series(eq_curve, index=pd.DatetimeIndex(eq_dates))
    dd=(eq-eq.cummax())/eq.cummax()*100.0
    p=pd.Series([t["pnl"] for t in trades])
    n=len(p); w=int((p>0).sum()); l=int((p<0).sum())
    gp=p[p>0].sum() if n else 0.0; gl=-p[p<0].sum() if n else 0.0
    pf=(gp/gl) if gl>0 else (float("inf") if gp>0 else 0.0)
    return dict(
        net=round(eq.iloc[-1]-init,2) if len(eq) else 0.0,
        ret_pct=round((eq.iloc[-1]-init)/init*100,2) if len(eq) else 0.0,
        trades=n, wins=w, losses=l,
        wr=round(w/n*100,2) if n else 0.0,
        pf=round(pf,3) if pf!=float("inf") else 999.0,
        avg_win=round(p[p>0].mean(),2) if w else 0.0,
        avg_loss=round(p[p<0].mean(),2) if l else 0.0,
        expectancy=round(p.mean(),2) if n else 0.0,
        max_dd=round(-dd.min(),2) if len(dd) else 0.0,
        final=round(eq.iloc[-1],2) if len(eq) else init,
    )
