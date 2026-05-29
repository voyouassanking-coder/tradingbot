#!/usr/bin/env python3
"""Impact de l'affinage des entrees (engulfing / OTE / FVG / IPDA / D1)
   ajoute UN A LA FOIS sur la fusion validee. Compte 3000 USD (edge pur)."""
import sys
import run_fusion as F

CSV=sys.argv[1]
print("Preparation...")
m15=F.load_m15(CSV); h1,h4,d1=F.prep(m15)
F.BAL0=3000.0
split=m15.index[int(len(m15)*0.70)]

BASE=dict(require_ma_stack=True,sl_mult=1.8,tp_mult=3.0,min_conf=3)
def R(extra,**kw):
    cfg=dict(BASE); cfg.update(extra); return F.run(h1,h4,d1,cfg,**kw)
def fmt(m):
    return (f"net={m['net']:>8.1f} n={m['trades']:>4} WR={m['wr']:>5.1f}% PF={m['pf']:>5.2f} "
            f"DD={m['max_dd']:>5.1f}% sem+={m['wk_pct']:>5.1f}% medWk={m['med_wk']:>6.1f}")

print("\n"+"="*108)
print("AFFINAGE DES ENTREES — UN A LA FOIS (vs fusion de reference)")
print("="*108)
tests=[
    ("REF fusion (stack6MA)",        {}),
    ("+ Engulfing selon tendance",   dict(require_engulf=True)),
    ("+ OTE Fibonacci 0.62-0.79",    dict(require_ote=True)),
    ("+ FVG retest (sens trade)",    dict(require_fvg=True)),
    ("+ IPDA premium/discount 20j",  dict(ipda_filter=True)),
    ("+ Mode D1 en cours",           dict(d1_mode=True)),
]
ref=None
for name,ex in tests:
    m=R(ex)
    if ref is None: ref=m
    tag=""
    if name!="REF fusion (stack6MA)":
        better = m["pf"]>ref["pf"] and m["trades"]>=20
        tag = "  ✓ ameliore" if better else ("  ~ peu de trades" if m["trades"]<20 else "  ✗ pas mieux")
    print(f"{name:<32}{fmt(m)}{tag}")

print("\n"+"="*108)
print("COMBINAISONS prometteuses (+ IS/OOS)")
print("="*108)
combos=[
    ("Engulf + IPDA",            dict(require_engulf=True, ipda_filter=True)),
    ("IPDA seul",                dict(ipda_filter=True)),
    ("Engulf seul",             dict(require_engulf=True)),
    ("D1 mode + IPDA",          dict(d1_mode=True, ipda_filter=True)),
]
for name,ex in combos:
    mf=R(ex); mis=R(ex,end=split); moos=R(ex,start=split)
    print(f"\n{name}")
    print(f"   FULL: {fmt(mf)}")
    print(f"   IS  : {fmt(mis)}")
    print(f"   OOS : {fmt(moos)}")
    v=("ROBUSTE" if moos['trades']>=15 and moos['pf']>=1.0 and moos['net']>0
       else "INCONCLUSIF (peu de trades)" if moos['trades']<15 else "faible OOS")
    print(f"   >> {v}")
