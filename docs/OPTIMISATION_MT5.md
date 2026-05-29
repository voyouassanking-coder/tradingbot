# Protocole d'optimisation dans MT5 (la seule vérité)

Le backtester Python s'est révélé non fiable (PF 2.46 Python vs 0.96 MT5 sur
la même fenêtre). **On abandonne l'optimisation Python.** On utilise
l'**Optimiseur intégré de MetaTrader 5**, qui teste les paramètres sur tes
**vrais ticks** — c'est lui qui fait foi.

---

## A. Pré-requis : un bon historique et un bon compte

1. **Compte USD** (PAS « profit en pips »). Ouvre un démo Exness standard en USD.
2. **Télécharger l'historique réel** : dans MT5, onglet *Symboles* → BTCUSDm →
   *Barres* / *Ticks* → charger le maximum (plusieurs années). Plus l'historique
   est profond, plus l'optimisation est robuste.
3. Strategy Tester → modélisation **« Every tick based on real ticks »**.

---

## B. Lancer l'OPTIMISEUR (pas un simple test)

Dans l'onglet *Testeur de stratégie* :
- **Expert** : EA_FusionBTC_v1
- **Symbole** : BTCUSDm | **Période (TF graphe)** : M30
- **Date** : la plus longue possible (ex. 2019 → aujourd'hui)
- **Modélisation** : *Every tick based on real ticks*
- **Dépôt** : 1000 USD (capital plus réaliste pour optimiser ; 300 fausse le sizing)
- **Optimisation** : choisir **« Algorithme génétique rapide »**
- **Critère (Optimisation basée sur)** : **« Solde max + Facteur de profit »**
  (ou « Custom max » si tu veux que je te donne une fonction OnTester sur mesure)

### Paramètres à optimiser (coche la case + mets Start/Step/Stop)

| Paramètre | Start | Step | Stop | Pourquoi |
|---|---|---|---|---|
| `ATR_SL_Mult` | 2.0 | 0.5 | 5.0 | **SL « considérable »** qu'une correction ne touche pas |
| `ATR_TP_Mult` | 1.0 | 0.5 | 4.0 | équilibre TP/SL |
| `ADX_MinValue` | 15 | 5 | 35 | force de tendance minimale |
| `Trail_ATR_Mult` | 1.5 | 0.5 | 4.0 | éviter les stop-out prématurés |
| `BE_TriggerATR` | 1.5 | 0.5 | 3.0 | break-even pas trop tôt |
| `MasterBiasTF` | (tester D1 puis H4 séparément) | | | tendance directrice |

> Laisse les autres paramètres fixes (déjà bons). Optimiser 5 params suffit ;
> au-delà on sur-ajuste.

### Bouton : **Démarrer**. MT5 va tester des centaines de combinaisons sur tes
vrais ticks et classer par performance.

---

## C. Choisir le bon résultat (éviter le sur-ajustement)

Ne prends PAS bêtement la ligne #1 (souvent sur-ajustée). Choisis une combinaison :
- **Facteur de profit entre 1.3 et 2.0** (au-delà de 2.5 = suspect, sur-ajusté)
- **Drawdown < 20 %**
- **Nombre de trades ≥ 100** (sinon pas significatif)
- des valeurs de paramètres « rondes » et **stables** (si PF s'effondre quand tu
  changes un peu un paramètre, c'est fragile)

Puis **valide en avant** : onglet *Forward* de MT5 (ex. « 1/4 ») — il optimise sur
75 % et teste sur 25 % jamais vus, automatiquement. Si le Forward tient → robuste.

---

## D. Ensuite : démo réelle

Config retenue → **démo USD 3-4 semaines** → si PF > 1.4 et comportement conforme
→ réel avec petit capital.

---

## E. (Optionnel) Pour améliorer MON analyse, donne-moi les vrais coûts

Si tu veux que mon analyse colle mieux à MT5, exporte-moi depuis MT5 :
1. **L'historique en CSV au TF M5 ou M1** (déjà fait pour partie).
2. La **spécification du symbole** BTCUSDm (clic droit sur le symbole →
   *Spécification*) : **Contract size, Tick size, Tick value, Spread moyen,
   Commission, Swap**.

Avec ces coûts réels, je reconstruis mon moteur avec spread + commission +
slippage réalistes → l'écart avec MT5 se réduira. Mais **l'Optimiseur MT5 reste
le juge final**, car lui seul utilise les vrais ticks.

---

## Résumé en une phrase

**On ne corrige pas Python — on optimise directement dans MT5 (vrais ticks),
on choisit une combinaison robuste (PF 1.3-2.0, DD<20%, 100+ trades), on valide
en Forward, puis démo.** C'est la seule boucle qui dit la vérité.
