# Évaluation des squelettes EA vs notre standard validé

Comparaison de 7 EAs externes (Gold/Forex) avec le squelette que nous avons
**validé par backtest** sur BTC dans ce projet (`EA_FusionBTC_v1`).

## Notre standard de référence (modules validés)

Au fil du projet, on a prouvé par backtest IS/OOS + walk-forward que ces
6 modules font la différence entre un EA perdant et un EA robuste :

| # | Module validé | Preuve |
|---|---|---|
| M1 | **Lecture barre fermée** (shift=1) partout | corrige les signaux fantômes |
| M2 | **SL = ATR×1.5–1.8, RR ≥ 2** (pas de TP fixe en pips) | PF 0.54→1.2+ |
| M3 | **Filtre stack 6 MA (EMA5/8/21+SMA55/100/200) + Kijun** | PF 1.24→1.82 |
| M4 | **PAS de partial/BE prématuré** | PF 0.54→0.94 |
| M5 | **Garde-fous risque** : blocage si risque min-lot > %equity + kill-switch DD global | DD 15→8.8 %, protège petits comptes |
| M6 | **Filling auto-détecté** + spread en USD (pas en pips) | exécute sur Exness BTC |

## Scorecard des 7 EAs (✓ présent / ~ partiel / ✗ absent)

| EA | M1 barre fermée | M2 ATR+RR | M3 stack6MA | M4 no partial préma. | M5 garde-fous | M6 filling/spread | Verdict squelette |
|---|:--:|:--:|:--:|:--:|:--:|:--:|---|
| **EA Gold CCI+MACD v2** | ✓ | ✓ | ✗ | ✓ | ~ (daily only) | ✓ | 🥇 **Le plus discipliné** |
| **TITAN GOLD v3.1** | ✓ | ✓ (3 TP RR) | ✗ | ~ | ✓ (DD+daily) | ~ (IOC figé) | 🥈 **Ambitieux mais creux** |
| **Paré ULTIMATE** | ~ | ✓ | ✗ | ✗ | ~ | ~ | 🥉 Confluence riche, non-BTC |
| EA1 GoldTrendScalper | ✓ | ✓ | ✗ | ✓ (rien) | ✗ | ~ | Propre mais nu |
| Paré A / B / C | ~ | ✓ | ✗ | ✗ | ~ | ~ | EAs "profil volatilité" legacy |

## Analyse individuelle

### 🥇 EA Gold CCI+MACD v2 — le meilleur squelette
**Forces** : tout lu en barre fermée (shift=1), filtre tendance EMA200, CCI breakout + confirmation MACD, **SL ATR + RR2**, stop journalier %, max 2 trades/jour, session, clôture forcée, sortie anticipée si CCI s'inverse, **calcul de lot robuste avec garde-fou tickValue** (recalcule si la valeur broker est aberrante — excellent réflexe). Filling IOC adapté Exness.
**Manques vs notre standard** : pas de stack 6 MA (M3), pas de kill-switch DD global ni blocage min-lot (M5), tourne sur `PERIOD_CURRENT` (TF non imposé → risque d'usage sur le mauvais graphe).
→ **Le plus proche de nous. Candidat n°1 à booster pour BTC.**

### 🥈 TITAN GOLD v3.1 — superbe ossature, moteur absent
**Forces** : la meilleure **structure de contexte** de tous (`MarketContext` MTF D1/H4/H1/M15, régime de marché, z-score, sessions Exness UTC+0), risque complet (DD pic + daily), structures `TradeRecord`/mémoire pour apprentissage adaptatif.
**Faille bloquante** : **le moteur de signaux n'existe pas**. `OnTick` construit le contexte puis s'arrête sur le commentaire *« Le reste de ton moteur de signaux peut être réintégré ici »*. Les 7 stratégies (ICT, Wyckoff, Elliott…) sont déclarées en `input` mais **aucune n'est codée**. Les tableaux `Memory[]` sont alloués mais jamais utilisés. Filling IOC figé.
→ **C'est une coquille.** Magnifique squelette de contexte/risque, **zéro trade**. À utiliser comme **châssis** dans lequel injecter NOTRE moteur validé.

### 🥉 Paré ULTIMATE + A/B/C — confluence multi-indicateurs legacy
**Forces** : confluence riche (RSI+CCI+MACD+SAR+BB+ADX), logique "profil de volatilité" intéressante conceptuellement.
**Manques** : conçus Forex/Gold D1/H4, **mêmes bugs que le Paré C déjà audité** (spread en pips, partial/BE prématuré, seuils non adaptés BTC). Pas de stack 6 MA, lecture parfois sur barre courante.
→ Intérêt surtout **conceptuel** (l'idée de régime de volatilité). Pas une base technique pour BTC.

### EA1 GoldTrendScalper — minimaliste
EMA9/21 cross + RSI sur M15, SL/TP ATR, trailing. Propre mais **aucune protection** (pas d'EMA200, pas de session, pas de daily/DD stop) → sur-trade chaque croisement. Squelette d'entrée de gamme.

## Plan de boost — converger tous vers le standard

L'idée : **un squelette commun "impeccable"** qu'on applique à chacun, en
gardant la spécificité de signal de chacun.

```
┌─ CHÂSSIS COMMUN (à imposer à tous) ──────────────────────────┐
│ M1  toutes lectures indicateurs en shift=1 (barre fermée)    │
│ M2  SL = ATR×1.5-1.8 ; TP = RR≥2 (jamais de pips fixes)      │
│ M3  FILTRE stack 6 MA + Kijun (gate avant toute entrée)      │
│ M4  retirer partial/BE prématuré (ou le reculer ≥1R)         │
│ M5  RiskAllowed() : skip si risque min-lot > %equity         │
│     + GlobalDDHalt() : kill-switch DD pic                    │
│ M6  GetFilling() auto + spread en USD + TF imposé            │
└──────────────────────────────────────────────────────────────┘
        │ on y branche le MOTEUR DE SIGNAL propre à chaque EA :
        ├─ CCI+MACD v2 : breakout CCI + confirm MACD  (le + prêt)
        ├─ TITAN      : ses 7 stratégies (à CODER)
        ├─ Paré       : confluence RSI/CCI/MACD/SAR/BB
        └─ GoldScalper: EMA cross + RSI
```

### Priorité recommandée
1. **CCI+MACD v2 → BTC** : ajouter M3 (stack 6 MA) + M5 (garde-fous) + imposer TF. C'est le plus rapide à rendre "impeccable" et backtestable sur nos données.
2. **TITAN comme châssis** : il a le meilleur contexte MTF/risque ; y injecter notre moteur FusionBTC (strat B+C + stack 6 MA) → version "pro".
3. **Paré** : garder seulement l'idée de **régime de volatilité** comme filtre additionnel (ATR percentile) — déjà dans notre moteur.
4. **GoldScalper** : sert de test minimal, faible priorité.

## Lien avec notre projet (cap maintenu)

Aucun de ces EAs ne dépasse notre `EA_FusionBTC_v1` sur BTC en l'état :
- soit ils ne tradent pas (TITAN),
- soit il leur manque le filtre stack 6 MA qui a fait passer notre PF de 1.24 à 1.82,
- soit ils sont calibrés pour Gold/Forex avec des bugs déjà corrigés chez nous.

**Ils ne remplacent pas notre fusion — ils l'enrichissent** : le contexte MTF
de TITAN et le calcul de lot anti-aberration de CCI+MACD v2 sont deux briques
à intégrer dans notre standard.
