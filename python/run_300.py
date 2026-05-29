#!/usr/bin/env python3
"""Simulation config #4 (multi-TF + stack 6 MA) sur compte Exness 300 USD.
   Demontre l'effet du plancher de lot et des garde-fous risque.
"""
import sys
import numpy as np
import bt_engine as E

M15 = sys.argv[1]
print("Preparation...")
m15 = E.load_m15(M15); prep = E.prepare(m15, E.DEFAULT)
split = m15.index[int(len(m15)*0.70)]

def fmt(m):
    return (f"final={m['final']:>8.1f} net={m['net']:>8.1f} ret={m['ret_pct']:>7.1f}% "
            f"n={m['trades']:>4} WR={m['wr']:>5.1f}% PF={m['pf']:>5.2f} DD={m['max_dd']:>5.1f}%")
def R(cfg,**kw):
    m,_=E.run(m15,prep,cfg,**kw); return m

# Config #4 = sans partial/BE + RR2.5 SL1.5 + stack 6 MA
C4 = dict(use_partial=False, use_be=False, rr=2.5, atr_sl_mult=1.5, require_ma_stack=True)

print("\n"+"="*100)
print("CONFIG #4 selon le CAPITAL (1 lot = 1 BTC, lot min 0.01)")
print("="*100)
print("ATR(H1) moyen ~505 USD -> SL ~757 USD -> perte/0.01 lot ~7.6 USD\n")
for bal in [150, 300, 1000, 3000, 10000]:
    m = R(dict(C4, initial_balance=bal))
    risk_minlot_pct = 7.6 / bal * 100
    print(f"  Capital {bal:>6} USD | risque min-lot ~{risk_minlot_pct:4.1f}%/trade | {fmt(m)}")

print("\n"+"="*100)
print("COMPTE 300 USD — effet des GARDE-FOUS (un a la fois)")
print("="*100)
B = dict(C4, initial_balance=300.0)
configs = [
    ("0. Sans garde-fou",                       dict(B)),
    ("1. + kill-switch DD global 25%",          dict(B, global_dd_stop=25)),
    ("2. + kill-switch DD global 15%",          dict(B, global_dd_stop=15)),
    ("3. + skip si risque min-lot >3% equity",  dict(B, max_risk_pct_block=3.0)),
    ("4. + skip si risque >5% + DD global 25%", dict(B, max_risk_pct_block=5.0, global_dd_stop=25)),
]
for name,cfg in configs:
    print(f"{name:<44}{fmt(R(cfg))}")

print("\n"+"="*100)
print("IS / OOS — compte 300 + garde-fous (#4 ci-dessus)")
print("="*100)
best = dict(B, max_risk_pct_block=5.0, global_dd_stop=25)
mf=R(best); mis=R(best,end=split); moos=R(best,start=split)
print(f"  FULL: {fmt(mf)}")
print(f"  IS  : {fmt(mis)}")
print(f"  OOS : {fmt(moos)}")

# illustration levier : marge requise
print("\n"+"="*100)
print("LEVIER 1:2000 — marge requise (ne change PAS le risque)")
print("="*100)
price=70000; lot=0.01; notional=price*lot
for lev in [100, 500, 2000]:
    margin=notional/lev
    print(f"  Levier 1:{lev:<5} -> marge pour 0.01 BTC ({notional:.0f} USD notionnel) = {margin:6.2f} USD")
print(f"  => Avec 300 USD et 1:2000, tu peux ouvrir la position sans souci de marge.")
print(f"     MAIS si le SL saute, tu perds ~7.6 USD quel que soit le levier.")
