#!/usr/bin/env python3
"""Analyse de la strategie M5 pure (6 MA + Kijun) : matrice de variantes,
   IS/OOS, walk-forward. Edge mesure en lot fixe 0.01 (USD)."""
import sys
import bt_m5_mastack as M

CSV = sys.argv[1]
print("Chargement M5 + indicateurs...")
d = M.prepare(M.load(CSV))
t0,t1 = d.index[0], d.index[-1]
split = d.index[int(len(d)*0.70)]
print(f"  {len(d):,} bougies M5  {t0.date()} -> {t1.date()}  | split OOS @ {split.date()}\n")

def fmt(m):
    return (f"net={m['net']:>8.1f} n={m['trades']:>4} WR={m['wr']:>5.1f}% PF={m['pf']:>5.2f} "
            f"DD={m['max_dd_usd']:>7.1f} exp={m['expectancy']:>6.3f} medbars={m['median_bars']:>3}")

def R(cfg, **kw):
    m,_ = M.run(d, cfg, **kw); return m

print("="*112)
print("MATRICE DE VARIANTES (lot 0.01, USD)")
print("="*112)
variants = [
    ("A. Entry=always, exit=stack_break, Kijun ON",   dict(entry="always", exit_mode="stack_break")),
    ("B. Entry=fresh,  exit=sltp (RR2 SL1.5)",        dict(entry="fresh",  exit_mode="sltp")),
    ("C. Entry=fresh,  exit=stack_break",             dict(entry="fresh",  exit_mode="stack_break")),
    ("D. Entry=pullback, exit=sltp (RR2 SL1.5)",      dict(entry="pullback",exit_mode="sltp")),
    ("E. Entry=pullback, exit=stack_break",           dict(entry="pullback",exit_mode="stack_break")),
    ("F. Entry=pullback, exit=sltp_or_break",         dict(entry="pullback",exit_mode="sltp_or_break")),
    ("G. D + RR3.0",                                  dict(entry="pullback",exit_mode="sltp",rr=3.0)),
    ("H. D + RR1.5 SL1.0 (scalp serre)",              dict(entry="pullback",exit_mode="sltp",rr=1.5,atr_sl_mult=1.0)),
    ("I. D sans Kijun",                               dict(entry="pullback",exit_mode="sltp",use_kijun=False)),
    ("J. D + session 8-21",                           dict(entry="pullback",exit_mode="sltp",use_session=True)),
    ("K. D + time_stop 12 bougies",                   dict(entry="pullback",exit_mode="sltp",time_stop_bars=12)),
    ("L. fresh + sltp_or_break + RR2.5",              dict(entry="fresh",exit_mode="sltp_or_break",rr=2.5)),
]
res=[]
for name,cfg in variants:
    m=R(cfg); res.append((name,cfg,m))
    print(f"{name:<46}{fmt(m)}")

print("\nTOP 5 par PF (min 40 trades):")
for name,cfg,m in sorted([r for r in res if r[2]['trades']>=40], key=lambda x:-x[2]['pf'])[:5]:
    print(f"  {name:<46}{fmt(m)}")
print("\nTOP 5 par net (min 40 trades):")
for name,cfg,m in sorted([r for r in res if r[2]['trades']>=40], key=lambda x:-x[2]['net'])[:5]:
    print(f"  {name:<46}{fmt(m)}")

# IS/OOS sur top 3 PF
print("\n"+"="*112)
print("VALIDATION IS/OOS (top 3 par PF, min 40 trades)")
print("="*112)
top=sorted([r for r in res if r[2]['trades']>=40], key=lambda x:-x[2]['pf'])[:3]
for name,cfg,mf in top:
    mis=R(cfg,end=split); moos=R(cfg,start=split)
    print(f"\n{name}")
    print(f"   FULL: {fmt(mf)}")
    print(f"   IS  : {fmt(mis)}")
    print(f"   OOS : {fmt(moos)}")
    if moos['trades']<15: v="INCONCLUSIF (peu de trades OOS)"
    elif moos['pf']>=1.0 and moos['net']>0: v="ROBUSTE"
    elif moos['pf']>=0.9: v="ACCEPTABLE"
    else: v="SURAJUSTEMENT -> ECARTER"
    print(f"   >> {v}")

# Walk-forward sur le meilleur PF
import pandas as pd
print("\n"+"="*112)
print("WALK-FORWARD 6 fenetres — meilleure config par PF")
print("="*112)
best_name,best_cfg,_=top[0]
print(f"Config : {best_name}\n")
edges=pd.date_range(t0,t1,periods=7)
print(f"{'Fenetre':<26}{'n':>5}{'WR':>7}{'PF':>7}{'net':>9}{'DD':>8}")
print("-"*62)
pos=0;pfok=0
for k in range(6):
    s,e=edges[k],edges[k+1]; m=R(best_cfg,start=s,end=e)
    if m['net']>0:pos+=1
    if m['pf']>=1.0:pfok+=1
    print(f"{str(s.date())+'->'+str(e.date()):<26}{m['trades']:>5}{m['wr']:>6.1f}%{m['pf']:>7.2f}{m['net']:>9.1f}{m['max_dd_usd']:>8.1f}")
print("-"*62)
print(f"Profitables : {pos}/6   PF>=1 : {pfok}/6")
