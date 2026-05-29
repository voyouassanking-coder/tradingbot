#!/usr/bin/env python3
"""Validation rigoureuse anti-surajustement :
   1. Split 70% in-sample (IS) / 30% out-of-sample (OOS)
   2. Grid search des params cles sur IS, verification sur OOS
   3. Test combinaison V1a + V2g (sur IS, OOS, full)
   4. Walk-forward (fenetres glissantes)
"""
import sys
import itertools
import numpy as np
import pandas as pd
import bt_engine as E

M15 = sys.argv[1]

print("Chargement + preparation indicateurs (sur tout l'historique)...")
m15 = E.load_m15(M15)
prep = E.prepare(m15, E.DEFAULT)
t0, t1 = m15.index[0], m15.index[-1]
print(f"  {len(m15):,} bougies  {t0} -> {t1}\n")

# ---- Split chronologique 70/30 ----
split_idx = int(len(m15) * 0.70)
split_date = m15.index[split_idx]
print(f"Split 70/30 a {split_date}")
print(f"  IS  : {t0.date()} -> {split_date.date()}  ({split_idx:,} barres)")
print(f"  OOS : {split_date.date()} -> {t1.date()}  ({len(m15)-split_idx:,} barres)\n")

def fmt(m):
    return (f"net={m['net']:>8.0f} ret={m['ret_pct']:>6.1f}% n={m['trades']:>4} "
            f"WR={m['wr']:>5.1f}% PF={m['pf']:>5.2f} DD={m['max_dd']:>5.1f}% exp={m['expectancy']:>6.2f}")

def run_slice(cfg, start=None, end=None):
    m,_ = E.run(m15, prep, cfg, start=start, end=end)
    return m

# ==================================================================
# ETAPE 1 : GRID SEARCH SUR IS
# ==================================================================
print("="*100)
print("ETAPE 1 — GRID SEARCH sur IN-SAMPLE (70%)")
print("="*100)

# Famille de params issue des variantes gagnantes (V2g + seance)
grid = dict(
    session_start = [0, 8],
    session_end   = [12, 21],
    atr_sl_mult   = [1.0, 1.5, 2.0],
    rr            = [1.5, 2.0, 2.5],
    use_partial   = [False],     # confirme nefaste -> on fige a False
    use_be        = [False],
    atr_rank_max  = [None, 75],
)
keys = list(grid.keys())
combos = list(itertools.product(*[grid[k] for k in keys]))
print(f"Combinaisons testees : {len(combos)}\n")

is_results = []
for combo in combos:
    cfg = dict(zip(keys, combo))
    m = run_slice(cfg, end=split_date)
    is_results.append((cfg, m))

# Critere de selection : PF d'abord, puis net, avec garde-fou min de trades
valid = [(cfg,m) for cfg,m in is_results if m["trades"] >= 30]
valid.sort(key=lambda x: (x[1]["pf"], x[1]["net"]), reverse=True)

print("TOP 8 IN-SAMPLE (tri PF puis net, min 30 trades) :")
for cfg,m in valid[:8]:
    sset = f"{cfg['session_start']:02d}-{cfg['session_end']:02d}h"
    print(f"  SL{cfg['atr_sl_mult']} RR{cfg['rr']} {sset} ATRmax={str(cfg['atr_rank_max']):>4} | {fmt(m)}")

best_cfg, best_is = valid[0]
print(f"\n>> MEILLEUR IS : {best_cfg}")
print(f"   IS  : {fmt(best_is)}")

# ==================================================================
# ETAPE 2 : VERIFICATION OUT-OF-SAMPLE
# ==================================================================
print("\n" + "="*100)
print("ETAPE 2 — VERIFICATION OUT-OF-SAMPLE (30% jamais vus)")
print("="*100)
best_oos = run_slice(best_cfg, start=split_date)
print(f"   IS  : {fmt(best_is)}")
print(f"   OOS : {fmt(best_oos)}")

# Verdict surajustement
def verdict_overfit(is_m, oos_m):
    if oos_m["trades"] < 15:
        return "INCONCLUSIF (trop peu de trades OOS)"
    if oos_m["pf"] >= 1.0 and oos_m["net"] > 0:
        return "ROBUSTE (tient en OOS)"
    if oos_m["pf"] >= 0.9:
        return "ACCEPTABLE (leger recul mais coherent)"
    return "SURAJUSTEMENT PROBABLE (s'effondre en OOS) -> ECARTER"
print(f"\n>> VERDICT : {verdict_overfit(best_is, best_oos)}")

# On verifie aussi le TOP 3 pour voir la stabilite
print("\nControle du TOP 3 IS -> OOS :")
for cfg,m_is in valid[:3]:
    m_oos = run_slice(cfg, start=split_date)
    sset=f"{cfg['session_start']:02d}-{cfg['session_end']:02d}h"
    print(f"  SL{cfg['atr_sl_mult']} RR{cfg['rr']} {sset} ATRmax={str(cfg['atr_rank_max']):>4}")
    print(f"     IS : {fmt(m_is)}")
    print(f"     OOS: {fmt(m_oos)}  {verdict_overfit(m_is,m_oos)}")

# ==================================================================
# ETAPE 3 : COMBINAISON V1a + V2g
# ==================================================================
print("\n" + "="*100)
print("ETAPE 3 — COMBINAISON V1a (seance 8-12h) + V2g (sans partial/BE, RR2, SL x1.5)")
print("="*100)
combo_cfg = dict(session_start=8, session_end=12,
                 use_partial=False, use_be=False, rr=2.0, atr_sl_mult=1.5)
base = run_slice({})
combo_full = run_slice(combo_cfg)
combo_is   = run_slice(combo_cfg, end=split_date)
combo_oos  = run_slice(combo_cfg, start=split_date)
print(f"   BASELINE full : {fmt(base)}")
print(f"   V1a+V2g full  : {fmt(combo_full)}")
print(f"   V1a+V2g IS    : {fmt(combo_is)}")
print(f"   V1a+V2g OOS   : {fmt(combo_oos)}  {verdict_overfit(combo_is, combo_oos)}")

# ==================================================================
# ETAPE 4 : WALK-FORWARD (fenetres glissantes)
# ==================================================================
print("\n" + "="*100)
print("ETAPE 4 — WALK-FORWARD (fenetres glissantes ~6 mois)")
print("="*100)
print("Config testee = meilleur IS retenu :", best_cfg, "\n")

# Decoupe en N fenetres consecutives
N_WIN = 6
edges = pd.date_range(t0, t1, periods=N_WIN+1)
print(f"{'Fenetre':<26} {'trades':>7} {'WR':>6} {'PF':>6} {'net':>9} {'DD':>6}")
print("-"*70)
wf = []
for k in range(N_WIN):
    s, e = edges[k], edges[k+1]
    m = run_slice(best_cfg, start=s, end=e)
    wf.append(m)
    print(f"{str(s.date())+' -> '+str(e.date()):<26} {m['trades']:>7} {m['wr']:>5.1f}% "
          f"{m['pf']:>6.2f} {m['net']:>9.0f} {m['max_dd']:>5.1f}%")

pos_windows = sum(1 for m in wf if m["net"]>0)
pf_windows  = sum(1 for m in wf if m["pf"]>=1.0)
print("-"*70)
print(f"Fenetres profitables : {pos_windows}/{N_WIN}  |  PF>=1.0 : {pf_windows}/{N_WIN}")
if pos_windows >= N_WIN-1:
    print(">> ROBUSTE dans le temps")
elif pos_windows >= N_WIN*0.6:
    print(">> MOYENNEMENT robuste (depend du regime de marche)")
else:
    print(">> NON robuste (probable coup de chance sur certaines periodes)")

# Walk-forward AUSSI sur la combo V1a+V2g pour comparaison
print("\nWalk-forward sur V1a+V2g :")
print(f"{'Fenetre':<26} {'trades':>7} {'WR':>6} {'PF':>6} {'net':>9} {'DD':>6}")
print("-"*70)
wf2=[]
for k in range(N_WIN):
    s,e = edges[k], edges[k+1]
    m = run_slice(combo_cfg, start=s, end=e)
    wf2.append(m)
    print(f"{str(s.date())+' -> '+str(e.date()):<26} {m['trades']:>7} {m['wr']:>5.1f}% "
          f"{m['pf']:>6.2f} {m['net']:>9.0f} {m['max_dd']:>5.1f}%")
pos2=sum(1 for m in wf2 if m["net"]>0); pf2=sum(1 for m in wf2 if m["pf"]>=1.0)
print("-"*70)
print(f"Fenetres profitables : {pos2}/{N_WIN}  |  PF>=1.0 : {pf2}/{N_WIN}")
