#!/usr/bin/env python3
"""Backtest comparatif de 3 EAs externes, REPLIQUES sur donnees BTC M15.
   ATTENTION : ces EAs sont concus pour Oil/Gold. On les teste sur BTC
   pour voir lequel transfere le mieux comme base du projet scalping BTC.

   1. OilGrid   : grille + direction Ichimoku H1, pas de SL, close +1%
   2. IchiVP    : Ichimoku H1 score 5-composantes + Volume Profile + ATR SL/RR
   3. GoldStorm : 3 sous-strategies (EMA50/200 + Ichimoku + cassures) H1/H4/D1

   Compte de reference 3000 USD. Resultats = edge approximatif (OHLC M15).
"""
import sys
import numpy as np
import pandas as pd

def ema(s,n): return s.ewm(span=n,adjust=False).mean()
def sma(s,n): return s.rolling(n).mean()
def wilder(s,n): return s.ewm(alpha=1.0/n,adjust=False).mean()
def kijun(h,l,n): return (h.rolling(n).max()+l.rolling(n).min())/2.0
def tenkan(h,l,n=9): return (h.rolling(n).max()+l.rolling(n).min())/2.0
def tr(h,l,c):
    pc=c.shift(1); return pd.concat([(h-l),(h-pc).abs(),(l-pc).abs()],axis=1).max(axis=1)
def atr(h,l,c,n): return wilder(tr(h,l,c),n)

BAL0 = 3000.0
CONTRACT = 1.0   # 1 lot = 1 BTC
VMIN, VSTEP = 0.01, 0.01

def load_m15(path):
    d=pd.read_csv(path,parse_dates=["datetime"]).set_index("datetime").sort_index()
    d=d[~d.index.duplicated()]; d["spread_usd"]=d["spread"]*0.01
    return d
def rs(d,rule):
    return d.resample(rule,label="right",closed="right").agg(
        {"open":"first","high":"max","low":"min","close":"last","tick_volume":"sum"}).dropna()

def ichimoku(df):
    df=df.copy()
    df["tenkan"]=tenkan(df["high"],df["low"],9)
    df["kijun"]=kijun(df["high"],df["low"],26)
    ssa=((df["tenkan"]+df["kijun"])/2).shift(26)
    ssb=kijun(df["high"],df["low"],52).shift(26)
    df["ssa"]=ssa; df["ssb"]=ssb
    return df

def calc_lot(bal, sl_dist, risk_pct):
    if sl_dist<=0: return VMIN
    risk=bal*risk_pct/100.0
    lot=np.floor(risk/(sl_dist*CONTRACT)/VSTEP)*VSTEP
    return max(VMIN, round(lot,2))

def metrics(trades, eq, eqt, bal0):
    p=pd.Series([t["pnl"] for t in trades])
    n=len(p); w=int((p>0).sum()); l=int((p<0).sum())
    gp=p[p>0].sum() if n else 0; gl=-p[p<0].sum() if n else 0
    pf=(gp/gl) if gl>0 else (999 if gp>0 else 0)
    eqs=pd.Series(eq,index=pd.DatetimeIndex(eqt)) if eq else pd.Series([bal0])
    dd=((eqs.cummax()-eqs)/eqs.cummax()*100).max()
    return dict(net=round(eqs.iloc[-1]-bal0,1), final=round(eqs.iloc[-1],1),
        ret=round((eqs.iloc[-1]-bal0)/bal0*100,1), trades=n,
        wr=round(w/n*100,1) if n else 0, pf=round(pf,2),
        max_dd=round(dd,1) if n else 0,
        avg=round(p.mean(),2) if n else 0)

# ==================================================================
# 1. OILGRID sur BTC
# ==================================================================
def bt_oilgrid(h1, start=None, end=None):
    h1=ichimoku(h1)
    idx=h1.index; i0,i1=0,len(h1)
    if start: i0=int(idx.searchsorted(pd.Timestamp(start)))
    if end:   i1=int(idx.searchsorted(pd.Timestamp(end),side="right"))
    bal=BAL0; eq=[]; eqt=[]; trades=[]
    grid=[]   # positions: dict(dir,entry,lot)
    GRID_USD=5000.0  # = GridStep(0.5)*10000 comme le code
    MAXLVL=5; LOT=0.01
    start_bal=BAL0
    for i in range(max(i0,53), i1):
        row=h1.iloc[i]
        c=row["close"]; ct=max(row["ssa"],row["ssb"]); cb=min(row["ssa"],row["ssb"])
        if np.isnan(ct):
            eq.append(bal); eqt.append(idx[i]); continue
        bull=(c>ct) and (row["tenkan"]>row["kijun"])
        bear=(c<cb) and (row["tenkan"]<row["kijun"])
        # MtM du panier
        float_pnl=sum((c-g["entry"])*g["lot"]*CONTRACT*(1 if g["dir"]>0 else -1) for g in grid)
        # DD global 15%
        if start_bal>0 and (start_bal-(bal+float_pnl))/start_bal*100>=15 and grid:
            bal+=float_pnl
            for g in grid: trades.append(dict(pnl=(c-g["entry"])*g["lot"]*(1 if g["dir"]>0 else -1)))
            grid=[]
            eq.append(bal); eqt.append(idx[i]); continue
        # close basket si profit >= 1% balance
        if grid and float_pnl >= bal*0.01:
            bal+=float_pnl
            for g in grid: trades.append(dict(pnl=(c-g["entry"])*g["lot"]*(1 if g["dir"]>0 else -1)))
            grid=[]
        # init
        if not grid:
            if bull: grid.append(dict(dir=1,entry=c,lot=LOT))
            elif bear: grid.append(dict(dir=-1,entry=c,lot=LOT))
        else:
            d0=grid[0]["dir"]
            if d0>0 and bull and len(grid)<MAXLVL:
                lowest=min(g["entry"] for g in grid)
                if c < lowest-GRID_USD: grid.append(dict(dir=1,entry=c,lot=LOT))
            elif d0<0 and bear and len(grid)<MAXLVL:
                highest=max(g["entry"] for g in grid)
                if c > highest+GRID_USD: grid.append(dict(dir=-1,entry=c,lot=LOT))
        eq.append(bal+sum((c-g["entry"])*g["lot"]*(1 if g["dir"]>0 else -1) for g in grid))
        eqt.append(idx[i])
    return metrics(trades, eq, eqt, BAL0)

# ==================================================================
# 2. ICHIVP sur BTC
# ==================================================================
def vp_zone(d1_slice):
    # POC/VAH/VAL sur 20 dernieres D1
    hi=d1_slice["high"].values; lo=d1_slice["low"].values; vol=d1_slice["tick_volume"].values
    gHi=hi.max(); gLo=lo.min()
    if gHi<=gLo: return None
    B=50; bs=(gHi-gLo)/B; lvl=np.zeros(B); tot=0
    for b in range(len(hi)):
        li=int(max(0,min(B-1,(lo[b]-gLo)//bs))); h_=int(max(0,min(B-1,(hi[b]-gLo)//bs)))
        sp=h_-li+1
        for k in range(li,h_+1): lvl[k]+=vol[b]/sp; tot+=vol[b]/sp
    poc_i=int(lvl.argmax()); POC=gLo+(poc_i+0.5)*bs
    target=tot*0.7; va=lvl[poc_i]; loV=hiV=poc_i
    while va<target and (loV>0 or hiV<B-1):
        addU=lvl[hiV+1] if hiV<B-1 else 0; addD=lvl[loV-1] if loV>0 else 0
        if addU>=addD and hiV<B-1: hiV+=1; va+=addU
        elif loV>0: loV-=1; va+=addD
        else: break
    return POC, gLo+(hiV+1)*bs, gLo+loV*bs  # POC,VAH,VAL

def bt_ichivp(h1, d1, start=None, end=None):
    h1=ichimoku(h1); h1["atr"]=atr(h1["high"],h1["low"],h1["close"],14)
    idx=h1.index; i0,i1=0,len(h1)
    if start: i0=int(idx.searchsorted(pd.Timestamp(start)))
    if end:   i1=int(idx.searchsorted(pd.Timestamp(end),side="right"))
    bal=BAL0; eq=[]; eqt=[]; trades=[]; pos=None
    MINSCORE=2; RR=2.0; SLm=1.5; PROX=2.0
    for i in range(max(i0,60), i1):
        r=h1.iloc[i]; r1=h1.iloc[i-1]
        price=r1["close"]; ts=r1["tenkan"]; ks=r1["kijun"]; ssa=r1["ssa"]; ssb=r1["ssb"]
        if np.isnan(ssa) or np.isnan(r1["atr"]):
            eq.append(bal); eqt.append(idx[i]); continue
        kt=max(ssa,ssb); kb=min(ssa,ssb)
        # gestion position (SL/TP)
        if pos is not None:
            hi=r["high"]; lo=r["low"]; isb=pos["dir"]>0
            sl_hit=(lo<=pos["sl"]) if isb else (hi>=pos["sl"])
            tp_hit=(hi>=pos["tp"]) if isb else (lo<=pos["tp"])
            ex=None
            if sl_hit: ex=pos["sl"]
            elif tp_hit: ex=pos["tp"]
            if ex is not None:
                g=(ex-pos["entry"])*pos["lot"]*CONTRACT*(1 if isb else -1)
                bal+=g; trades.append(dict(pnl=g)); pos=None
        eq.append(bal); eqt.append(idx[i])
        if pos is not None: continue
        # score Ichimoku (simplifie : 5 composantes principales)
        sl_score=0; ss_score=0
        if ts>ks: sl_score+=1
        else: ss_score+=1
        if price>ks: sl_score+=1
        else: ss_score+=1
        if price>kt: sl_score+=1
        elif price<kb: ss_score+=1
        if ssa>ssb: sl_score+=1
        else: ss_score+=1
        # chikou approx : close actuel vs close il y a 26
        if i-1-26>=0:
            past=h1.iloc[i-1-26]["close"]
            if price>past: sl_score+=1
            else: ss_score+=1
        # VP
        d1_pos=d1.index.searchsorted(idx[i],side="right")
        vp=None
        if d1_pos>=20: vp=vp_zone(d1.iloc[d1_pos-20:d1_pos])
        atrv=r1["atr"]; entry=r["open"]
        # LONG
        if sl_score>=MINSCORE:
            vpok = (vp is None) or (entry<=vp[2]*(1+PROX/100)) or (vp[2]<=entry<=vp[0])
            if vpok:
                sl=min(entry-atrv*SLm, ks-atrv*0.2)
                tp=entry+(entry-sl)*RR
                if sl<entry:
                    lot=calc_lot(bal, entry-sl, 1.5)
                    pos=dict(dir=1,entry=entry,sl=sl,tp=tp,lot=lot); continue
        if ss_score>=MINSCORE:
            vpok = (vp is None) or (entry>=vp[1]*(1-PROX/100)) or (entry<=vp[1] and entry>=vp[0])
            if vpok:
                sl=max(entry+atrv*SLm, ks+atrv*0.2)
                tp=entry-(sl-entry)*RR
                if sl>entry:
                    lot=calc_lot(bal, sl-entry, 1.5)
                    pos=dict(dir=-1,entry=entry,sl=sl,tp=tp,lot=lot)
    return metrics(trades, eq, eqt, BAL0)

# ==================================================================
# 3. GOLDSTORM sur BTC
# ==================================================================
def bt_goldstorm(h1, h4, d1, start=None, end=None):
    h1=ichimoku(h1); h1["atr"]=atr(h1["high"],h1["low"],h1["close"],14)
    h1["ema50"]=ema(h1["close"],50); h1["ema200"]=ema(h1["close"],200)
    h4=h4.copy(); h4["atr"]=atr(h4["high"],h4["low"],h4["close"],14)
    idx=h1.index; i0,i1=0,len(h1)
    if start: i0=int(idx.searchsorted(pd.Timestamp(start)))
    if end:   i1=int(idx.searchsorted(pd.Timestamp(end),side="right"))
    bal=BAL0; eq=[]; eqt=[]; trades=[]; pos=None
    SLm=1.8; TPm=3.6; MINCONF=3; ATRmin=0.8
    for i in range(max(i0,210), i1):
        r=h1.iloc[i]; r1=h1.iloc[i-1]
        c1=r1["close"]; o1=r1["open"]; ema50=r1["ema50"]; ema200=r1["ema200"]
        ks=r1["kijun"]; ts=r1["tenkan"]; ssa=r1["ssa"]; ssb=r1["ssb"]; av=r1["atr"]
        if np.isnan(ema200) or np.isnan(ssa) or np.isnan(av):
            eq.append(bal); eqt.append(idx[i]); continue
        # gestion position
        if pos is not None:
            hi=r["high"]; lo=r["low"]; isb=pos["dir"]>0
            sl_hit=(lo<=pos["sl"]) if isb else (hi>=pos["sl"])
            tp_hit=(hi>=pos["tp"]) if isb else (lo<=pos["tp"])
            ex=None
            if sl_hit: ex=pos["sl"]
            elif tp_hit: ex=pos["tp"]
            if ex is not None:
                g=(ex-pos["entry"])*pos["lot"]*CONTRACT*(1 if isb else -1)
                bal+=g; trades.append(dict(pnl=g)); pos=None
        eq.append(bal); eqt.append(idx[i])
        if pos is not None: continue
        if av<ATRmin: continue
        kt=max(ssa,ssb); kb=min(ssa,ssb)
        bull=ema50>ema200; bear=ema50<ema200
        aboveK=c1>kt; belowK=c1<kb
        aboveKj=c1>ks; belowKj=c1<ks
        def score(trend,abk,abkj,cass):
            return int(trend)+int(abk)+int(abkj)+int(cass)+int(av>ATRmin)
        entry=r["open"]
        # Strat B : cassure H1 fractale + cross tenkan/kijun
        hh=h1.iloc[max(0,i-21):i-1]["high"].max()
        ll=h1.iloc[max(0,i-21):i-1]["low"].min()
        ts2=h1.iloc[i-2]["tenkan"]; ks2=h1.iloc[i-2]["kijun"]
        crossBull=(ts>ks) and (ts2<ks2); crossBear=(ts<ks) and (ts2>ks2)
        took=False
        if bull and not (kb<=c1<=kt) and crossBull and c1>hh:
            if score(bull,aboveK,aboveKj,True)>=MINCONF:
                sl=entry-SLm*av; tp=entry+TPm*av
                pos=dict(dir=1,entry=entry,sl=sl,tp=tp,lot=calc_lot(bal,entry-sl,1.0)); took=True
        if not took and bear and not (kb<=c1<=kt) and crossBear and c1<ll:
            if score(bear,belowK,belowKj,True)>=MINCONF:
                sl=entry+SLm*av; tp=entry-TPm*av
                pos=dict(dir=-1,entry=entry,sl=sl,tp=tp,lot=calc_lot(bal,sl-entry,1.0)); took=True
        # Strat C : D1 trend + pullback kijun
        if not took:
            d1_pos=d1.index.searchsorted(idx[i],side="right")
            if d1_pos>200:
                ema200d1=ema(d1["close"],200).iloc[d1_pos-1]
                closeD1=d1.iloc[d1_pos-1]["close"]
                tBull=(closeD1>ema200d1) and bull
                tBear=(closeD1<ema200d1) and bear
                pbBull=(r1["low"]<=ks*1.002) and (c1>ks) and (c1>o1)
                pbBear=(r1["high"]>=ks*0.998) and (c1<ks) and (c1<o1)
                if tBull and pbBull and aboveK and score(bull,aboveK,aboveKj,True)>=MINCONF:
                    sl=entry-SLm*2.0*av; tp=entry+TPm*2.5*av
                    pos=dict(dir=1,entry=entry,sl=sl,tp=tp,lot=calc_lot(bal,entry-sl,1.0))
                elif tBear and pbBear and belowK and score(bear,belowK,belowKj,True)>=MINCONF:
                    sl=entry+SLm*2.0*av; tp=entry-TPm*2.5*av
                    pos=dict(dir=-1,entry=entry,sl=sl,tp=tp,lot=calc_lot(bal,sl-entry,1.0))
    return metrics(trades, eq, eqt, BAL0)


def main():
    csv=sys.argv[1]
    print("Chargement M15 + resampling...")
    m15=load_m15(csv)
    h1=rs(m15,"1h"); h4=rs(m15,"4h"); d1=rs(m15,"1D")
    t0,t1=m15.index[0],m15.index[-1]
    split=m15.index[int(len(m15)*0.70)]
    print(f"  {len(m15):,} M15 -> H1={len(h1):,} | {t0.date()} -> {t1.date()} | split {split.date()}\n")

    def show(name, fn, *a):
        mf=fn(*a); mis=fn(*a,start=None,end=split); moos=fn(*a,start=split,end=None)
        print(f"\n{'='*86}\n{name}\n{'='*86}")
        for lbl,m in [("FULL",mf),("IS  ",mis),("OOS ",moos)]:
            print(f"  {lbl}: net={m['net']:>9.1f} ret={m['ret']:>7.1f}% n={m['trades']:>4} "
                  f"WR={m['wr']:>5.1f}% PF={m['pf']:>5.2f} DD={m['max_dd']:>5.1f}%")
        return mf,mis,moos

    r_oil = show("1. OILGRID (grille+Ichimoku) sur BTC", bt_oilgrid, h1)
    r_ivp = show("2. ICHIVP (Ichimoku+VolumeProfile) sur BTC", bt_ichivp, h1, d1)
    r_gs  = show("3. GOLDSTORM (3 strat EMA+Ichimoku) sur BTC", bt_goldstorm, h1, h4, d1)

    print(f"\n{'='*86}\nCLASSEMENT (sur FULL, critere PF puis net)\n{'='*86}")
    rank=[("OilGrid",r_oil[0]),("IchiVP",r_ivp[0]),("GoldStorm",r_gs[0])]
    for nm,m in sorted(rank,key=lambda x:(x[1]['pf'],x[1]['net']),reverse=True):
        print(f"  {nm:<12} net={m['net']:>9.1f} ret={m['ret']:>7.1f}% PF={m['pf']:>5.2f} "
              f"DD={m['max_dd']:>5.1f}% n={m['trades']}")

if __name__=="__main__":
    main()
