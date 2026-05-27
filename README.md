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
    ├── EA_ScalpBTCUSDm_v1.mq5         # v1 : pullback-in-trend (M5)
    └── EA_ScalpBTC_Confluence_v1.mq5  # v2 : Ichimoku MTF + SMC (M1)
```

---

# EA #2 : ScalpBTC Confluence (Ichimoku MTF + SMC)

EA séparé, conçu sur cahier des charges utilisateur — différent du v1.

## Concept

- **Symbole** : BTCUSD
- **Exécution** : M1
- **Biais** : confluence Ichimoku **M15 + H1** (les deux TF doivent valider)
- **Stack MA** : EMA5/8/21/55 + SMA100/200 alignées et pentes dans le sens du biais (sur M15)
- **Range filter** : Kijun plate + Tenkan/Kijun collées + nuage fin + prix autour du nuage → no trade
- **Triggers M1** : OTE Fibonacci (62–79%), retest FVG, breaker block, engulfing (≥1 par défaut, configurable pour "magic confluence")
- **Ordre** : stop order au break du high/low de la bougie de signal, validité 1 bougie
- **Pas de SL initial**
- **TP fixe** : 5 USD en distance de prix BTC
- **BE** : armé après 30 s + gain ≥ 2 USD → SL passe à entrée + 0.10 USD
- **Time-stop** : 5 min max par trade
- **Force-close** : à `InpForceCloseEndH` (défaut 23:00 GMT)

## Gestion

| Rule | Valeur défaut |
|---|---|
| Sessions | 09:00–23:00 GMT (Londres + NY) |
| Jours | Mardi à samedi |
| Trades max/jour | 100 |
| Pertes consécutives max | 5 → lockout 10 × M15 |
| Daily loss cap | 10 USD → lockout 10 × M15 |
| News (manuel) | Jusqu'à 5 fenêtres : `"YYYY.MM.DD HH:MM+DUR"` |
| Comportement news | Close all + lockout 10 × M15 |

## Format fenêtre news

Exemple `InpNews1 = "2026.05.27 14:30+30"` → fenêtre du 27/05/2026 14:30 GMT pendant 30 minutes. Pendant cette plage : close-all des positions + ordres, puis lockout de 10 bougies M15 (2h30) avant nouvelle analyse.

## Points d'attention

- **Pas de SL** = risque illimité jusqu'à activation du BE. Si le marché va contre toi sans atteindre +2 USD, il n'y a aucun frein. **Toujours** combiner ce bot avec une supervision manuelle ou un kill-switch.
- **TP en distance de prix** (5 USD BTC). À 0.01 lot, gain ≈ 0.05 USD P&L. Adapte `InpFixedLot` au capital cible.
- Les patterns SMC (FVG, OTE, breaker) sont implémentés algorithmiquement — un trader manuel les marque différemment. À calibrer en backtest.
- News auto-détection impossible nativement en MT5 sans plugin externe. Renseigne `InpNewsX` à la main avant chaque session.
