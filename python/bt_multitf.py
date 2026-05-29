#!/usr/bin/env python3
"""Compare le coeur de la fusion (strat B + stack 6 MA + FVG) sur plusieurs TF,
   tous derives du MEME M1 -> meme fenetre = comparaison equitable.
   Lot fixe 0.01 (edge pur). But : trouver le TF d'execution optimal.
"""
import sys
import numpy as np
import pandas as pd

def ema(s,n): return s.ewm(span=n,adjust=False).mean()
def sma(s,n): return s.rolling(n).mean()
def wil(s,n): return s.ewm(alpha=1.0/n,adjust=False).mean()
def kij(h,l,n): return (h.rolling(n).max()+l.rolling(n).min())/2.0
def tr(h,l,c):
    pc=c.shift(1); return pd.concat([(h-l),(h-pc).abs(),(l-pc).abs()],axis=1).max(axis=1)
def atr(h,l,c,n): return wil(tr(h,l,c),n)

CONTRACT=1.0; LOT=0.01

def load_m1(path):
    d=pd.read_csv(path,parse_dates=["datetime"]).set_index("datetime").sort_index()
    d=d[~d.index.duplicated()]; d["spread_usd"]=d["spread"]*0.01; return d

def resample(d,minutes):
    rule=f"{minutes}min"
    return d.resample(rule,label="right",closed="right").agg(
        {"open":"first","high":"max","low":"min","close":"last",
         "tick_volume":"sum","spread_usd":"mean"}).dropna()

def prep(df):
    d=df.copy()
    d["ema50"]=ema(d["close"],50); d["ema200"]=ema(d["close"],200)
    d["tk"]=kij(d["high"],d["low"],9); d["kj"]=kij(d["high"],d["low"],26)
    d["ssa"]=((d["tk"]+d["kj"])/2).shift(26); d["ssb"]=kij(d["high"],d["low"],52).shift(26)
    d["e5"]=ema(d["close"],5); d["e8"]=ema(d["close"],8); d["e21"]=ema(d["close"],21)
    d["s55"]=sma(d["close"],55); d["s100"]=sma(d["close"],100); d["s200"]=sma(d["close"],200)
    up=((d["e5"]>d["e8"])&(d["e8"]>d["e21"])&(d["e21"]>d["s55"])&(d["s55"]>d["s100"])
        &(d["s100"]>d["s200"])&(d["close"]>d["kj"])&(d["kj"]>d["s200"]))
    dn=((d["e5"]<d["e8"])&(d["e8"]<d["e21"])&(d["e21"]<d["s55"])&(d["s55"]<d["s100"])
        &(d["s100"]<d["s200"])&(d["close"]<d["kj"])&(d["kj"]<d["s200"]))
    d["stack"]=np.where(up,1,np.where(dn,-1,0))
    d["atr"]=atr(d["high"],d["low"],d["close"],14)
    d["fvg_bull"]=(d["low"]>d["high"].shift(2)).rolling(20).max().astype(bool)
    d["fvg_bear"]=(d["high"]<d["low"].shift(2)).rolling(20).max().astype(bool)
    return d

def run(d, sl_mult=1.8, tp_mult=3.0, use_stack=True, use_fvg=True, max_spread=40.0):
    o=d["open"].values; h=d["high"].values; l=d["low"].values; c=d["close"].values
    e50=d["ema50"].values; e200=d["ema200"].values
    tk=d["tk"].values; kj=d["kj"].values; ssa=d["ssa"].values; ssb=d["ssb"].values
    stack=d["stack"].values; av=d["atr"].values; spr=d["spread_usd"].values
    fb=d["fvg_bull"].values; fs=d["fvg_bear"].values
    hi20=d["high"].rolling(20).max().shift(1).values
    lo20=d["low"].rolling(20).min().shift(1).values
    idx=d.index
    bal=0.0; eq=[]; trades=[]; pos=None
    for i in range(210,len(d)):
        # gestion
        if pos is not None:
            isb=pos["dir"]>0
            slh=(l[i]<=pos["sl"]) if isb else (h[i]>=pos["sl"])
            tph=(h[i]>=pos["tp"]) if isb else (l[i]<=pos["tp"])
            ex=None
            if slh: ex=pos["sl"]
            elif tph: ex=pos["tp"]
            if ex is not None:
                g=(ex-pos["entry"])*LOT*CONTRACT*(1 if isb else -1)
                bal+=g; trades.append(g); pos=None
        eq.append(bal)
        if pos is not None: continue
        if np.isnan(ssa[i-1]) or np.isnan(av[i-1]) or av[i-1]<=0: continue
        if spr[i-1]>max_spread: continue
        c1=c[i-1]; ts=tk[i-1]; ks=kj[i-1]; ts2=tk[i-2]; ks2=kj[i-2]
        kt=max(ssa[i-1],ssb[i-1]); kb=min(ssa[i-1],ssb[i-1])
        bull=e50[i-1]>e200[i-1]; bear=e50[i-1]<e200[i-1]
        cBull=(ts>ks)and(ts2<ks2); cBear=(ts<ks)and(ts2>ks2)
        direction=0; entry=o[i]
        if bull and not(kb<=c1<=kt) and cBull and hi20[i-1]>0 and c1>hi20[i-1]:
            direction=1
        elif bear and not(kb<=c1<=kt) and cBear and lo20[i-1]>0 and c1<lo20[i-1]:
            direction=-1
        if direction==0: continue
        if use_stack and int(stack[i-1])!=direction: continue
        if use_fvg:
            if direction>0 and not bool(fb[i-1]): continue
            if direction<0 and not bool(fs[i-1]): continue
        sld=av[i-1]*sl_mult
        sl=entry-sld if direction>0 else entry+sld
        tp=entry+sld*tp_mult if direction>0 else entry-sld*tp_mult
        pos=dict(dir=direction,entry=entry,sl=sl,tp=tp)
    p=pd.Series(trades)
    n=len(p); w=int((p>0).sum())
    gp=p[p>0].sum() if n else 0; gl=-p[p<0].sum() if n else 0
    pf=(gp/gl) if gl>0 else (999 if gp>0 else 0)
    eqs=pd.Series(eq) if eq else pd.Series([0])
    dd=(eqs.cummax()-eqs).max()
    return dict(net=round(p.sum(),1), trades=n, wr=round(w/n*100,1) if n else 0,
                pf=round(pf,2), dd_usd=round(dd,1),
                avg=round(p.mean(),3) if n else 0)

def main():
    csv=sys.argv[1]
    print("Chargement M1...")
    m1=load_m1(csv)
    print(f"  {len(m1):,} bougies M1 | {m1.index[0]} -> {m1.index[-1]} "
          f"({(m1.index[-1]-m1.index[0]).days} jours)\n")
    print("="*92)
    print("COMPARAISON TF (meme fenetre M1, coeur fusion strat B + stack6MA + FVG, lot 0.01)")
    print("="*92)
    print(f"{'TF':>5} {'bougies':>8} {'net$':>8} {'trades':>7} {'WR':>6} {'PF':>6} {'DD$':>7} {'avg$':>7}")
    print("-"*92)
    rows=[]
    for mn,label in [(1,"M1"),(2,"M2"),(3,"M3"),(4,"M4"),(5,"M5"),(15,"M15"),(60,"H1")]:
        d=prep(resample(m1,mn))
        if len(d)<260:
            print(f"{label:>5} {len(d):>8}  (pas assez de bougies)"); continue
        m=run(d)
        rows.append((label,m,len(d)))
        print(f"{label:>5} {len(d):>8} {m['net']:>8.1f} {m['trades']:>7} {m['wr']:>5.1f}% "
              f"{m['pf']:>6.2f} {m['dd_usd']:>7.1f} {m['avg']:>7.3f}")
    print("-"*92)
    valid=[r for r in rows if r[1]['trades']>=15]
    if valid:
        best=max(valid,key=lambda x:x[1]['pf'])
        print(f"\nMeilleur PF (>=15 trades) : {best[0]}  PF={best[1]['pf']}  net={best[1]['net']}$  n={best[1]['trades']}")
    print("\nNote : fenetre courte (~2 mois) -> echantillon limite sur les petits TF.")
    print("M15/H1 sont valides separement sur 34 mois (voir rapports precedents).")

if __name__=="__main__":
    main()
