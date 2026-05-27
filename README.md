# ScalpBTC — EA MT5 dédié BTCUSDm

EA de scalping pour MetaTrader 5, conçu pour **BTCUSDm** sur **M5** (M1 optionnel).

## Philosophie

**Pullback dans tendance** (pas de mean-reversion pure) :

1. **Biais macro** — EMA200 + pente (long uniquement au-dessus, short en dessous)
2. **Régime** — ADX ≥ seuil, ATR < p95 (skip volatilité extrême)
3. **Trigger** — Stoch cross dans la zone neutre + EMA8/21 stack + pullback proche EMA8
4. **Momentum** — MACD histogramme dans le sens du trade et accélère
5. **Filtres BTC obligatoires** — spread max dynamique (ATR-aware), session liquide, volume tick mini, cooldown post-SL

## Gestion du risque

| Élément | Valeur défaut |
|---|---|
| Risque par trade | 0.25 % equity |
| Daily loss cap | -2 % equity → pause jusqu'au lendemain |
| Positions simultanées | 1 |
| SL | ATR × 1.8 (avec garde `STOPS_LEVEL` + spread) |
| TP final | SL × 1.5 (RR 1.5:1) |
| TP1 partiel | 50 % à 1R, puis SL → BE + offset |
| Trail | ATR × 1.44 après TP1 |
| Time stop | 12 bougies sans atteindre 0.5R |
| Cooldown | 3 bougies après un SL |

## Installation

1. Copier `mql5/EA_ScalpBTCUSDm_v1.mq5` dans `MQL5/Experts/` de ton dossier MetaTrader 5.
2. Compiler (F7) dans MetaEditor.
3. Attacher à un graphique **BTCUSDm M5** (ou M1 si `InpAllowM1 = true`).
4. Autoriser le trading algorithmique (bouton AutoTrading).

## Backtest recommandé avant live

- **Période** : minimum 6 mois récents (BTC a des régimes très différents)
- **Modèle** : *Every tick based on real ticks*
- **Spread** : *Current* ou un spread fixe réaliste de ton broker
- **Capital** : taille proche du compte cible (pour valider le sizing)
- **Étapes** :
  1. Backtest paramètres par défaut → vérifier qu'il y a au moins ~50 trades
  2. Optimisation prudente : `InpATRMultSL` (1.2–2.5), `InpRR` (1.2–2.0), `InpADXMin` (18–28)
  3. **Forward test** sur démo ≥ 2 semaines avant live
  4. Live avec **1/4 du sizing cible** sur 1 mois

## Paramètres clés à connaître

- `InpRiskPct` — toujours ≤ 0.5 % en scalping crypto
- `InpMaxSpreadBaseUSD` — adapte au spread typique de **ton** broker BTCUSDm (regarde dans Symbol Specification)
- `InpSessionStartHour` / `InpSessionEndHour` — en heure **broker** (souvent GMT+2 ou GMT+3)
- `InpAllowM1` — laisser `false` au début, M1 demande spread très bas et latence faible

## Avertissement

Le scalping crypto est exigeant : spread, slippage et nuit/weekend illiquides peuvent transformer un edge théorique en perte réelle. **Toujours** valider par backtest + démo avant tout capital réel.

## Structure du dépôt

```
tradingbot/
├── README.md
└── mql5/
    └── EA_ScalpBTCUSDm_v1.mq5
```
