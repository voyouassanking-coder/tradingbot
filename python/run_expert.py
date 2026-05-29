#!/usr/bin/env python3
"""Test des suggestions expert (ADX, Volume) UNE A UNE sur la fusion finale,
   TF M30 (defaut), IS/OOS + walk-forward."""
import sys
import pandas as pd
import run_fusion as F

CSV=sys.argv[1]
print("Preparation (TF base M30)...")
m15=F.load_m15(CSV)
h1,h4,d1=F.prep(m15, base_rule="30min")
F.BAL0=3000.0
split=m15.index[int(len(m15)*0.70)]

BASE=dict(require_ma_stack=True,require_fvg=True,sl_mult=1.8,tp_mult=3.0,min_conf=3)
def R(extra,**kw):
    cfg=dict(BASE); cfg.update(extra); return F.run(h1,h4,d1,cfg,**kw)
def fmt(m):
    return (f"net={m['net']:>8.1f} n={m['trades']:>4} WR={m['wr']:>5.1f}% PF={m['pf']:>5.2f} "
            f"DD={m['max_dd']:>5.1f}% sem+={m['wk_pct']:>5.1f}% medWk={m['med_wk']:>6.1f}")
def wf(cfg):
    edges=pd.date_range(m15.index[0],m15.index[-1],periods=7); pos=0
    for k in range(6):
        m=F.run(h1,h4,d1,cfg,start=edges[k],end=edges[k+1])
        if m['net']>0: pos+=1
    return pos

print("\n"+"="*104)
print("SUGGESTIONS EXPERT — UNE A UNE (TF M30, vs fusion de reference)")
print("="*104)
tests=[
    ("REF fusion M30 (stack+FVG)",   {}),
    ("+ ADX > 20",                   dict(use_adx=True, adx_min=20)),
    ("+ ADX > 25",                   dict(use_adx=True, adx_min=25)),
    ("+ ADX > 30",                   dict(use_adx=True, adx_min=30)),
    ("+ Volume > moyenne (x1.0)",    dict(use_volume=True, vol_mult=1.0)),
    ("+ Volume > moyenne (x1.3)",    dict(use_volume=True, vol_mult=1.3)),
]
ref=None
for name,ex in tests:
    m=R(ex)
    if ref is None: ref=m
    tag=""
    if name.startswith("+"):
        if m["trades"]<20: tag="  ~ peu de trades"
        elif m["pf"]>ref["pf"] and m["wk_pct"]>=ref["wk_pct"]-1: tag="  ✓ ameliore"
        elif m["pf"]>ref["pf"]: tag="  ~ PF+ mais regularite-"
        else: tag="  ✗ pas mieux"
    print(f"{name:<32}{fmt(m)}{tag}")

print("\n"+"="*104)
print("VALIDATION IS/OOS + WALK-FORWARD des candidats prometteurs")
print("="*104)
cands=[
    ("ADX>25", dict(use_adx=True, adx_min=25)),
    ("ADX>20", dict(use_adx=True, adx_min=20)),
    ("Volume x1.0", dict(use_volume=True, vol_mult=1.0)),
    ("ADX>25 + Volume x1.0", dict(use_adx=True, adx_min=25, use_volume=True, vol_mult=1.0)),
]
for name,ex in cands:
    cfg=dict(BASE); cfg.update(ex)
    mf=R(ex); mis=R(ex,end=split); moos=R(ex,start=split); w=wf(cfg)
    print(f"\n{name}")
    print(f"   FULL: {fmt(mf)}")
    print(f"   IS  : {fmt(mis)}")
    print(f"   OOS : {fmt(moos)}")
    print(f"   walk-forward : {w}/6 fenetres +")
    v=("ROBUSTE" if moos['trades']>=15 and moos['pf']>=1.0 and moos['net']>0 and w>=4
       else "INCONCLUSIF (peu de trades)" if moos['trades']<15 else "faible")
    print(f"   >> {v}")
