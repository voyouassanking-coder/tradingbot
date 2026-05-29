#!/usr/bin/env python3
"""Genere un document Word exhaustif expliquant EA_FusionBTC v1.1."""
from docx import Document
from docx.shared import Pt, RGBColor, Inches
from docx.enum.text import WD_ALIGN_PARAGRAPH
import os

doc = Document()

# Styles de base
st = doc.styles["Normal"]
st.font.name = "Calibri"; st.font.size = Pt(11)

GREEN = RGBColor(0x1b,0x7a,0x37)
GREY  = RGBColor(0x55,0x55,0x55)

def h1(t):
    p=doc.add_heading(t, level=1)
    return p
def h2(t):
    return doc.add_heading(t, level=2)
def para(t, italic=False, bold=False, color=None):
    p=doc.add_paragraph(); r=p.add_run(t); r.italic=italic; r.bold=bold
    if color: r.font.color.rgb=color
    return p
def bullet(t, bold_prefix=None):
    p=doc.add_paragraph(style="List Bullet")
    if bold_prefix:
        r=p.add_run(bold_prefix); r.bold=True
        p.add_run(t)
    else:
        p.add_run(t)
    return p

def table(headers, rows):
    t=doc.add_table(rows=1, cols=len(headers)); t.style="Light Grid Accent 1"
    for i,hh in enumerate(headers):
        c=t.rows[0].cells[i]; c.text=""; r=c.paragraphs[0].add_run(hh); r.bold=True
    for row in rows:
        cells=t.add_row().cells
        for i,v in enumerate(row): cells[i].text=str(v)
    return t

# ====================== PAGE DE TITRE ======================
title=doc.add_paragraph(); title.alignment=WD_ALIGN_PARAGRAPH.CENTER
r=title.add_run("EA FUSION BTC"); r.bold=True; r.font.size=Pt(30); r.font.color.rgb=GREEN
sub=doc.add_paragraph(); sub.alignment=WD_ALIGN_PARAGRAPH.CENTER
r=sub.add_run("Expert Advisor MetaTrader 5 — Bitcoin (BTCUSD / BTCUSDm)"); r.font.size=Pt(14); r.font.color.rgb=GREY
sub2=doc.add_paragraph(); sub2.alignment=WD_ALIGN_PARAGRAPH.CENTER
r=sub2.add_run("Documentation technique et mode d'emploi — Version 1.1"); r.italic=True; r.font.size=Pt(12)
doc.add_paragraph()
para("Stratégie de suivi de tendance multi-confluence : Ichimoku + EMA50/200 + "
     "alignement de 6 moyennes mobiles + Fair Value Gap, avec gestion du risque "
     "renforcée (kill-switch, plafond de risque adapté aux petits comptes).",
     italic=True).alignment=WD_ALIGN_PARAGRAPH.CENTER
doc.add_paragraph()
warn=doc.add_paragraph()
r=warn.add_run("AVERTISSEMENT : le trading comporte un risque de perte. Aucun système "
   "ne garantit un gain à chaque période. Ce document et l'EA sont fournis à titre "
   "informatif et éducatif. Toujours valider en démo avant tout capital réel.")
r.italic=True; r.font.color.rgb=RGBColor(0xb0,0x00,0x00); r.font.size=Pt(10)
doc.add_page_break()

# ====================== 1. PRESENTATION ======================
h1("1. Présentation générale")
para("EA Fusion BTC est un robot de trading automatique (Expert Advisor) pour la "
     "plateforme MetaTrader 5, conçu spécifiquement pour le Bitcoin. Il a été "
     "développé puis affiné par une démarche rigoureuse de backtests sur 34 mois de "
     "données BTCUSDm (M15), avec validation hors-échantillon (out-of-sample) et "
     "analyse en fenêtres glissantes (walk-forward) pour éviter le surajustement.")
para("Le robot n'est PAS un scalpeur ultra-rapide : c'est un système de SUIVI DE "
     "TENDANCE qui sélectionne des entrées de haute qualité grâce à plusieurs filtres "
     "de confluence, puis laisse courir les gains avec un ratio risque/récompense élevé.")

h2("1.1 Caractéristiques clés")
bullet("Bitcoin (BTCUSD, BTCUSDm et variantes).", "Marché : ")
bullet("M30 par défaut (optimal gains + régularité), H1 en alternative (drawdown le plus bas).", "Timeframe : ")
bullet("Suivi de tendance multi-confluence (Ichimoku, EMA, stack 6 MA, FVG).", "Type : ")
bullet("ATR dynamique pour le Stop Loss, ratio 1:3 visé pour le Take Profit.", "Sorties : ")
bullet("Risque par trade plafonné, kill-switch de drawdown global, calcul de lot anti-erreur courtier.", "Sécurité : ")

h2("1.2 Résultats de backtest (34 mois, compte de référence)")
para("Chiffres issus de la simulation Python sur données historiques. Ils doivent "
     "être confirmés par le Strategy Tester MT5 en mode « every tick based on real ticks ». "
     "Le backtest reste une indication, pas une garantie de performance future.")
table(["Configuration","Profit Factor","Drawdown max","Gain","Trades","Semaines gagnantes","Walk-forward"],
      [["M30 + ADX>20 (défaut)","1.57","6.6 %","+50 %","157","56.7 %","6/6 fenêtres +"],
       ["M30 sans ADX","1.39","9.7 %","+42 %","199","56.9 %","5/6 fenêtres +"],
       ["H1 (alternative bas DD)","1.86","6.9 %","+36 %","92","51.5 %","5/6 fenêtres +"]])
para("Les deux configurations sont robustes : 5 fenêtres walk-forward sur 6 sont "
     "profitables, et la performance se maintient sur la partie des données jamais "
     "utilisée pour l'optimisation (out-of-sample).", italic=True)

# ====================== 2. STRATEGIE ======================
h1("2. Logique de la stratégie")
para("Une position n'est ouverte que lorsque PLUSIEURS conditions indépendantes "
     "s'alignent. Cette exigence de confluence réduit le nombre de trades mais "
     "augmente fortement leur qualité (c'est ce qui a fait passer le profit factor "
     "de 1.24 à 1.86 lors du développement).")

h2("2.1 Les deux moteurs d'entrée")
para("Stratégie B — Cassure en tendance :", bold=True)
bullet("Tendance définie par EMA50 vs EMA200 (haussière si EMA50 > EMA200).")
bullet("Croisement Tenkan/Kijun (Ichimoku) dans le sens de la tendance.")
bullet("Le prix casse le plus haut (ou plus bas) des 20 dernières bougies.")
bullet("Le prix est hors du nuage Ichimoku (Kumo).")
para("Stratégie C — Repli sur la Kijun en tendance de fond :", bold=True)
bullet("Tendance de fond confirmée par l'EMA200 en données journalières (D1).")
bullet("Repli (pullback) du prix sur la ligne Kijun, puis bougie de continuation.")
bullet("Prix au-dessus du nuage pour un achat (sous le nuage pour une vente).")

h2("2.2 Les filtres de confluence (le cœur du système)")
para("Filtre n°1 — Alignement des 6 moyennes mobiles + Kijun :", bold=True)
para("C'est le filtre le plus important. Une position n'est validée que si les six "
     "moyennes mobiles sont parfaitement empilées dans le sens du trade :")
para("   EMA5 > EMA8 > EMA21 > SMA55 > SMA100 > SMA200   (pour un achat ; ordre inverse pour une vente)",
     italic=True)
para("De plus, le prix doit être au-dessus de la Kijun, elle-même au-dessus de la "
     "SMA200. Cet alignement complet signale une tendance mature et ordonnée.")
para("Filtre n°2 — Fair Value Gap (FVG) :", bold=True)
para("Le robot exige la présence récente d'un « gap d'inefficience » (déséquilibre "
     "de prix laissé par un mouvement institutionnel) dans le sens du trade. C'est le "
     "seul affinage de type Smart Money qui a amélioré le système de façon robuste "
     "lors des tests (les concepts OTE, IPDA et engulfing, eux, étranglaient le nombre "
     "de trades sans gain net — ils ont donc été écartés).")
para("Filtre n°3 — ADX (force de tendance) :", bold=True)
para("L'ADX mesure la PUISSANCE de la tendance (pas sa direction). Le robot n'entre "
     "que si l'ADX dépasse 20 : il évite ainsi les marchés qui hésitent (range), où un "
     "suivi de tendance perd de l'argent. Ce filtre a été ajouté après validation : il "
     "fait passer le profit factor de 1.39 à 1.57 et réduit le drawdown de 9.7 % à 6.6 %, "
     "avec 6 fenêtres walk-forward profitables sur 6. (Le filtre de volume, lui, a été "
     "testé puis écarté car il n'apportait rien sur Bitcoin.)")
para("Score de confirmations :", bold=True)
para("Chaque condition (tendance, position vs Kumo, position vs Kijun, cassure, "
     "volatilité suffisante) rapporte un point. Il faut au moins 3 points "
     "(paramètre MinConfirmations) pour autoriser l'entrée.")

h2("2.3 Gestion de la position après l'entrée")
bullet("Stop Loss = 1.8 × ATR (s'adapte automatiquement à la volatilité du moment).")
bullet("Take Profit = 3.0 × ATR (ratio risque/récompense de 1:3 environ).")
bullet("Break-even : le Stop est remonté au point d'entrée dès +1.2 ATR de gain.")
bullet("Trailing stop : le Stop suit le prix à 1.0 ATR de distance pour sécuriser les gains.")

# ====================== 3. PARAMETRES ======================
h1("3. Paramètres détaillés")
para("Tous les paramètres sont modifiables dans l'onglet « Entrées » lors de "
     "l'attachement de l'EA. Les valeurs par défaut sont celles validées par backtest "
     "— il est déconseillé de les modifier sans re-tester.")

h2("3.1 Timeframe et stratégies")
table(["Paramètre","Défaut","Rôle"],
 [["InpBaseTF","PERIOD_M30","Timeframe d'exécution (M30 conseillé, H1 = DD plus bas)"],
  ["RunStrategyB","true","Active le moteur cassure + cross Tenkan/Kijun"],
  ["RunStrategyC","true","Active le moteur pullback Kijun en tendance D1"]])

h2("3.2 Filtres de confluence")
table(["Paramètre","Défaut","Rôle"],
 [["RequireMAStack","true","Exige l'alignement des 6 MA + Kijun (NE PAS désactiver)"],
  ["UseFVGFilter","true","Exige un Fair Value Gap récent dans le sens du trade"],
  ["FVG_Lookback","20","Nombre de bougies où chercher un FVG"],
  ["UseADXFilter","true","Exige une tendance forte (ADX) — boost validé"],
  ["ADX_MinValue","20.0","Seuil ADX (20 optimal ; au-delà de 25 la régularité baisse)"],
  ["MinConfirmations","3","Score minimum de confirmations pour entrer"]])

h2("3.3 Stop Loss / Take Profit")
table(["Paramètre","Défaut","Rôle"],
 [["ATR_Period","14","Période de l'ATR (mesure de volatilité)"],
  ["ATR_SL_Mult","1.8","Stop Loss = 1.8 × ATR"],
  ["ATR_TP_Mult","3.0","Take Profit = 3.0 × ATR"],
  ["ATR_MinThreshold","0.8","Pas de trade si volatilité trop faible"]])

h2("3.4 Gestion du risque et garde-fous")
table(["Paramètre","Défaut","Rôle"],
 [["RiskPercent","1.0","% du capital risqué par trade"],
  ["MaxRiskPctBlock","8.0","Ignore le trade si le lot minimum risque plus de X% (300$=8 ; 1000$+=3)"],
  ["GlobalDDStop","25.0","Kill-switch : ferme tout et stoppe l'EA si le compte perd 25% depuis son pic"],
  ["MaxDailyLossPct","4.0","Arrêt des entrées si perte journalière > 4%"],
  ["MaxDailyTrades","6","Nombre maximum de trades par jour"],
  ["MaxLotSize","2.0","Taille de lot maximale autorisée"]])

h2("3.5 Gestion de position et filtres")
table(["Paramètre","Défaut","Rôle"],
 [["UseBreakEven","true","Active la mise à break-even"],
  ["BE_TriggerATR","1.2","Déclenche le break-even à +1.2 ATR"],
  ["UseTrailingStop","true","Active le trailing stop"],
  ["Trail_ATR_Mult","1.0","Distance du trailing = 1.0 ATR"],
  ["UseSpreadFilter","true","Refuse de trader si le spread est trop large"],
  ["MaxSpreadUSD","30.0","Spread maximum accepté, en USD"],
  ["MagicNumber","20250777","Identifiant unique des ordres de cet EA"]])

# ====================== 4. SECURITE ======================
h1("4. Sécurité et gestion du risque")
h2("4.1 Calcul de lot anti-aberration")
para("Certains courtiers (dont des comptes Exness) renvoient parfois une valeur de "
     "tick erronée, ce qui peut conduire à un calcul de lot dangereux. L'EA compare la "
     "valeur du courtier à la valeur théorique (taille de contrat × tick) et la corrige "
     "automatiquement si elle est aberrante. Le sizing reste donc fiable.")
h2("4.2 Plafond de risque adapté au capital")
para("Sur un petit compte BTC, le lot minimum (0.01) impose un risque incompressible "
     "par trade. Le paramètre MaxRiskPctBlock empêche d'ouvrir un trade dont le risque "
     "dépasserait le pourcentage défini. Réglage conseillé : 8 % pour 300 USD, 3 % pour "
     "1000 USD et plus.")
h2("4.3 Kill-switch de drawdown global")
para("Si l'equity du compte chute de 25 % (paramétrable) sous son plus haut, l'EA ferme "
     "toutes ses positions et cesse de trader. C'est la protection ultime contre une "
     "série de pertes ou un évènement de marché extrême.")
h2("4.4 Le levier ne change pas le risque")
para("Important : un levier élevé (ex. 1:2000 chez Exness) sert uniquement à réduire la "
     "marge nécessaire pour ouvrir une position. Il NE modifie PAS la perte subie si le "
     "Stop Loss est touché. Ne jamais augmenter la taille de lot sous prétexte d'un fort "
     "levier — c'est la première cause de comptes ruinés.", bold=True)

# ====================== 5. INSTALLATION ======================
h1("5. Installation dans MetaTrader 5")
steps=[
 "Ouvrir MetaTrader 5, menu Fichier → Ouvrir le dossier de données.",
 "Aller dans le dossier MQL5 → Experts et y copier le fichier EA_FusionBTC_v1.mq5.",
 "(Optionnel) Copier les fichiers .set dans MQL5 → Presets.",
 "Dans MetaTrader, ouvrir MetaEditor (bouton ou F4), ouvrir l'EA, et compiler (touche F7). Vérifier « 0 erreur ».",
 "Ouvrir un graphique BTCUSDm (n'importe quel timeframe d'affichage : l'EA utilise InpBaseTF).",
 "Faire glisser l'EA depuis le Navigateur sur le graphique.",
 "Onglet Commun : cocher « Autoriser le trading algorithmique ».",
 "Onglet Entrées : charger un preset (.set) via le bouton Load, ou laisser les valeurs par défaut.",
 "Cliquer OK, puis activer le bouton AutoTrading (vert) en haut de MetaTrader.",
 "Un visage souriant en haut à droite du graphique confirme que l'EA est actif.",
]
for i,s in enumerate(steps,1):
    p=doc.add_paragraph(style="List Number"); p.add_run(s)

# ====================== 6. VALIDATION ======================
h1("6. Procédure de validation AVANT argent réel")
para("Ne jamais passer en réel sans avoir franchi ces trois étapes dans l'ordre.")
h2("6.1 Strategy Tester (backtest sur ticks réels)")
bullet("Symbole BTCUSDm, modélisation « Every tick based on real ticks », 6 à 12 mois.")
bullet("Charger le preset FusionBTC_M30_300usd.set.")
bullet("Critères de validation (go) : Profit Factor ≥ 1.4, Drawdown ≤ 25 %, au moins 40 trades, courbe d'equity montante.")
h2("6.2 Forward test sur compte démo")
bullet("Compte démo Exness avec le capital réel visé, pendant 3 à 4 semaines minimum.")
bullet("Critères de passage : Profit Factor > 1.4, au moins 50 % de semaines positives, kill-switch non déclenché.")
h2("6.3 Passage en réel")
bullet("Démarrer avec le capital testé, sans augmenter la taille de lot.")
bullet("Surveiller la première semaine (exécution des ordres, absence de rejets), puis laisser le système travailler.")

# ====================== 7. ATTENTES REALISTES ======================
h1("7. Attentes réalistes et limites")
bullet("Aucun système ne gagne chaque semaine. Objectif réaliste : 55 à 60 % de semaines positives, courbe mensuelle en hausse, drawdown maîtrisé.")
bullet("Le robot trade peu (qualité avant quantité) : il peut rester plusieurs jours sans position. C'est normal et voulu.")
bullet("Sur un compte de 300 USD, le drawdown est structurellement plus élevé (plancher de lot). 1000 USD et plus améliorent nettement le profil de risque.")
bullet("Les performances passées ne préjugent pas des performances futures. Le Strategy Tester en ticks réels fait foi, pas le backtest Python.")
bullet("Le Bitcoin est très volatil : des mouvements brutaux (news, week-end) peuvent provoquer du slippage. Le filtre de spread et le kill-switch limitent, sans éliminer, ce risque.")

# ====================== 8. FAQ ======================
h1("8. Questions fréquentes")
def faq(q,a):
    para(q, bold=True); para(a)
faq("Sur quel graphique dois-je l'attacher ?",
    "N'importe quel timeframe d'affichage de BTCUSDm. L'EA calcule ses signaux sur le timeframe défini par InpBaseTF (M30 par défaut), indépendamment du graphique.")
faq("Puis-je l'utiliser sur l'or ou le Forex ?",
    "Il a été optimisé et validé uniquement sur Bitcoin. Sur un autre actif, il faudrait re-tester et ré-ajuster les paramètres (notamment MaxSpreadUSD et les seuils ATR).")
faq("Pourquoi le robot ne prend-il aucun trade ?",
    "C'est souvent normal : les conditions de confluence (6 MA alignées + FVG + score) sont exigeantes. Vérifiez aussi le spread, la session et que l'AutoTrading est activé.")
faq("Quel capital minimum ?",
    "Techniquement 300 USD avec MaxRiskPctBlock=8. Recommandé : 1000 USD et plus (MaxRiskPctBlock=3) pour un drawdown autour de 10 %.")
faq("Le robot peut-il me garantir un revenu hebdomadaire ?",
    "Non. Aucun robot honnête ne le peut. L'objectif est une espérance positive sur la durée, avec une majorité de semaines/mois gagnants.")

doc.add_paragraph()
end=doc.add_paragraph(); end.alignment=WD_ALIGN_PARAGRAPH.CENTER
r=end.add_run("— Fin du document —"); r.italic=True; r.font.color.rgb=GREY

out="docs/EA_FusionBTC_Documentation.docx"
os.makedirs("docs", exist_ok=True)
doc.save(out)
print("Document genere :", out)
