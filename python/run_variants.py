#!/usr/bin/env python3
"""Teste les ameliorations UNE PAR UNE contre la baseline.
   Chaque variante = baseline + UN seul changement.
"""
import sys
import bt_engine as E

M15 = sys.argv[1]

print("Chargement + preparation des indicateurs (une fois)...")
m15 = E.load_m15(M15)
prep = E.prepare(m15, E.DEFAULT)
print(f"  {len(m15):,} bougies M15  {m15.index[0]} -> {m15.index[-1]}\n")

# Baseline
base, _ = E.run(m15, prep, {})

VARIANTS = [
    # --- Filtre de seance : eviter les pires heures (12-17 + 19-20) ---
    ("V1a Session 8-12h seulement",          dict(session_start=8,  session_end=12)),
    ("V1b Session 9-11h + 18h (best hours)",  dict(session_start=9,  session_end=11)),
    ("V1c Exclure 12-20h (garder 8-12)",      dict(session_start=8,  session_end=12)),

    # --- Ajustement stop / objectif ---
    ("V2a SL x1.5",                           dict(atr_sl_mult=1.5)),
    ("V2b SL x2.0",                           dict(atr_sl_mult=2.0)),
    ("V2c RR 2.0 (TP plus loin)",             dict(rr=2.0)),
    ("V2d RR 3.0",                            dict(rr=3.0)),
    ("V2e Sans partial ni BE (laisser courir)", dict(use_partial=False, use_be=False)),
    ("V2f Partial plus loin (+400 USD)",      dict(partial_usd=400.0)),
    ("V2g Sans partial + RR2 + SL x1.5",      dict(use_partial=False, use_be=False, rr=2.0, atr_sl_mult=1.5)),

    # --- Filtre de tendance ---
    ("V3a SELL only (BUY desactive)",         dict(allow_buy=False)),
    ("V3b Tendance forte |dist EMA200|>=1.5%", dict(min_dist_ema200_pct=1.5)),
    ("V3c Tendance forte |dist EMA200|>=2.5%", dict(min_dist_ema200_pct=2.5)),

    # --- Filtre de volatilite (ATR) ---
    ("V4a ATR rank 25-75 (eviter extremes)",  dict(atr_rank_min=25, atr_rank_max=75)),
    ("V4b ATR rank <=75 (eviter vol haute)",  dict(atr_rank_max=75)),
    ("V4c ATR rank <=50 (vol basse/moyenne)", dict(atr_rank_max=50)),

    # --- Sortie sur signal oppose ---
    ("V5a Exit signal oppose (no partial/BE)", dict(exit_on_opposite=True, use_partial=False, use_be=False)),
]

def fmt(m):
    return (f"net={m['net']:>9.0f}  ret={m['ret_pct']:>7.1f}%  "
            f"n={m['trades']:>4}  WR={m['wr']:>5.1f}%  PF={m['pf']:>5.2f}  "
            f"DD={m['max_dd']:>5.1f}%  exp={m['expectancy']:>6.2f}")

print("="*108)
print(f"{'BASELINE':<42} {fmt(base)}")
print("="*108)

results=[("BASELINE", base)]
for name, cfg in VARIANTS:
    m,_ = E.run(m15, prep, cfg)
    results.append((name, m))
    # verdict
    better = (m["net"] > base["net"]) and (m["pf"] > base["pf"])
    tag = "✓ MIEUX" if better else ("~ partiel" if m["net"]>base["net"] or m["pf"]>base["pf"] else "✗ pire")
    print(f"{name:<42} {fmt(m)}  {tag}")

print("="*108)
print("\nTOP 5 par profit net :")
for name,m in sorted(results, key=lambda x:-x[1]["net"])[:5]:
    print(f"  {name:<42} net={m['net']:>9.0f}  PF={m['pf']:.2f}  DD={m['max_dd']:.1f}%  WR={m['wr']:.1f}%")
print("\nTOP 5 par profit factor :")
for name,m in sorted(results, key=lambda x:-x[1]["pf"])[:5]:
    print(f"  {name:<42} PF={m['pf']:>5.2f}  net={m['net']:>9.0f}  DD={m['max_dd']:.1f}%")
