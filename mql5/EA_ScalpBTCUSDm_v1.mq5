//+==================================================================+
//|   EA_ScalpBTCUSDm_v1.mq5                                          |
//|   Scalping EA dédié BTCUSDm                                       |
//|   Stratégie : pullback dans tendance + filtres BTC stricts        |
//|                                                                   |
//|   Pipeline (par bougie close) :                                   |
//|     1. Filtres de garde (spread, session, volume, cooldown, DD)  |
//|     2. Régime (EMA200 bias, ADX, ATR régime)                      |
//|     3. Signal (EMA8/21 pullback + Stoch cross + MACD momentum)    |
//|     4. Exécution (lot ATR-sized, deviation adaptative)            |
//|     5. Gestion intra-bar (TP1 partiel @ 1R, BE, trail, time-stop) |
//+==================================================================+
#property copyright "ScalpBTCUSDm v1"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

CTrade        Trade;
CPositionInfo PositionInfo;
CSymbolInfo   SymbolInfoObj;

//─── Général ──────────────────────────────────────────────────────
input group "=== GÉNÉRAL ==="
input long   InpMagic           = 770001;
input string InpComment         = "ScalpBTC_v1";
input bool   InpAllowM1         = false;   // Autoriser M1 (sinon force M5 minimum)
input bool   InpVerboseLog      = true;

//─── Risque ───────────────────────────────────────────────────────
input group "=== RISQUE ==="
input double InpRiskPct         = 0.25;    // % equity risqué par trade
input double InpDailyLossPct    = 2.0;     // Stop journalier (% equity)
input int    InpMaxConcurrent   = 1;       // Positions simultanées max
input int    InpCooldownBars    = 3;       // Bougies d'attente après un SL
input double InpATRPeriod       = 14;
input double InpATRMultSL       = 1.8;     // SL = ATR × mult
input double InpRR              = 1.5;     // TP final = SL × RR (TP1 = 1R)
input double InpTP1Fraction     = 0.5;     // Fraction fermée à TP1 (1R)
input int    InpTimeStopBars    = 12;      // Bougies max sans atteindre 0.5R

//─── Filtres BTC ──────────────────────────────────────────────────
input group "=== FILTRES BTC ==="
input double InpMaxSpreadBaseUSD = 8.0;    // Spread max de base en USD
input double InpMaxSpreadATRPct  = 8.0;    // + (% d'ATR) ajouté au plafond spread
input bool   InpUseSession       = true;
input int    InpSessionStartHour = 7;      // GMT broker : début fenêtre active
input int    InpSessionEndHour   = 22;     // GMT broker : fin fenêtre active
input bool   InpAvoidSundayOpen  = true;   // Skip premières 6h après ouverture dim/lun
input double InpMinTickVolMult   = 0.6;    // Volume tick > moyenne(20) × ce mult

//─── Régime / tendance ────────────────────────────────────────────
input group "=== RÉGIME ==="
input int    InpEMABias          = 200;    // EMA filtre directionnel
input int    InpADXPeriod        = 14;
input double InpADXMin           = 20.0;   // Seuil ADX en M5 (auto 22 si M1)
input int    InpATRLookback      = 100;    // Fenêtre percentile ATR
input double InpATRMaxPct        = 95.0;   // Skip si ATR > p95 (vol. extrême)

//─── Signal ───────────────────────────────────────────────────────
input group "=== SIGNAL ==="
input int    InpEMAFast          = 8;
input int    InpEMASlow          = 21;
input int    InpStochK           = 5;
input int    InpStochD           = 3;
input int    InpStochSlow        = 3;
input double InpStochBuyMax      = 60.0;   // Stoch cross haussier doit être <= ce niveau
input double InpStochSellMin     = 40.0;   // Stoch cross baissier doit être >= ce niveau
input int    InpMACDFast         = 12;
input int    InpMACDSlow         = 26;
input int    InpMACDSig          = 9;
input double InpPullbackATRMax   = 0.8;    // Distance close↔EMAfast < ATR × ce mult

//─── Exécution ────────────────────────────────────────────────────
input group "=== EXÉCUTION ==="
input int    InpDeviationPoints  = 50;     // Slippage toléré
input bool   InpUseLimitOrders   = false;  // Sinon marché

//─── Handles & buffers ────────────────────────────────────────────
int hEMABias, hEMAFast, hEMASlow, hATR, hADX, hStoch, hMACD;
double bufEMAB[], bufEMAF[], bufEMAS[];
double bufATR[], bufADX[], bufDMIP[], bufDMIM[];
double bufStK[], bufStD[];
double bufMACD[], bufSig[];

//─── État ─────────────────────────────────────────────────────────
datetime g_lastBar      = 0;
datetime g_lastStopBar  = 0;
datetime g_dayAnchorDate= 0;
double   g_dayAnchorEq  = 0.0;
double   g_pointVal     = 0.0;   // SYMBOL_TRADE_TICK_VALUE_LOSS / TICK_SIZE * _Point

//══════════════════════════════════════════════════════════════════
// OnInit / OnDeinit
//══════════════════════════════════════════════════════════════════
int OnInit()
{
   if(!InpAllowM1 && Period() == PERIOD_M1)
   {
      Print("❌ Timeframe M1 désactivé (InpAllowM1=false). Utilise M5+.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!SymbolInfoObj.Name(_Symbol))
   {
      Print("❌ Symbole introuvable: ", _Symbol);
      return INIT_FAILED;
   }
   SymbolInfoObj.RefreshRates();

   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints(InpDeviationPoints);
   Trade.SetTypeFillingBySymbol(_Symbol);

   hEMABias = iMA(_Symbol, PERIOD_CURRENT, InpEMABias, 0, MODE_EMA, PRICE_CLOSE);
   hEMAFast = iMA(_Symbol, PERIOD_CURRENT, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   hEMASlow = iMA(_Symbol, PERIOD_CURRENT, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
   hATR     = iATR(_Symbol, PERIOD_CURRENT, (int)InpATRPeriod);
   hADX     = iADX(_Symbol, PERIOD_CURRENT, InpADXPeriod);
   hStoch   = iStochastic(_Symbol, PERIOD_CURRENT,
                          InpStochK, InpStochD, InpStochSlow,
                          MODE_SMA, STO_LOWHIGH);
   hMACD    = iMACD(_Symbol, PERIOD_CURRENT,
                    InpMACDFast, InpMACDSlow, InpMACDSig, PRICE_CLOSE);

   if(hEMABias==INVALID_HANDLE || hEMAFast==INVALID_HANDLE ||
      hEMASlow==INVALID_HANDLE || hATR==INVALID_HANDLE ||
      hADX==INVALID_HANDLE     || hStoch==INVALID_HANDLE ||
      hMACD==INVALID_HANDLE)
   {
      Print("❌ Init handles indicateurs");
      return INIT_FAILED;
   }

   ArraySetAsSeries(bufEMAB, true);
   ArraySetAsSeries(bufEMAF, true);
   ArraySetAsSeries(bufEMAS, true);
   ArraySetAsSeries(bufATR,  true);
   ArraySetAsSeries(bufADX,  true);
   ArraySetAsSeries(bufDMIP, true);
   ArraySetAsSeries(bufDMIM, true);
   ArraySetAsSeries(bufStK,  true);
   ArraySetAsSeries(bufStD,  true);
   ArraySetAsSeries(bufMACD, true);
   ArraySetAsSeries(bufSig,  true);

   ResetDailyAnchor();
   EventSetTimer(15);

   Print("✅ ScalpBTC v1 init | ", _Symbol, " | TF=", EnumToString(Period()),
         " | Risk=", InpRiskPct, "% | DailyCap=", InpDailyLossPct, "%");
   Print("   Stops level=", SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
         " pts | TickSize=", SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE),
         " | TickValueLoss=", SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hEMABias);
   IndicatorRelease(hEMAFast);
   IndicatorRelease(hEMASlow);
   IndicatorRelease(hATR);
   IndicatorRelease(hADX);
   IndicatorRelease(hStoch);
   IndicatorRelease(hMACD);
   EventKillTimer();
}

//══════════════════════════════════════════════════════════════════
// OnTick : management intra-bar + signal à la bougie close
//══════════════════════════════════════════════════════════════════
void OnTick()
{
   SymbolInfoObj.RefreshRates();
   ManageOpenPositions();

   datetime cur = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(cur == g_lastBar) return;
   g_lastBar = cur;

   RollDailyAnchorIfNeeded();
   if(!LoadBuffers()) return;

   // Gardes
   if(!DailyLossOK())      return;
   if(!SessionOK())        return;
   if(!CooldownOK())       return;
   if(!SpreadOK())         return;
   if(!VolumeOK())         return;
   if(CountPos() >= InpMaxConcurrent) return;
   if(!ATRRegimeOK())      return;

   // Régime
   int bias = BiasDirection();
   if(bias == 0)           return;
   if(!ADXOK())            return;

   // Signal
   int dir = GetSignal(bias);
   if(dir == 0)            return;

   // Levels + exécution
   double slDist, tpDist;
   if(!CalcLevels(slDist, tpDist)) return;
   ExecTrade(dir, slDist, tpDist);
}

//══════════════════════════════════════════════════════════════════
// OnTradeTransaction : détecte stop-out pour cooldown
//══════════════════════════════════════════════════════════════════
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &req,
                        const MqlTradeResult      &res)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   ulong dealTicket = trans.deal;
   if(dealTicket == 0) return;
   if(!HistoryDealSelect(dealTicket)) return;

   if((long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != InpMagic) return;
   if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol) return;
   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;

   long reason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
   if(reason == DEAL_REASON_SL)
   {
      g_lastStopBar = iTime(_Symbol, PERIOD_CURRENT, 0);
      if(InpVerboseLog) Print("⏸ Cooldown armé après SL");
   }
}

//══════════════════════════════════════════════════════════════════
// Buffers
//══════════════════════════════════════════════════════════════════
bool LoadBuffers()
{
   if(CopyBuffer(hEMABias, 0, 0, 5,  bufEMAB) < 3) return false;
   if(CopyBuffer(hEMAFast, 0, 0, 5,  bufEMAF) < 3) return false;
   if(CopyBuffer(hEMASlow, 0, 0, 5,  bufEMAS) < 3) return false;
   if(CopyBuffer(hATR,     0, 0, InpATRLookback+5, bufATR) < InpATRLookback) return false;
   if(CopyBuffer(hADX,     0, 0, 5,  bufADX)  < 3) return false;
   if(CopyBuffer(hADX,     1, 0, 5,  bufDMIP) < 3) return false;
   if(CopyBuffer(hADX,     2, 0, 5,  bufDMIM) < 3) return false;
   if(CopyBuffer(hStoch,   0, 0, 5,  bufStK)  < 3) return false;
   if(CopyBuffer(hStoch,   1, 0, 5,  bufStD)  < 3) return false;
   if(CopyBuffer(hMACD,    0, 0, 5,  bufMACD) < 3) return false;
   if(CopyBuffer(hMACD,    1, 0, 5,  bufSig)  < 3) return false;
   return true;
}

//══════════════════════════════════════════════════════════════════
// Filtres de garde
//══════════════════════════════════════════════════════════════════
bool SpreadOK()
{
   double ask = SymbolInfoObj.Ask();
   double bid = SymbolInfoObj.Bid();
   double spreadUSD = ask - bid;
   double atr = bufATR[1];
   double cap = InpMaxSpreadBaseUSD + atr * (InpMaxSpreadATRPct / 100.0);
   bool ok = spreadUSD <= cap;
   if(!ok && InpVerboseLog)
      PrintFormat("✗ Spread %.2f > cap %.2f (ATR=%.2f)", spreadUSD, cap, atr);
   return ok;
}

bool SessionOK()
{
   if(!InpUseSession) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(InpAvoidSundayOpen && dt.day_of_week == 0) return false;
   if(InpAvoidSundayOpen && dt.day_of_week == 1 && dt.hour < 6) return false;

   if(InpSessionStartHour <= InpSessionEndHour)
      return (dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour);
   else // wrap-around
      return (dt.hour >= InpSessionStartHour || dt.hour < InpSessionEndHour);
}

bool VolumeOK()
{
   long vol[];
   ArraySetAsSeries(vol, true);
   if(CopyTickVolume(_Symbol, PERIOD_CURRENT, 1, 21, vol) < 21) return true; // pas assez d'histo → laisser passer
   double mean = 0;
   for(int i=1; i<=20; i++) mean += (double)vol[i];
   mean /= 20.0;
   return (double)vol[0] >= mean * InpMinTickVolMult;
}

bool CooldownOK()
{
   if(g_lastStopBar == 0) return true;
   int barsSec = PeriodSeconds(PERIOD_CURRENT);
   long elapsed = (long)(iTime(_Symbol, PERIOD_CURRENT, 0) - g_lastStopBar);
   return elapsed >= (long)InpCooldownBars * barsSec;
}

bool DailyLossOK()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_dayAnchorEq <= 0) return true;
   double lossPct = (g_dayAnchorEq - eq) / g_dayAnchorEq * 100.0;
   if(lossPct >= InpDailyLossPct)
   {
      if(InpVerboseLog) PrintFormat("⛔ Daily loss %.2f%% atteint, pause jusqu'à demain", lossPct);
      return false;
   }
   return true;
}

bool ATRRegimeOK()
{
   double cur = bufATR[1];
   int n = MathMin(InpATRLookback, ArraySize(bufATR)-1);
   if(n < 20) return true;
   int above = 0;
   for(int i=1; i<=n; i++) if(bufATR[i] >= cur) above++;
   double percentile = 100.0 * (1.0 - (double)above / (double)n);
   bool ok = percentile <= InpATRMaxPct;
   if(!ok && InpVerboseLog)
      PrintFormat("✗ ATR p%.0f trop élevé (cap %.0f)", percentile, InpATRMaxPct);
   return ok;
}

//══════════════════════════════════════════════════════════════════
// Régime
//══════════════════════════════════════════════════════════════════
int BiasDirection()
{
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   if(close1 > bufEMAB[1] && bufEMAB[1] > bufEMAB[3]) return  1;
   if(close1 < bufEMAB[1] && bufEMAB[1] < bufEMAB[3]) return -1;
   return 0;
}

bool ADXOK()
{
   double thr = (Period() == PERIOD_M1) ? MathMax(InpADXMin, 22.0) : InpADXMin;
   return bufADX[1] >= thr;
}

//══════════════════════════════════════════════════════════════════
// Signal : pullback-in-trend + Stoch cross + MACD momentum
//══════════════════════════════════════════════════════════════════
int GetSignal(int bias)
{
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double atr    = bufATR[1];
   double dist   = MathAbs(close1 - bufEMAF[1]);

   bool pullbackOK = (dist <= atr * InpPullbackATRMax);

   bool stochCrossUp   = (bufStK[2] < bufStD[2]) && (bufStK[1] >= bufStD[1]) && (bufStK[1] <= InpStochBuyMax);
   bool stochCrossDown = (bufStK[2] > bufStD[2]) && (bufStK[1] <= bufStD[1]) && (bufStK[1] >= InpStochSellMin);

   double histo1 = bufMACD[1] - bufSig[1];
   double histo2 = bufMACD[2] - bufSig[2];
   bool macdUp   = (histo1 > 0) && (histo1 > histo2);
   bool macdDown = (histo1 < 0) && (histo1 < histo2);

   bool emaStackUp   = (bufEMAF[1] > bufEMAS[1]);
   bool emaStackDown = (bufEMAF[1] < bufEMAS[1]);

   if(bias > 0 && pullbackOK && emaStackUp   && stochCrossUp   && macdUp)   return  1;
   if(bias < 0 && pullbackOK && emaStackDown && stochCrossDown && macdDown) return -1;
   return 0;
}

//══════════════════════════════════════════════════════════════════
// Niveaux SL / TP
//══════════════════════════════════════════════════════════════════
bool CalcLevels(double &slDist, double &tpDist)
{
   double atr = bufATR[1];
   slDist = atr * InpATRMultSL;

   double point  = _Point;
   long   stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double spread = SymbolInfoObj.Ask() - SymbolInfoObj.Bid();
   double minDist = stops * point + spread * 2.0;

   if(slDist < minDist) slDist = minDist;
   tpDist = slDist * InpRR;
   return slDist > 0;
}

//══════════════════════════════════════════════════════════════════
// Lot sizing (ATR-based, broker-agnostic via tick value)
//══════════════════════════════════════════════════════════════════
double CalcLots(double slDist)
{
   double eq        = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = eq * InpRiskPct / 100.0;

   double tickSize      = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValueLoss = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   double volStep       = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double volMin        = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax        = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(tickSize <= 0 || tickValueLoss <= 0 || volStep <= 0) return volMin;

   double lossPerLot = (slDist / tickSize) * tickValueLoss;
   if(lossPerLot <= 0) return volMin;

   double lots = riskMoney / lossPerLot;
   lots = MathFloor(lots / volStep) * volStep;
   lots = MathMax(volMin, MathMin(volMax, lots));
   return lots;
}

//══════════════════════════════════════════════════════════════════
// Exécution
//══════════════════════════════════════════════════════════════════
void ExecTrade(int dir, double slDist, double tpDist)
{
   double lots = CalcLots(slDist);
   int    dig  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double ask  = SymbolInfoObj.Ask();
   double bid  = SymbolInfoObj.Bid();

   if(dir == 1)
   {
      double sl = NormalizeDouble(ask - slDist, dig);
      double tp = NormalizeDouble(ask + tpDist, dig);
      if(Trade.Buy(lots, _Symbol, ask, sl, tp, InpComment))
         PrintFormat("▲ BUY %.4f @%.2f SL=%.2f TP=%.2f ATR=%.2f", lots, ask, sl, tp, bufATR[1]);
      else
         PrintFormat("✗ BUY rejected: %d %s", Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
   }
   else
   {
      double sl = NormalizeDouble(bid + slDist, dig);
      double tp = NormalizeDouble(bid - tpDist, dig);
      if(Trade.Sell(lots, _Symbol, bid, sl, tp, InpComment))
         PrintFormat("▼ SELL %.4f @%.2f SL=%.2f TP=%.2f ATR=%.2f", lots, bid, sl, tp, bufATR[1]);
      else
         PrintFormat("✗ SELL rejected: %d %s", Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
   }
}

//══════════════════════════════════════════════════════════════════
// Gestion des positions ouvertes
//   - TP1 partiel à 1R (close fraction, SL → BE + offset)
//   - Trail ATR sur le reste
//   - Time stop si > N bougies et progression < 0.5R
//══════════════════════════════════════════════════════════════════
void ManageOpenPositions()
{
   if(ArraySize(bufATR) < 2) return;
   double atr = bufATR[1];
   if(atr <= 0) return;
   int dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   long stops = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stops * _Point;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!PositionInfo.SelectByIndex(i)) continue;
      if(PositionInfo.Symbol() != _Symbol)       continue;
      if(PositionInfo.Magic()  != InpMagic)      continue;

      ulong  tk   = PositionInfo.Ticket();
      double opn  = PositionInfo.PriceOpen();
      double sl   = PositionInfo.StopLoss();
      double tp   = PositionInfo.TakeProfit();
      double vol  = PositionInfo.Volume();
      double bid  = SymbolInfoObj.Bid();
      double ask  = SymbolInfoObj.Ask();
      ENUM_POSITION_TYPE pt = PositionInfo.PositionType();

      // R initial = distance SL d'origine (approximée par |open - SL courant| si pas BE)
      double initialR = MathAbs(opn - sl);
      if(initialR <= 0) continue;

      bool isBuy = (pt == POSITION_TYPE_BUY);
      double price = isBuy ? bid : ask;
      double gain  = isBuy ? (price - opn) : (opn - price);

      // Heuristique : TP1 considéré fait si SL est déjà ≥ BE pour BUY (≤ BE pour SELL)
      bool tp1Done = isBuy ? (sl >= opn - _Point) : (sl <= opn + _Point);

      //─── 1) TP1 partiel à 1R ─────────────────────────────────────
      if(!tp1Done && gain >= initialR && InpTP1Fraction > 0 && InpTP1Fraction < 1.0)
      {
         double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         double closeVol = MathFloor((vol * InpTP1Fraction) / volStep) * volStep;
         if(closeVol >= volMin && closeVol < vol)
         {
            if(Trade.PositionClosePartial(tk, closeVol))
            {
               // SL → BE + petit offset (couvre commission/spread)
               double offset = MathMax(_Point * 2, atr * 0.1);
               double newSL  = isBuy ? NormalizeDouble(opn + offset, dig)
                                     : NormalizeDouble(opn - offset, dig);
               if(MathAbs(price - newSL) > minDist)
                  Trade.PositionModify(tk, newSL, tp);
               if(InpVerboseLog) PrintFormat("◐ TP1 partial %.4f, SL→BE", closeVol);
            }
         }
         continue;
      }

      //─── 2) Trail ATR (après TP1) ────────────────────────────────
      if(tp1Done)
      {
         double trailDist = atr * InpATRMultSL * 0.8; // un peu plus serré post-TP1
         double newSL = isBuy ? NormalizeDouble(price - trailDist, dig)
                              : NormalizeDouble(price + trailDist, dig);
         bool improves = isBuy ? (newSL > sl) : (newSL < sl);
         if(improves && MathAbs(price - newSL) > minDist)
            Trade.PositionModify(tk, newSL, tp);
      }

      //─── 3) Time stop ────────────────────────────────────────────
      datetime opnTime = (datetime)PositionInfo.Time();
      int barsHeld = (int)((TimeCurrent() - opnTime) / PeriodSeconds(PERIOD_CURRENT));
      if(barsHeld >= InpTimeStopBars && gain < initialR * 0.5)
      {
         Trade.PositionClose(tk);
         if(InpVerboseLog) PrintFormat("⏱ Time-stop close après %d bougies", barsHeld);
      }
   }
}

//══════════════════════════════════════════════════════════════════
// Daily anchor
//══════════════════════════════════════════════════════════════════
void RollDailyAnchorIfNeeded()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   MqlDateTime anc;
   TimeToStruct(g_dayAnchorDate, anc);
   if(g_dayAnchorDate == 0 || now.day != anc.day || now.mon != anc.mon || now.year != anc.year)
      ResetDailyAnchor();
}

void ResetDailyAnchor()
{
   g_dayAnchorDate = TimeCurrent();
   g_dayAnchorEq   = AccountInfoDouble(ACCOUNT_EQUITY);
   if(InpVerboseLog) PrintFormat("🔄 Daily anchor reset @ equity %.2f", g_dayAnchorEq);
}

//══════════════════════════════════════════════════════════════════
// Utilitaires
//══════════════════════════════════════════════════════════════════
int CountPos()
{
   int n = 0;
   for(int i=0; i<PositionsTotal(); i++)
      if(PositionInfo.SelectByIndex(i) &&
         PositionInfo.Symbol()==_Symbol &&
         PositionInfo.Magic()==InpMagic) n++;
   return n;
}

//══════════════════════════════════════════════════════════════════
// Dashboard
//══════════════════════════════════════════════════════════════════
void OnTimer()
{
   if(ArraySize(bufATR) < 2 || ArraySize(bufADX) < 2) return;
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayPL = (g_dayAnchorEq > 0) ? (eq - g_dayAnchorEq) / g_dayAnchorEq * 100.0 : 0.0;
   double spread= SymbolInfoObj.Ask() - SymbolInfoObj.Bid();

   string bias = "—";
   int b = BiasDirection();
   if(b > 0) bias = "↑ LONG";
   else if(b < 0) bias = "↓ SHORT";

   Comment(
      "ScalpBTC v1 — ", _Symbol, " ", EnumToString(Period()), "\n",
      "───────────────────────────────\n",
      "Bias EMA200 : ", bias, "\n",
      "ADX(",   IntegerToString(InpADXPeriod), ") : ", DoubleToString(bufADX[1], 1),
         "  (min ", DoubleToString(InpADXMin, 0), ")\n",
      "ATR        : ", DoubleToString(bufATR[1], 2), " USD\n",
      "Spread     : ", DoubleToString(spread, 2), " USD\n",
      "───────────────────────────────\n",
      "Positions  : ", IntegerToString(CountPos()), "/", IntegerToString(InpMaxConcurrent), "\n",
      "Equity     : ", DoubleToString(eq, 2), "\n",
      "Day P/L    : ", DoubleToString(dayPL, 2), " %  (cap -",
         DoubleToString(InpDailyLossPct, 1), "%)\n",
      "Cooldown   : ", CooldownOK() ? "OK" : "ACTIF"
   );
}
