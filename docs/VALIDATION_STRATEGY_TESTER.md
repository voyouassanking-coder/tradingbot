# Validation Strategy Tester MT5 — EA_FusionBTC v1.1

Procédure pas à pas pour valider l'EA dans MT5 **avant la démo**, et
critères de décision (go / no-go).

## 0. Installation

1. Copier `mql5/EA_FusionBTC_v1.mq5` dans `MQL5/Experts/` (MT5 → Fichier →
   Ouvrir le dossier de données → MQL5 → Experts).
2. Copier les deux `.set` de `mql5/presets/` dans
   `MQL5/Presets/` (ou les charger directement depuis le testeur).
3. MetaEditor → ouvrir l'EA → **Compiler (F7)**. Vérifier **0 erreur**.
   (Quelques avertissements "variable non utilisée" sont sans gravité.)

## 1. Réglage du Strategy Tester

| Champ | Valeur |
|---|---|
| Expert | EA_FusionBTC_v1 |
| Symbole | **BTCUSDm** (ton symbole Exness) |
| Période (graphe) | peu importe — l'EA travaille en `InpBaseTF` |
| Modélisation | **Every tick based on real ticks** (obligatoire) |
| Période de test | **6 à 12 derniers mois** |
| Dépôt | 300 USD (ou 1000) — devise du compte |
| Levier | 1:2000 (ton levier Exness) |
| Optimisation | **Désactivée** (test simple d'abord) |

Charger le preset : onglet *Inputs* → **Load** → `FusionBTC_M30_300usd.set`.

## 2. Critères de validation (go / no-go)

On **NE passe en démo que si** le test ticks réels donne :

| Métrique | Seuil minimum | Idéal |
|---|---|---|
| Profit factor | **≥ 1.4** | ≥ 1.6 |
| Max drawdown | **≤ 25 %** | ≤ 15 % |
| Trades | **≥ 40** sur la période | — |
| Courbe d'equity | montante, sans effondrement brutal | régulière |

Si le PF s'effondre vs nos chiffres Python (M30 PF 1.39 / H1 PF 1.86),
c'est le **spread/slippage réel** qui pèse → comparer les deux presets et,
si besoin, durcir `MaxSpreadUSD` ou tester H1 (moins sensible au spread).

## 3. Comparaison M30 vs H1

Lancer le test deux fois (un preset chacun) et comparer :
- **M30** : plus de trades, gains et régularité hebdo supérieurs, DD ~10-15 %.
- **H1**  : moins de trades, PF plus élevé, DD le plus bas.

Choisir selon ta tolérance au drawdown. Par défaut : **M30**.

## 4. Forward test démo (après un Strategy Tester concluant)

1. Compte **démo Exness BTCUSDm**, capital = capital réel visé (300 ou 1000).
2. Attacher l'EA, charger le preset, **AutoTrading ON**.
3. Laisser tourner **≥ 3-4 semaines** (au moins un épisode volatil BTC).
4. Critère de passage en réel :
   - PF > 1.4
   - au moins **50 % de semaines positives**
   - le kill-switch DD global ne s'est PAS déclenché
   - le comportement colle au backtest (fréquence, durée des trades)

## 5. Passage en réel (seulement si tout ci-dessus est vert)

- Démarrer avec le capital testé, **sans augmenter le lot** (le levier 1:2000
  ne doit jamais servir à sur-dimensionner — le risque par trade reste piloté
  par `RiskPercent` et le plancher de lot).
- Surveiller la 1re semaine, vérifier que les ordres passent (pas de rejet
  filling/stops level), puis laisser le système travailler.

## Rappels honnêtes

- **Aucun système ne gagne chaque semaine.** Objectif réaliste : ~55-60 % de
  semaines vertes, courbe mensuelle montante, DD maîtrisé.
- Le backtest Python (OHLC) est plus optimiste/pessimiste par endroits que
  les ticks réels — **le Strategy Tester every-tick fait foi**.
- À 300 USD le DD est structurellement plus élevé (plancher de lot) ; 1000 USD+
  améliore nettement le profil risque.
