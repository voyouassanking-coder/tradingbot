#!/usr/bin/env python3
"""Fusion GoldStorm + stack 6 MA + garde-fous risque.
   Teste l'ajout UN element a la fois, avec metrique de REGULARITE HEBDO.
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

BAL0=3000.0; CONTRACT=1.0; VMIN=0.01; VSTEP=0.01

DEFAULT=dict(
    sl_mult=1.8, tp_mult=3.6, min_conf=3, atr_min=0.8, risk_pct=1.0,
    require_ma_stack=False,      # F1
    max_risk_pct=None,           # F2
    global_dd_stop=None,         # F3
    use_session=False, sess_start=0, sess_end=24,
    run_A=True, run_B=True, run_C=True,
    # --- affinage entrees SMC (testes un a un) ---
    require_engulf=False,   # bougie de signal = engulfing dans le sens
    require_ote=False,      # entree dans zone OTE 0.62-0.79 du dernier swing
    require_fvg=False,      # FVG recent dans le sens du trade
    ipda_filter=False,      # premium/discount IPDA 20j (long en discount, short en premium)
    d1_mode=False,          # exige accord avec la bougie D1 EN COURS (open->close)
    ote_lo=0.62, ote_hi=0.79, swing_lb=30, fvg_lb=20, ipda_days=20,
)

def load_m15(path):
    d=pd.read_csv(path,parse_dates=["datetime"]).set_index("datetime").sort_index()
    d=d[~d.index.duplicated()]; d["spread_usd"]=d["spread"]*0.01; return d
def rs(d,rule):
    return d.resample(rule,label="right",closed="right").agg(
        {"open":"first","high":"max","low":"min","close":"last","tick_volume":"sum"}).dropna()

def prep(m15):
    h1=rs(m15,"1h"); h4=rs(m15,"4h"); d1=rs(m15,"1D")
    for df in (h1,h4):
        df["atr"]=atr(df["high"],df["low"],df["close"],14)
    h1["tenkan"]=tenkan(h1["high"],h1["low"],9)
    h1["kijun"]=kijun(h1["high"],h1["low"],26)
    h1["ssa"]=((h1["tenkan"]+h1["kijun"])/2).shift(26)
    h1["ssb"]=kijun(h1["high"],h1["low"],52).shift(26)
    h1["ema50"]=ema(h1["close"],50); h1["ema200"]=ema(h1["close"],200)
    # stack 6 MA + Kijun sur H1
    h1["e5"]=ema(h1["close"],5); h1["e8"]=ema(h1["close"],8); h1["e21"]=ema(h1["close"],21)
    h1["s55"]=sma(h1["close"],55); h1["s100"]=sma(h1["close"],100); h1["s200"]=sma(h1["close"],200)
    up=((h1["e5"]>h1["e8"])&(h1["e8"]>h1["e21"])&(h1["e21"]>h1["s55"])
        &(h1["s55"]>h1["s100"])&(h1["s100"]>h1["s200"])&(h1["close"]>h1["kijun"])&(h1["kijun"]>h1["s200"]))
    dn=((h1["e5"]<h1["e8"])&(h1["e8"]<h1["e21"])&(h1["e21"]<h1["s55"])
        &(h1["s55"]<h1["s100"])&(h1["s100"]<h1["s200"])&(h1["close"]<h1["kijun"])&(h1["kijun"]<h1["s200"]))
    h1["stack"]=np.where(up,1,np.where(dn,-1,0))
    d1["ema200d"]=ema(d1["close"],200)

    # --- precalculs SMC pour l'affinage des entrees ---
    o=h1["open"]; hh=h1["high"]; ll=h1["low"]; cc=h1["close"]
    # Engulfing (bougie fermee i vs i-1) : on lit ensuite en shift=1
    h1["eng_bull"]=((cc>o)&(cc.shift(1)<o.shift(1))&(cc>=o.shift(1))&(o<=cc.shift(1)))
    h1["eng_bear"]=((cc<o)&(cc.shift(1)>o.shift(1))&(cc<=o.shift(1))&(o>=cc.shift(1)))
    # Swing pour OTE (sur swing_lb barres, decale)
    h1["sw_hi"]=hh.rolling(30).max()
    h1["sw_lo"]=ll.rolling(30).min()
    # FVG 3 bougies : bull = low[i] > high[i-2] ; bear = high[i] < low[i-2]
    h1["fvg_bull"]=(ll>hh.shift(2))
    h1["fvg_bear"]=(hh<ll.shift(2))
    h1["fvg_bull_any"]=h1["fvg_bull"].rolling(20).max().astype(bool)
    h1["fvg_bear_any"]=h1["fvg_bear"].rolling(20).max().astype(bool)
    # IPDA premium/discount sur 20 jours (~480 H1)
    n=480
    rngHi=hh.rolling(n).max(); rngLo=ll.rolling(n).min()
    mid=(rngHi+rngLo)/2.0
    h1["ipda_discount"]=(cc<mid)   # zone "pas chere" -> long
    h1["ipda_premium"]=(cc>mid)    # zone "chere" -> short
    # open de la bougie D1 EN COURS (premier open du jour, propage)
    h1["day_open"]=h1.groupby(h1.index.normalize())["open"].transform("first")
    return h1,h4,d1

def calc_lot(bal,sl_dist,risk_pct):
    if sl_dist<=0: return VMIN
    lot=np.floor(bal*risk_pct/100.0/(sl_dist*CONTRACT)/VSTEP)*VSTEP
    return max(VMIN,round(lot,2))

def run(h1,h4,d1,cfg,start=None,end=None,full=False):
    c=dict(DEFAULT); c.update(cfg)
    idx=h1.index; i0,i1=0,len(h1)
    if start: i0=int(idx.searchsorted(pd.Timestamp(start)))
    if end:   i1=int(idx.searchsorted(pd.Timestamp(end),side="right"))
    bal=BAL0; eq=[]; eqt=[]; trades=[]; pos=None
    peak=BAL0; halted=False
    SLm=c["sl_mult"]; TPm=c["tp_mult"]; MC=c["min_conf"]; AM=c["atr_min"]

    H=h1.to_dict("records")  # plus rapide
    for i in range(max(i0,210),i1):
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
                bal+=g; trades.append(dict(t=idx[i],pnl=g)); pos=None
        eq.append(bal); eqt.append(idx[i])
        if bal>peak: peak=bal
        if c["global_dd_stop"] is not None and (peak-bal)/peak*100>=c["global_dd_stop"]:
            halted=True
        if halted or pos is not None: continue
        if av<AM: continue
        if c["use_session"] and not (c["sess_start"]<=idx[i].hour<c["sess_end"]): continue
        # filtre stack 6 MA
        stack=int(r1["stack"])
        kt=max(ssa,ssb); kb=min(ssa,ssb)
        bull=ema50>ema200; bear=ema50<ema200
        aboveK=c1>kt; belowK=c1<kb
        aboveKj=c1>ks; belowKj=c1<ks
        def score(trend,abk,abkj,cass): return int(trend)+int(abk)+int(abkj)+int(cass)+int(av>AM)
        entry=r["open"]; took=False; direction=0; sl=tp=0

        # Strat B : cassure H1 + cross T/K
        if c["run_B"]:
            hh=h1["high"].iloc[max(0,i-21):i-1].max(); ll=h1["low"].iloc[max(0,i-21):i-1].min()
            ts2=h1["tenkan"].iloc[i-2]; ks2=h1["kijun"].iloc[i-2]
            cBull=(ts>ks)and(ts2<ks2); cBear=(ts<ks)and(ts2>ks2)
            if bull and not(kb<=c1<=kt) and cBull and c1>hh and score(bull,aboveK,aboveKj,True)>=MC:
                direction=1; sl=entry-SLm*av; tp=entry+TPm*av; took=True
            elif bear and not(kb<=c1<=kt) and cBear and c1<ll and score(bear,belowK,belowKj,True)>=MC:
                direction=-1; sl=entry+SLm*av; tp=entry-TPm*av; took=True
        # Strat C : D1 trend + pullback kijun
        if not took and c["run_C"]:
            dp=d1.index.searchsorted(idx[i],side="right")
            if dp>200:
                e2d=d1["ema200d"].iloc[dp-1]; cD=d1["close"].iloc[dp-1]
                tBull=(cD>e2d)and bull; tBear=(cD<e2d)and bear
                pbBull=(r1["low"]<=ks*1.002)and(c1>ks)and(c1>o1)
                pbBear=(r1["high"]>=ks*0.998)and(c1<ks)and(c1<o1)
                if tBull and pbBull and aboveK and score(bull,aboveK,aboveKj,True)>=MC:
                    direction=1; sl=entry-SLm*2.0*av; tp=entry+TPm*2.5*av; took=True
                elif tBear and pbBear and belowK and score(bear,belowK,belowKj,True)>=MC:
                    direction=-1; sl=entry+SLm*2.0*av; tp=entry-TPm*2.5*av; took=True

        if not took or direction==0: continue
        # FILTRE STACK 6 MA (fusion)
        if c["require_ma_stack"] and stack!=direction: continue

        # ===== AFFINAGE ENTREES SMC (testes un a un) =====
        if c["require_engulf"]:
            if direction>0 and not bool(r1["eng_bull"]): continue
            if direction<0 and not bool(r1["eng_bear"]): continue
        if c["require_ote"]:
            swhi=r1["sw_hi"]; swlo=r1["sw_lo"]; rng=swhi-swlo
            if rng<=0: continue
            if direction>0:
                lo=swhi-rng*c["ote_hi"]; hi=swhi-rng*c["ote_lo"]
                if not (lo<=c1<=hi): continue
            else:
                lo=swlo+rng*c["ote_lo"]; hi=swlo+rng*c["ote_hi"]
                if not (lo<=c1<=hi): continue
        if c["require_fvg"]:
            if direction>0 and not bool(r1["fvg_bull_any"]): continue
            if direction<0 and not bool(r1["fvg_bear_any"]): continue
        if c["ipda_filter"]:
            if direction>0 and not bool(r1["ipda_discount"]): continue
            if direction<0 and not bool(r1["ipda_premium"]): continue
        if c["d1_mode"]:
            # accord avec la bougie D1 EN COURS : sens = close H1 courant vs open du jour
            dayopen=r1["day_open"]
            if np.isnan(dayopen): continue
            d1dir = 1 if c1>dayopen else -1
            if d1dir!=direction: continue

        sl_dist=abs(entry-sl)
        lot=calc_lot(bal,sl_dist,c["risk_pct"])
        # garde-fou risque
        if c["max_risk_pct"] is not None:
            if sl_dist*lot*CONTRACT > bal*c["max_risk_pct"]/100.0: continue
        pos=dict(dir=direction,entry=entry,sl=sl,tp=tp,lot=lot)

    if full:
        return _metrics(trades,eq,eqt), trades, eq, eqt
    return _metrics(trades,eq,eqt)

def _metrics(trades,eq,eqt):
    p=pd.Series([t["pnl"] for t in trades])
    n=len(p); w=int((p>0).sum()); l=int((p<0).sum())
    gp=p[p>0].sum() if n else 0; gl=-p[p<0].sum() if n else 0
    pf=(gp/gl) if gl>0 else (999 if gp>0 else 0)
    eqs=pd.Series(eq,index=pd.DatetimeIndex(eqt)) if eq else pd.Series([BAL0])
    dd=((eqs.cummax()-eqs)/eqs.cummax()*100).max()
    # regularite hebdo
    wk_pos=wk_tot=0; wk_pct=0.0; med_wk=0.0
    if n:
        tdf=pd.DataFrame(trades).set_index("t")
        wk=tdf["pnl"].resample("W").sum()
        wk=wk[wk!=0]   # semaines avec activite
        wk_tot=len(wk); wk_pos=int((wk>0).sum())
        wk_pct=round(wk_pos/wk_tot*100,1) if wk_tot else 0.0
        med_wk=round(wk.median(),1) if wk_tot else 0.0
    return dict(net=round(eqs.iloc[-1]-BAL0,1), ret=round((eqs.iloc[-1]-BAL0)/BAL0*100,1),
        trades=n, wr=round(w/n*100,1) if n else 0, pf=round(pf,2),
        max_dd=round(dd,1) if n else 0,
        wk_pos=wk_pos, wk_tot=wk_tot, wk_pct=wk_pct, med_wk=med_wk)

def main():
    csv=sys.argv[1]
    print("Preparation...")
    m15=load_m15(csv); h1,h4,d1=prep(m15)
    split=m15.index[int(len(m15)*0.70)]
    print(f"  H1={len(h1):,} | {m15.index[0].date()}->{m15.index[-1].date()} | split {split.date()}\n")

    def fmt(m):
        return (f"net={m['net']:>8.1f} ret={m['ret']:>6.1f}% n={m['trades']:>4} WR={m['wr']:>5.1f}% "
                f"PF={m['pf']:>5.2f} DD={m['max_dd']:>5.1f}% | sem.gagn={m['wk_pct']:>5.1f}% "
                f"({m['wk_pos']}/{m['wk_tot']}) medWk={m['med_wk']:>6.1f}")
    def R(cfg,**kw): return run(h1,h4,d1,cfg,**kw)

    print("="*120)
    print("FUSION — AJOUT D'UN ELEMENT A LA FOIS (compte 3000 USD)")
    print("="*120)
    steps=[
        ("F0 GoldStorm base (reference)",          dict()),
        ("F1 + filtre stack 6 MA",                 dict(require_ma_stack=True)),
        ("F2 + garde-fou risque max 3%",           dict(require_ma_stack=True, max_risk_pct=3.0)),
        ("F3 + kill-switch DD global 20%",         dict(require_ma_stack=True, max_risk_pct=3.0, global_dd_stop=20)),
    ]
    base=None
    for name,cfg in steps:
        m=R(cfg)
        if base is None: base=m
        print(f"{name:<40}{fmt(m)}")

    print("\n"+"="*120)
    print("OPTIMISATION (sur la fusion F2) — SL/TP/MinConf, critere regularite hebdo + PF")
    print("="*120)
    best=None; bestcfg=None
    grid=[]
    for slm in [1.5,1.8,2.2]:
        for tpm in [3.0,3.6,4.5]:
            for mc in [3,4]:
                grid.append(dict(require_ma_stack=True,max_risk_pct=3.0,sl_mult=slm,tp_mult=tpm,min_conf=mc))
    rows=[]
    for cfg in grid:
        m=R(cfg); rows.append((cfg,m))
    # tri : regularite hebdo d'abord, puis PF
    rows.sort(key=lambda x:(x[1]["wk_pct"],x[1]["pf"]),reverse=True)
    print(f"{'SL':>4}{'TP':>5}{'MC':>3}  {'':<2}"+ "  metriques")
    for cfg,m in rows[:8]:
        print(f"{cfg['sl_mult']:>4}{cfg['tp_mult']:>5}{cfg['min_conf']:>3}  {fmt(m)}")
    bestcfg,best=rows[0]

    print("\n"+"="*120)
    print(f"MEILLEURE CONFIG : SL{bestcfg['sl_mult']} TP{bestcfg['tp_mult']} MC{bestcfg['min_conf']} + stack6MA + risque3%")
    print("="*120)
    mf=R(bestcfg); mis=R(bestcfg,end=split); moos=R(bestcfg,start=split)
    print(f"  FULL: {fmt(mf)}")
    print(f"  IS  : {fmt(mis)}")
    print(f"  OOS : {fmt(moos)}")

    # walk-forward
    print("\n"+"="*120); print("WALK-FORWARD 6 fenetres"); print("="*120)
    edges=pd.date_range(m15.index[0],m15.index[-1],periods=7)
    posw=0
    for k in range(6):
        s,e=edges[k],edges[k+1]; m=R(bestcfg,start=s,end=e)
        if m["net"]>0: posw+=1
        print(f"  {str(s.date())}->{str(e.date())}: {fmt(m)}")
    print(f"\n  Fenetres profitables : {posw}/6")

if __name__=="__main__":
    main()
