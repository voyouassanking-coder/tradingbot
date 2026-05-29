#!/usr/bin/env python3
"""Retest avec compte de depart 150 USD :
   - retrait des ordres a pertes prematurees (partial close + break-even)
   - ajout du filtre d'alignement des 6 MA (EMA5/8/21, SMA55/100/200) + Kijun
   Comparaisons systematiques + IS/OOS + walk-forward.
"""
import sys
import numpy as np
import pandas as pd
import bt_engine as E

M15 = sys.argv[1]
START_BAL = 150.0

print("Preparation indicateurs (avec stack 6 MA + Kijun)...")
m15 = E.load_m15(M15)
prep = E.prepare(m15, E.DEFAULT)
t0, t1 = m15.index[0], m15.index[-1]
split_date = m15.index[int(len(m15)*0.70)]
print(f"  {len(m15):,} bougies  {t0.date()} -> {t1.date()}  | split OOS @ {split_date.date()}\n")

def fmt(m):
    return (f"final={m['final']:>8.1f} net={m['net']:>8.1f} ret={m['ret_pct']:>7.1f}% "
            f"n={m['trades']:>4} WR={m['wr']:>5.1f}% PF={m['pf']:>5.2f} DD={m['max_dd']:>5.1f}%")

def R(cfg, start=None, end=None):
    m,_ = E.run(m15, prep, cfg, start=start, end=end)
    return m

# base de comparaison : compte 150, params EA originaux (avec partial/BE)
BAL = dict(initial_balance=START_BAL)

print("="*104)
print("RETEST — compte 150 USD")
print("="*104)

configs = [
    ("0. Baseline (partial+BE ON, params EA)", dict(BAL)),
    ("1. SANS partial/BE (retrait ordres premat.)", dict(BAL, use_partial=False, use_be=False)),
    ("2. #1 + RR2.5 + SL x1.5", dict(BAL, use_partial=False, use_be=False, rr=2.5, atr_sl_mult=1.5)),
    ("3. #2 + seance 8-12h (V1a)", dict(BAL, use_partial=False, use_be=False, rr=2.5, atr_sl_mult=1.5,
                                        session_start=8, session_end=12)),
    ("4. #2 + STACK 6 MA aligne", dict(BAL, use_partial=False, use_be=False, rr=2.5, atr_sl_mult=1.5,
                                       require_ma_stack=True)),
    ("5. #3 + STACK 6 MA aligne", dict(BAL, use_partial=False, use_be=False, rr=2.5, atr_sl_mult=1.5,
                                       session_start=8, session_end=12, require_ma_stack=True)),
    ("6. STACK 6 MA seul (RR2.5 SL1.5)", dict(BAL, use_partial=False, use_be=False, rr=2.5, atr_sl_mult=1.5,
                                              require_ma_stack=True, session_start=0, session_end=24)),
]

results=[]
for name,cfg in configs:
    m = R(cfg)
    results.append((name,cfg,m))
    print(f"{name:<46} {fmt(m)}")

print("\n" + "="*104)
print("VALIDATION IS / OOS des 3 meilleures configs (par PF)")
print("="*104)
ranked = sorted([r for r in results if r[2]["trades"]>=20], key=lambda x:-x[2]["pf"])[:3]
for name,cfg,m_full in ranked:
    m_is  = R(cfg, end=split_date)
    m_oos = R(cfg, start=split_date)
    print(f"\n{name}")
    print(f"   FULL: {fmt(m_full)}")
    print(f"   IS  : {fmt(m_is)}")
    print(f"   OOS : {fmt(m_oos)}")
    if m_oos["trades"]<10:
        v="INCONCLUSIF (trop peu de trades OOS)"
    elif m_oos["pf"]>=1.0 and m_oos["net"]>0:
        v="ROBUSTE"
    elif m_oos["pf"]>=0.9:
        v="ACCEPTABLE"
    else:
        v="SURAJUSTEMENT -> ECARTER"
    print(f"   >> {v}")

print("\n" + "="*104)
print("WALK-FORWARD (6 fenetres) — config #5 (#3 + stack MA) et #2 (reference)")
print("="*104)
edges = pd.date_range(t0, t1, periods=7)
for label, cfg in [("Config #2 (RR2.5 SL1.5, sans MA stack)",
                    dict(BAL, use_partial=False, use_be=False, rr=2.5, atr_sl_mult=1.5)),
                   ("Config #5 (#3 + stack 6 MA)",
                    dict(BAL, use_partial=False, use_be=False, rr=2.5, atr_sl_mult=1.5,
                         session_start=8, session_end=12, require_ma_stack=True))]:
    print(f"\n{label}")
    print(f"{'Fenetre':<26}{'n':>5}{'WR':>7}{'PF':>7}{'net':>9}{'DD':>7}")
    print("-"*61)
    pos=0; pfok=0
    for k in range(6):
        s,e = edges[k], edges[k+1]
        m = R(cfg, start=s, end=e)
        if m["net"]>0: pos+=1
        if m["pf"]>=1.0: pfok+=1
        print(f"{str(s.date())+'->'+str(e.date()):<26}{m['trades']:>5}{m['wr']:>6.1f}%{m['pf']:>7.2f}{m['net']:>9.1f}{m['max_dd']:>6.1f}%")
    print("-"*61)
    print(f"Profitables : {pos}/6   PF>=1 : {pfok}/6")
