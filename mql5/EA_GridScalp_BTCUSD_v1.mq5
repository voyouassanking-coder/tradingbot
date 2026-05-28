//+==================================================================+
//|   EA_GridScalp_BTCUSD_v1.mq5                                      |
//|   Scalping BTCUSD par grille progressive (averaging)              |
//|                                                                   |
//|   Principe :                                                      |
//|     1. Ouverture d'une position initiale (sens auto ou forcé)     |
//|     2. Si le marché va contre, on ajoute des positions à chaque   |
//|        $X de mouvement adverse → moyenne du prix d'entrée         |
//|     3. Dès que le panier (somme nette) passe en gain, on ferme    |
//|        TOUT et on relance un cycle                                |
//|     4. Sécurité : nombre max de positions + stop global en %      |
//|                                                                   |
//|   AVERTISSEMENT :                                                 |
//|     Le grid amplifie les pertes en cas de mouvement directionnel  |
//|     fort. Ne JAMAIS désactiver le DrawdownMaxStop.                |
//+==================================================================+
#property copyright "GridScalp BTCUSD v1"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

CTrade        Trade;
CPositionInfo PositionInfo;
CSymbolInfo   SymbolInfoObj;

//══════════════════════════════════════════════════════════════════
// PARAMÈTRES UTILISATEUR
//══════════════════════════════════════════════════════════════════
input group "=== GÉNÉRAL ==="
input long   InpMagic            = 770003;       // Numéro magique (ne pas changer en cours de cycle)
input string InpComment          = "GridBTC";    // Commentaire des ordres
input int    InpDeviation        = 100;          // Slippage toléré (points)
input bool   InpVerbose          = true;         // Logs détaillés

enum ENUM_GRID_DIR { GRID_AUTO = 0, GRID_BUY_ONLY = 1, GRID_SELL_ONLY = 2 };
input ENUM_GRID_DIR InpDirection = GRID_AUTO;    // Sens : AUTO (selon tendance M15) ou forcé

input group "=== GRILLE ==="
input double InpGridDistanceUSD  = 150.0;        // Distance entre ordres en USD (ex: 150 = +1 ordre tous les 150$ adverses)
input double InpLotMultiplier    = 1.0;          // Multiplicateur lot par niveau (1.0=même lot, 1.3=martingale douce, 2.0=martingale agressive)
input int    InpMaxTrades        = 5;            // Nombre max de positions simultanées dans la grille

input group "=== LOT DYNAMIQUE ==="
input bool   InpAutoLot          = true;         // Calculer le lot initial selon le solde
input double InpAutoLotPerUSD    = 1000.0;       // 0.01 lot par tranche de X USD (défaut 1000$)
input double InpManualLot        = 0.01;         // Lot initial si InpAutoLot = false

input group "=== CLÔTURE GLOBALE ==="
input double InpMinNetProfitUSD  = 0.50;         // Gain net minimum (USD) pour fermer le panier
input double InpExtraBufferUSD   = 0.30;         // Marge de sécurité pour commissions (à ajouter au seuil)

input group "=== SÉCURITÉ ==="
input double InpDrawdownMaxPct   = 15.0;         // Stop d'urgence : si DD flottant ≥ ce % du capital → tout fermer
input bool   InpHaltAfterDDStop  = true;         // Après déclenchement, EA en pause jusqu'à redémarrage manuel

input group "=== FILTRE TENDANCE (mode AUTO) ==="
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_M15;   // Timeframe utilisé pour déterminer la tendance
input int    InpTrendEMA         = 50;           // Période EMA pour la tendance

//══════════════════════════════════════════════════════════════════
// VARIABLES GLOBALES
//══════════════════════════════════════════════════════════════════
int    hTrendEMA       = INVALID_HANDLE;
double bufTrendEMA[];

bool   g_isHalted      = false;     // EA en pause (DD stop déclenché)
double g_cycleStartEq  = 0.0;       // Equity au début du cycle (pour calcul DD relatif)
int    g_cycleNumber   = 0;

//══════════════════════════════════════════════════════════════════
// OnInit / OnDeinit
//══════════════════════════════════════════════════════════════════
int OnInit()
{
   // Vérifie que le symbole est disponible
   if(!SymbolInfoObj.Name(_Symbol))
   {
      Print("❌ Symbole introuvable : ", _Symbol);
      return INIT_FAILED;
   }
   SymbolInfoObj.RefreshRates();

   // Configure l'objet Trade
   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints(InpDeviation);
   Trade.SetTypeFillingBySymbol(_Symbol);

   // EMA tendance (mode AUTO)
   hTrendEMA = iMA(_Symbol, InpTrendTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(hTrendEMA == INVALID_HANDLE)
   {
      Print("❌ Impossible de créer l'EMA tendance");
      return INIT_FAILED;
   }
   ArraySetAsSeries(bufTrendEMA, true);

   // Ancre equity pour démarrage
   g_cycleStartEq = AccountInfoDouble(ACCOUNT_EQUITY);

   // Timer pour le dashboard
   EventSetTimer(10);

   Print("✅ GridScalp BTCUSD v1 démarré");
   PrintFormat("   Symbole=%s | Grid=%.2f USD | MaxTrades=%d | DD stop=%.1f%%",
               _Symbol, InpGridDistanceUSD, InpMaxTrades, InpDrawdownMaxPct);
   PrintFormat("   AutoLot=%s (%.0f USD/0.01) | Multiplier=%.2f",
               (InpAutoLot ? "OUI" : "NON"), InpAutoLotPerUSD, InpLotMultiplier);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hTrendEMA != INVALID_HANDLE) IndicatorRelease(hTrendEMA);
   EventKillTimer();
   Comment("");
}

//══════════════════════════════════════════════════════════════════
// OnTick — boucle principale
//══════════════════════════════════════════════════════════════════
void OnTick()
{
   SymbolInfoObj.RefreshRates();

   // Si l'EA est en pause après un stop d'urgence → ne rien faire
   if(g_isHalted) return;

   //─── 1) Vérifier le drawdown global d'urgence ───────────────────
   if(CheckEmergencyDrawdown()) return;  // si déclenché : on a tout fermé

   //─── 2) Récupérer l'état du panier ──────────────────────────────
   int    nPositions   = 0;
   double basketProfit = 0.0;
   double avgPriceBuy  = 0.0;
   double avgPriceSell = 0.0;
   double worstBuy     = 0.0;   // dernier prix d'achat le plus bas
   double worstSell    = 0.0;   // dernier prix de vente le plus haut
   double lastLotBuy   = 0.0;
   double lastLotSell  = 0.0;
   int    nBuy = 0, nSell = 0;

   AnalyzeBasket(nPositions, basketProfit, nBuy, nSell,
                 worstBuy, worstSell, lastLotBuy, lastLotSell);

   //─── 3) Si le panier est en gain net → tout fermer ──────────────
   double seuil = InpMinNetProfitUSD + InpExtraBufferUSD;
   if(nPositions > 0 && basketProfit >= seuil)
   {
      if(InpVerbose)
         PrintFormat("💰 Cycle #%d clôturé en gain net %.2f USD (seuil %.2f) — %d positions",
                     g_cycleNumber, basketProfit, seuil, nPositions);
      CloseAllPositions();
      g_cycleStartEq = AccountInfoDouble(ACCOUNT_EQUITY);
      g_cycleNumber++;
      return;
   }

   //─── 4) Aucune position → ouvrir le premier ordre du cycle ──────
   if(nPositions == 0)
   {
      int dir = DetermineDirection();
      if(dir == 0) return;  // pas de tendance claire en mode AUTO
      double lot = ComputeFirstLot();
      OpenPosition(dir, lot, "init");
      return;
   }

   //─── 5) Positions existantes → vérifier ajout grille ────────────
   if(nPositions >= InpMaxTrades) return;  // grille pleine

   double bid = SymbolInfoObj.Bid();
   double ask = SymbolInfoObj.Ask();

   // Si on a déjà des BUY et que le prix a baissé de InpGridDistanceUSD depuis le dernier BUY
   if(nBuy > 0 && worstBuy > 0)
   {
      if(ask <= worstBuy - InpGridDistanceUSD)
      {
         double nextLot = NormalizeLot(lastLotBuy * InpLotMultiplier);
         OpenPosition(+1, nextLot,
                      StringFormat("grid#%d", nBuy + 1));
      }
   }

   // Si on a déjà des SELL et que le prix a monté
   if(nSell > 0 && worstSell > 0)
   {
      if(bid >= worstSell + InpGridDistanceUSD)
      {
         double nextLot = NormalizeLot(lastLotSell * InpLotMultiplier);
         OpenPosition(-1, nextLot,
                      StringFormat("grid#%d", nSell + 1));
      }
   }
}

//══════════════════════════════════════════════════════════════════
// CheckEmergencyDrawdown
//   Si la perte flottante atteint InpDrawdownMaxPct% du capital de
//   départ du cycle → on ferme tout et on met l'EA en pause.
//══════════════════════════════════════════════════════════════════
bool CheckEmergencyDrawdown()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_cycleStartEq <= 0)
   {
      g_cycleStartEq = equity;
      return false;
   }

   double lossPct = (g_cycleStartEq - equity) / g_cycleStartEq * 100.0;
   if(lossPct >= InpDrawdownMaxPct)
   {
      PrintFormat("🚨 STOP D'URGENCE : DD %.2f%% ≥ %.1f%% — fermeture totale",
                  lossPct, InpDrawdownMaxPct);
      CloseAllPositions();
      if(InpHaltAfterDDStop)
      {
         g_isHalted = true;
         Print("⛔ EA en pause. Retirer du graphique puis remettre pour relancer.");
      }
      else
      {
         g_cycleStartEq = AccountInfoDouble(ACCOUNT_EQUITY);
         g_cycleNumber++;
      }
      return true;
   }
   return false;
}

//══════════════════════════════════════════════════════════════════
// AnalyzeBasket — parcourt les positions du magic et calcule l'état
//══════════════════════════════════════════════════════════════════
void AnalyzeBasket(int &nTot, double &profit, int &nBuy, int &nSell,
                   double &worstBuyPrice, double &worstSellPrice,
                   double &lastLotBuy, double &lastLotSell)
{
   nTot = 0; profit = 0.0; nBuy = 0; nSell = 0;
   worstBuyPrice = 0.0; worstSellPrice = 0.0;
   lastLotBuy = 0.0; lastLotSell = 0.0;
   double minBuyPrice  = DBL_MAX;
   double maxSellPrice = -DBL_MAX;
   datetime tLastBuy = 0, tLastSell = 0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!PositionInfo.SelectByIndex(i)) continue;
      if(PositionInfo.Symbol() != _Symbol) continue;
      if(PositionInfo.Magic() != InpMagic) continue;

      nTot++;
      profit += PositionInfo.Profit() + PositionInfo.Swap() + PositionInfo.Commission();

      double opn = PositionInfo.PriceOpen();
      double vol = PositionInfo.Volume();
      datetime t = (datetime)PositionInfo.Time();

      if(PositionInfo.PositionType() == POSITION_TYPE_BUY)
      {
         nBuy++;
         if(opn < minBuyPrice) minBuyPrice = opn;
         if(t > tLastBuy) { tLastBuy = t; lastLotBuy = vol; }
      }
      else
      {
         nSell++;
         if(opn > maxSellPrice) maxSellPrice = opn;
         if(t > tLastSell) { tLastSell = t; lastLotSell = vol; }
      }
   }
   if(nBuy  > 0) worstBuyPrice  = minBuyPrice;
   if(nSell > 0) worstSellPrice = maxSellPrice;
}

//══════════════════════════════════════════════════════════════════
// DetermineDirection
//   Mode AUTO : tendance EMA(50) sur M15 → BUY si prix > EMA et pente
//   positive, SELL si prix < EMA et pente négative, sinon 0 (skip)
//══════════════════════════════════════════════════════════════════
int DetermineDirection()
{
   if(InpDirection == GRID_BUY_ONLY)  return +1;
   if(InpDirection == GRID_SELL_ONLY) return -1;

   if(CopyBuffer(hTrendEMA, 0, 0, 5, bufTrendEMA) < 4) return 0;
   double close1 = iClose(_Symbol, InpTrendTF, 1);
   double ema1   = bufTrendEMA[1];
   double ema3   = bufTrendEMA[3];

   bool up   = (close1 > ema1) && (ema1 > ema3);
   bool down = (close1 < ema1) && (ema1 < ema3);
   if(up)   return +1;
   if(down) return -1;
   return 0;
}

//══════════════════════════════════════════════════════════════════
// ComputeFirstLot — lot initial selon InpAutoLot
//══════════════════════════════════════════════════════════════════
double ComputeFirstLot()
{
   double lot;
   if(InpAutoLot)
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double units   = MathFloor(balance / InpAutoLotPerUSD);  // nb de tranches
      if(units < 1) units = 1;
      lot = units * 0.01;
   }
   else lot = InpManualLot;

   return NormalizeLot(lot);
}

//══════════════════════════════════════════════════════════════════
// NormalizeLot — cale le lot sur les contraintes du symbole
//══════════════════════════════════════════════════════════════════
double NormalizeLot(double lot)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   if(lot < mn) lot = mn;
   if(lot > mx) lot = mx;
   return lot;
}

//══════════════════════════════════════════════════════════════════
// OpenPosition — ouvre un BUY (+1) ou un SELL (-1)
//══════════════════════════════════════════════════════════════════
void OpenPosition(int dir, double lot, const string tag)
{
   double ask = SymbolInfoObj.Ask();
   double bid = SymbolInfoObj.Bid();
   string cmt = InpComment + "|" + tag;

   bool ok = false;
   if(dir > 0)
      ok = Trade.Buy (lot, _Symbol, ask, 0.0, 0.0, cmt);
   else
      ok = Trade.Sell(lot, _Symbol, bid, 0.0, 0.0, cmt);

   if(ok)
   {
      if(InpVerbose)
         PrintFormat("%s %s %.4f @ %.2f (%s)",
                     (dir > 0 ? "▲" : "▼"), (dir > 0 ? "BUY" : "SELL"),
                     lot, (dir > 0 ? ask : bid), tag);
   }
   else
   {
      PrintFormat("✗ Ouverture rejetée (%s) : %d %s",
                  tag, Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
   }
}

//══════════════════════════════════════════════════════════════════
// CloseAllPositions — ferme toutes les positions du magic
//══════════════════════════════════════════════════════════════════
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionInfo.SelectByIndex(i)) continue;
      if(PositionInfo.Symbol() != _Symbol) continue;
      if(PositionInfo.Magic() != InpMagic) continue;
      Trade.PositionClose(PositionInfo.Ticket());
   }
}

//══════════════════════════════════════════════════════════════════
// OnTimer — tableau de bord visuel
//══════════════════════════════════════════════════════════════════
void OnTimer()
{
   int nTot, nBuy, nSell;
   double profit, wb, ws, lb, ls;
   AnalyzeBasket(nTot, profit, nBuy, nSell, wb, ws, lb, ls);

   double eq      = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal     = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd      = (g_cycleStartEq > 0) ? (g_cycleStartEq - eq) / g_cycleStartEq * 100.0 : 0.0;
   string trend   = "—";
   int    dir     = DetermineDirection();
   if(dir > 0)      trend = "↑ HAUSSIÈRE";
   else if(dir < 0) trend = "↓ BAISSIÈRE";

   string state = g_isHalted ? "⛔ EN PAUSE (DD stop)" : "✅ ACTIF";

   Comment(
      "GridScalp BTCUSD v1 — ", _Symbol, "\n",
      "─────────────────────────────────\n",
      "État          : ", state, "\n",
      "Cycle         : #", IntegerToString(g_cycleNumber), "\n",
      "Tendance ", EnumToString(InpTrendTF), " : ", trend, "\n",
      "─────────────────────────────────\n",
      "Positions     : ", IntegerToString(nTot), "/", IntegerToString(InpMaxTrades),
         " (BUY=", IntegerToString(nBuy), " SELL=", IntegerToString(nSell), ")\n",
      "Panier P&L    : ", DoubleToString(profit, 2), " USD",
         "  (cloturer à ≥ ", DoubleToString(InpMinNetProfitUSD + InpExtraBufferUSD, 2), ")\n",
      "Drawdown      : ", DoubleToString(dd, 2), " %",
         "  (stop à ", DoubleToString(InpDrawdownMaxPct, 1), " %)\n",
      "─────────────────────────────────\n",
      "Balance       : ", DoubleToString(bal, 2), "\n",
      "Equity        : ", DoubleToString(eq, 2), "\n",
      "Lot initial   : ", DoubleToString(ComputeFirstLot(), 2)
   );
}
