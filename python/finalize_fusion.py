#!/usr/bin/env python3
"""Finalisation EA_FusionBTC : courbe d'equity + detail mensuel/hebdo
   de la config optimale, sur compte 300 USD (compte cible Exness).
"""
import sys
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
import run_fusion as F

CSV = sys.argv[1]
OUT = "backtest_results/fusion_equity.png"
START_BAL = 300.0   # compte cible

# config optimale validee — garde-fou 8% adapte au compte 300 USD
# (a 1000 USD+, utiliser 3% pour un DD ~10%)
CFG = dict(require_ma_stack=True, max_risk_pct=8.0, global_dd_stop=25.0,
           sl_mult=1.8, tp_mult=3.0, min_conf=3)

print("Preparation...")
m15 = F.load_m15(CSV); h1,h4,d1 = F.prep(m15)
F.BAL0 = START_BAL   # rejoue avec le capital cible
split = m15.index[int(len(m15)*0.70)]

m, trades, eq, eqt = F.run(h1,h4,d1,CFG, full=True)
eqs = pd.Series(eq, index=pd.DatetimeIndex(eqt))
tdf = pd.DataFrame(trades).set_index("t")

# Drawdown
dd = (eqs.cummax()-eqs)/eqs.cummax()*100.0

# Mensuel & hebdo
monthly = tdf["pnl"].resample("ME").sum()
weekly  = tdf["pnl"].resample("W").sum(); weekly=weekly[weekly!=0]
mo_pos = int((monthly>0).sum()); mo_tot=len(monthly[monthly!=0])
wk_pos = int((weekly>0).sum()); wk_tot=len(weekly)

print("\n================ FUSION FINALE (compte 300 USD) ================")
for k,v in m.items(): print(f"  {k:<10}: {v}")
print(f"\n  Mois gagnants    : {mo_pos}/{mo_tot} ({mo_pos/mo_tot*100:.0f}%)")
print(f"  Semaines gagn.   : {wk_pos}/{wk_tot} ({wk_pos/wk_tot*100:.0f}%)")
print(f"  Meilleur mois    : {monthly.max():+.1f} | Pire mois : {monthly.min():+.1f}")

# Plot
fig, ax = plt.subplots(2,1,figsize=(12,7),sharex=True,gridspec_kw={"height_ratios":[3,1]})
ax[0].plot(eqs.index, eqs.values, lw=1.3, color="#1b7837", label="Equity")
ax[0].axhline(START_BAL, color="grey", ls="--", lw=0.8, label="Capital initial")
ax[0].axvline(split, color="#d95f02", ls=":", lw=1.2, label="Split IS/OOS (70/30)")
ax[0].set_title("EA_FusionBTC v1 — BTCUSDm — compte 300 USD (SL1.8/TP3.0/MC3 + stack 6 MA)",
                fontweight="bold")
ax[0].set_ylabel("Equity (USD)"); ax[0].legend(loc="upper left"); ax[0].grid(alpha=.3)
txt=(f"Net {m['net']:+.1f} USD ({m['ret']:+.1f}%)\nPF {m['pf']} | DD {m['max_dd']}%\n"
     f"Trades {m['trades']} | WR {m['wr']}%\nSemaines + {m['wk_pct']}% | Mois + {mo_pos}/{mo_tot}")
ax[0].text(.99,.02,txt,transform=ax[0].transAxes,ha="right",va="bottom",
           family="monospace",fontsize=9,
           bbox=dict(boxstyle="round,pad=0.4",fc="white",ec="grey",alpha=.85))
ax[1].fill_between(dd.index, dd.values, 0, color="#d62728", alpha=.5)
ax[1].set_ylabel("Drawdown %"); ax[1].set_xlabel("Date"); ax[1].grid(alpha=.3)
ax[1].xaxis.set_major_locator(mdates.MonthLocator(interval=3))
ax[1].xaxis.set_major_formatter(mdates.DateFormatter("%Y-%m"))
fig.tight_layout(); fig.savefig(OUT, dpi=130); plt.close(fig)
print(f"\n  Courbe : {OUT}")

# detail mensuel
print("\n  --- P&L mensuel (USD) ---")
for d,v in monthly[monthly!=0].items():
    print(f"    {d.strftime('%Y-%m')} : {v:+8.1f}")
