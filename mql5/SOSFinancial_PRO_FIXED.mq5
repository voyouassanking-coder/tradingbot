//+------------------------------------------------------------------+
//|                    SOSFinancial_PRO_FIXED.mq5                     |
//|         Advanced Multi-Timeframe EA — version corrigee            |
//|                                                                   |
//|   Corrections par rapport a la v1.0 originale :                  |
//|     FIX #1 : whitelist symboles accepte BTCUSDm / variantes "m"  |
//|     FIX #2 : filtre spread en USD (plus en "pips" Forex)         |
//|     FIX #3 : partial close & BE en USD (plus en pips)            |
//|     FIX #4 : filling order auto-detecte (plus FOK code en dur)   |
//|     FIX #5 : indicateurs lus sur barre fermee (shift=1)          |
//|     FIX #6 : Kinjun-Sen sur barre fermee (shift=1)               |
//|     FIX #7 : Heiken Ashi avec formule recursive standard         |
//|     FIX #8 : stats win/loss par TRADE (plus par deal)            |
//|     FIX #9 : daily DD avec anchor reset minuit + anti-spam log   |
//|     FIX #10: signal evalue seulement a la cloture d'une H1       |
//|     FIX #11: STOPS_LEVEL respecte avant placement SL/TP          |
//|     FIX #12: BE arme une seule fois (flag par position)          |
//+------------------------------------------------------------------+
#property copyright "SOSFinancial PRO FIXED"
#property version   "1.10"
#property description "Multi-TF D1+H4+H1 — fixes BTC scalping"

#include <Trade\Trade.mqh>

//=== PARAMETRES UTILISATEUR =======================================
input group "=== GESTION DU RISQUE ==="
input double   InpRiskPercent      = 1.0;    // Risque par trade (%)
input double   InpRewardRatio      = 1.5;    // Ratio Reward/Risk (RR)
input double   InpATR_SL_Mult      = 1.0;    // SL = ATR x multiplicateur
input double   InpMaxDailyDD       = 20.0;   // Drawdown journalier max (%)

input group "=== FILTRES ==="
input double   InpMaxSpreadUSD     = 30.0;   // FIX #2 : Spread max en USD
input double   InpMinATR_USD       = 1.0;    // ATR minimum en USD
input int      InpTradeHourStart   = 8;      // Debut session (heure broker)
input int      InpTradeHourEnd     = 21;     // Fin session
input int      InpCooldownSec      = 300;    // Cooldown entre trades (sec)
input bool     InpSkipWeekend      = false;  // BTC 24/7 par defaut
input bool     InpSkipFridayLate   = false;  // idem

input group "=== PARTIAL CLOSE & BREAK-EVEN ==="
input bool     InpUsePartialClose  = true;
input double   InpPartialUSD       = 150.0;  // FIX #3 : declenche partial a +X USD
input double   InpPartialRatio     = 0.5;    // Ratio a fermer
input bool     InpUseBreakEven     = true;
input double   InpBreakEvenUSD     = 5.0;    // FIX #3 : offset BE en USD

input group "=== INDICATEURS ==="
input int      InpEMA21Period      = 21;
input int      InpEMA50Period      = 50;
input int      InpEMA200Period     = 200;
input int      InpRSIPeriod        = 21;
input int      InpADXPeriod        = 14;
input int      InpATRPeriod        = 14;
input int      InpKinjunPeriod     = 26;

input group "=== SEUILS D1 ==="
input double   InpD1_RSI_Up        = 55.0;
input double   InpD1_RSI_Down      = 45.0;
input double   InpD1_ADX_Min       = 20.0;

input group "=== SEUILS H4 ==="
input double   InpH4_RSI_Up        = 52.0;
input double   InpH4_RSI_Down      = 48.0;
input double   InpH4_ADX_Min       = 15.0;

input group "=== SEUILS H1 ==="
input double   InpH1_RSI_Buy       = 50.0;
input double   InpH1_RSI_Sell      = 50.0;

input group "=== OPTIONS PRO ==="
input bool     InpUseVolumeFilter  = true;
input bool     InpUseSilverTrend   = true;
input bool     InpUseFibFilter     = false;
input double   InpFib_Level        = 0.618;

input group "=== AVANCE ==="
input bool     InpRestrictSymbols  = false;  // FIX #1 : whitelist desactivee par defaut
input bool     InpEvalOnH1CloseOnly= true;   // FIX #10
input long     InpMagicNumber      = 202502;

//=== CONSTANTES INTERNES ==========================================
#define EA_NAME "SOSFinancial PRO FIXED v1.1"

string SupportedSymbols[] = {"XAUUSD","XAGEUR","XAGUSD","CHFJPY","UKOIL","USOIL",
                             "BTCUSD","BTCUSDm","BTCUSDc","BTCUSDi"};  // FIX #1

enum ETrend  { TR_NONE=0, TR_UP=1,   TR_DOWN=-1 };
enum ESignal { SG_NONE=0, SG_BUY=1,  SG_SELL=-1 };

//=== HANDLES ======================================================
int h_EMA21_D1=INVALID_HANDLE, h_EMA50_D1=INVALID_HANDLE, h_EMA200_D1=INVALID_HANDLE;
int h_RSI_D1=INVALID_HANDLE,   h_ADX_D1=INVALID_HANDLE,   h_ATR_D1=INVALID_HANDLE;
int h_EMA21_H4=INVALID_HANDLE, h_EMA50_H4=INVALID_HANDLE;
int h_RSI_H4=INVALID_HANDLE,   h_ADX_H4=INVALID_HANDLE;
int h_EMA21_H1=INVALID_HANDLE, h_EMA50_H1=INVALID_HANDLE;
int h_RSI_H1=INVALID_HANDLE,   h_ATR_H1=INVALID_HANDLE;
int h_ATR_CUR=INVALID_HANDLE;

//=== VARIABLES GLOBALES ===========================================
CTrade   g_trade;
datetime g_lastTrade     = 0;
datetime g_lastH1Bar     = 0;     // FIX #10
datetime g_dayAnchorDate = 0;     // FIX #9
double   g_dayAnchorEq   = 0.0;
bool     g_ddLogged      = false; // FIX #9
int      g_totalBuy      = 0;
int      g_totalSell     = 0;
int      g_wins          = 0;
int      g_losses        = 0;
double   g_totalProfit   = 0.0;
double   g_startBalance  = 0.0;

// FIX #8 : suivi des positions pour stats par TRADE
struct PosTrack { ulong ticket; double accumPnL; bool beArmed; };
PosTrack g_tracked[];

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double BufVal(int handle, int bufIdx, int shift)
{
   if(handle == INVALID_HANDLE) return EMPTY_VALUE;
   double tmp[1];
   if(CopyBuffer(handle, bufIdx, shift, 1, tmp) <= 0) return EMPTY_VALUE;
   return tmp[0];
}

//+------------------------------------------------------------------+
//| Kinjun-Sen sur barre fermee (FIX #6)                             |
//+------------------------------------------------------------------+
double Kinjun(ENUM_TIMEFRAMES tf, int shift)
{
   double hi[], lo[];
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   int per = InpKinjunPeriod;
   if(CopyHigh(_Symbol, tf, shift, per, hi) < per) return EMPTY_VALUE;
   if(CopyLow (_Symbol, tf, shift, per, lo) < per) return EMPTY_VALUE;
   double highest = hi[ArrayMaximum(hi, 0, per)];
   double lowest  = lo[ArrayMinimum(lo, 0, per)];
   return (highest + lowest) / 2.0;
}

//+------------------------------------------------------------------+
//| Heiken Ashi avec formule recursive correcte (FIX #7)             |
//+------------------------------------------------------------------+
bool HeikenAshiBullish(ENUM_TIMEFRAMES tf, int shift)
{
   const int NB = 60;
   double o[], h[], l[], c[];
   ArraySetAsSeries(o,true); ArraySetAsSeries(h,true);
   ArraySetAsSeries(l,true); ArraySetAsSeries(c,true);

   int total = NB + shift + 1;
   if(CopyOpen (_Symbol,tf,0,total,o) < total) return false;
   if(CopyHigh (_Symbol,tf,0,total,h) < total) return false;
   if(CopyLow  (_Symbol,tf,0,total,l) < total) return false;
   if(CopyClose(_Symbol,tf,0,total,c) < total) return false;

   double haOpen[];   ArrayResize(haOpen,  total);
   double haClose[];  ArrayResize(haClose, total);
   int last = total - 1;
   haOpen[last]  = (o[last] + c[last]) / 2.0;
   haClose[last] = (o[last] + h[last] + l[last] + c[last]) / 4.0;
   for(int i = last - 1; i >= 0; i--)
   {
      haClose[i] = (o[i] + h[i] + l[i] + c[i]) / 4.0;
      haOpen[i]  = (haOpen[i+1] + haClose[i+1]) / 2.0;
   }
   return haClose[shift] > haOpen[shift];
}

//+------------------------------------------------------------------+
//| Filtres PRO (tous lus shift=1, FIX #5)                           |
//+------------------------------------------------------------------+
bool VolumeOK(ESignal sig)
{
   if(!InpUseVolumeFilter) return true;
   long vols[];
   ArraySetAsSeries(vols, true);
   if(CopyTickVolume(_Symbol, PERIOD_H1, 0, 6, vols) < 6) return true;
   long avgVol = (vols[2]+vols[3]+vols[4]+vols[5]) / 4;
   return vols[1] >= avgVol;
}

bool SilverTrendOK(ESignal sig)
{
   if(!InpUseSilverTrend) return true;
   if(sig == SG_BUY)  return  HeikenAshiBullish(PERIOD_H1, 1);
   if(sig == SG_SELL) return !HeikenAshiBullish(PERIOD_H1, 1);
   return true;
}

double FibLevel(ENUM_TIMEFRAMES tf, int lookback, double ratio)
{
   double hi[], lo[];
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   if(CopyHigh(_Symbol, tf, 1, lookback, hi) < lookback) return EMPTY_VALUE;
   if(CopyLow (_Symbol, tf, 1, lookback, lo) < lookback) return EMPTY_VALUE;
   double highest = hi[ArrayMaximum(hi, 0, lookback)];
   double lowest  = lo[ArrayMinimum(lo, 0, lookback)];
   return lowest + (highest - lowest) * ratio;
}

bool FibOK(ESignal sig)
{
   if(!InpUseFibFilter) return true;
   double price = iClose(_Symbol, PERIOD_H1, 1);
   double fibPrice = FibLevel(PERIOD_H4, 50, InpFib_Level);
   if(fibPrice == EMPTY_VALUE) return true;
   double tolerance = BufVal(h_ATR_H1, 0, 1) * 0.5;
   if(tolerance <= 0) return true;
   return (MathAbs(price - fibPrice) <= tolerance);
}

//+------------------------------------------------------------------+
//| Init / release indicateurs                                       |
//+------------------------------------------------------------------+
bool InitIndicators()
{
   h_EMA21_D1  = iMA(_Symbol, PERIOD_D1, InpEMA21Period,  0, MODE_EMA, PRICE_CLOSE);
   h_EMA50_D1  = iMA(_Symbol, PERIOD_D1, InpEMA50Period,  0, MODE_EMA, PRICE_CLOSE);
   h_EMA200_D1 = iMA(_Symbol, PERIOD_D1, InpEMA200Period, 0, MODE_EMA, PRICE_CLOSE);
   h_RSI_D1    = iRSI(_Symbol, PERIOD_D1, InpRSIPeriod, PRICE_CLOSE);
   h_ADX_D1    = iADX(_Symbol, PERIOD_D1, InpADXPeriod);
   h_ATR_D1    = iATR(_Symbol, PERIOD_D1, InpATRPeriod);
   h_EMA21_H4  = iMA(_Symbol, PERIOD_H4, InpEMA21Period, 0, MODE_EMA, PRICE_CLOSE);
   h_EMA50_H4  = iMA(_Symbol, PERIOD_H4, InpEMA50Period, 0, MODE_EMA, PRICE_CLOSE);
   h_RSI_H4    = iRSI(_Symbol, PERIOD_H4, InpRSIPeriod, PRICE_CLOSE);
   h_ADX_H4    = iADX(_Symbol, PERIOD_H4, InpADXPeriod);
   h_EMA21_H1  = iMA(_Symbol, PERIOD_H1, InpEMA21Period, 0, MODE_EMA, PRICE_CLOSE);
   h_EMA50_H1  = iMA(_Symbol, PERIOD_H1, InpEMA50Period, 0, MODE_EMA, PRICE_CLOSE);
   h_RSI_H1    = iRSI(_Symbol, PERIOD_H1, InpRSIPeriod, PRICE_CLOSE);
   h_ATR_H1    = iATR(_Symbol, PERIOD_H1, InpATRPeriod);
   h_ATR_CUR   = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);

   if(h_EMA21_D1==INVALID_HANDLE || h_RSI_D1==INVALID_HANDLE ||
      h_EMA21_H4==INVALID_HANDLE || h_EMA21_H1==INVALID_HANDLE ||
      h_ATR_H1  ==INVALID_HANDLE || h_ATR_CUR ==INVALID_HANDLE) {
      Print("✗ Erreur creation indicateurs : ", GetLastError());
      return false;
   }
   return true;
}

void ReleaseIndicators()
{
   int arr[] = {h_EMA21_D1,h_EMA50_D1,h_EMA200_D1,h_RSI_D1,h_ADX_D1,h_ATR_D1,
                h_EMA21_H4,h_EMA50_H4,h_RSI_H4,h_ADX_H4,
                h_EMA21_H1,h_EMA50_H1,h_RSI_H1,h_ATR_H1,h_ATR_CUR};
   for(int i=0;i<ArraySize(arr);i++)
      if(arr[i]!=INVALID_HANDLE) IndicatorRelease(arr[i]);
}

//+------------------------------------------------------------------+
//| Calcul lot size (broker-agnostic via TICK_VALUE_LOSS)            |
//+------------------------------------------------------------------+
double CalcLotSize(double slDistance)
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk     = balance * InpRiskPercent / 100.0;
   double tickSz   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickVL   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   double step     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(tickSz<=0 || tickVL<=0 || step<=0) return minLot;

   double lossPerLot = (slDistance / tickSz) * tickVL;
   if(lossPerLot <= 0) return minLot;

   double lots = risk / lossPerLot;
   lots = MathFloor(lots/step) * step;
   if(lots<minLot) lots=minLot;
   if(lots>maxLot) lots=maxLot;
   return lots;
}

//+------------------------------------------------------------------+
//| Analyses D1 / H4 / H1 — sur barre fermee (FIX #5)               |
//+------------------------------------------------------------------+
ETrend AnalyzeD1()
{
   double ema21  = BufVal(h_EMA21_D1,  0, 1);
   double ema50  = BufVal(h_EMA50_D1,  0, 1);
   double ema200 = BufVal(h_EMA200_D1, 0, 1);
   double rsi    = BufVal(h_RSI_D1,    0, 1);
   double adx    = BufVal(h_ADX_D1,    0, 1);
   double price  = iClose(_Symbol, PERIOD_D1, 1);

   if(ema21==EMPTY_VALUE||ema50==EMPTY_VALUE||ema200==EMPTY_VALUE) return TR_NONE;
   if(rsi==EMPTY_VALUE||adx==EMPTY_VALUE) return TR_NONE;

   if(ema21>ema50 && ema50>ema200 && price>ema200 &&
      rsi>InpD1_RSI_Up && adx>InpD1_ADX_Min) return TR_UP;
   if(ema21<ema50 && ema50<ema200 && price<ema200 &&
      rsi<InpD1_RSI_Down && adx>InpD1_ADX_Min) return TR_DOWN;
   return TR_NONE;
}

ETrend AnalyzeH4()
{
   double ema21  = BufVal(h_EMA21_H4, 0, 1);
   double ema50  = BufVal(h_EMA50_H4, 0, 1);
   double rsi    = BufVal(h_RSI_H4,   0, 1);
   double adx    = BufVal(h_ADX_H4,   0, 1);
   double kinjun = Kinjun(PERIOD_H4, 1);
   double price  = iClose(_Symbol, PERIOD_H4, 1);

   if(ema21==EMPTY_VALUE||ema50==EMPTY_VALUE||rsi==EMPTY_VALUE||adx==EMPTY_VALUE) return TR_NONE;
   if(kinjun==EMPTY_VALUE) return TR_NONE;

   if(ema21>ema50 && price>kinjun && rsi>InpH4_RSI_Up && adx>InpH4_ADX_Min) return TR_UP;
   if(ema21<ema50 && price<kinjun && rsi<InpH4_RSI_Down && adx>InpH4_ADX_Min) return TR_DOWN;
   return TR_NONE;
}

ESignal AnalyzeH1()
{
   double ema21  = BufVal(h_EMA21_H1, 0, 1);
   double ema50  = BufVal(h_EMA50_H1, 0, 1);
   double rsi    = BufVal(h_RSI_H1,   0, 1);
   double kinjun = Kinjun(PERIOD_H1, 1);
   double price  = iClose(_Symbol, PERIOD_H1, 1);

   if(ema21==EMPTY_VALUE||ema50==EMPTY_VALUE||rsi==EMPTY_VALUE||kinjun==EMPTY_VALUE) return SG_NONE;

   if(ema21>ema50 && price>kinjun && price>ema21 && rsi>InpH1_RSI_Buy)  return SG_BUY;
   if(ema21<ema50 && price<kinjun && price<ema21 && rsi<InpH1_RSI_Sell) return SG_SELL;
   return SG_NONE;
}

//+------------------------------------------------------------------+
//| Filtres exec                                                     |
//+------------------------------------------------------------------+
bool SpreadOK()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   return (ask - bid) <= InpMaxSpreadUSD;  // FIX #2
}

bool VolatilityOK()
{
   double atr = BufVal(h_ATR_CUR, 0, 1);
   return (atr != EMPTY_VALUE && atr >= InpMinATR_USD);
}

bool SessionOK()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpSkipWeekend && (dt.day_of_week==0 || dt.day_of_week==6)) return false;
   if(InpSkipFridayLate && dt.day_of_week==5 && dt.hour>=17) return false;
   return (dt.hour>=InpTradeHourStart && dt.hour<InpTradeHourEnd);
}

bool DrawdownOK()
{
   // FIX #9
   MqlDateTime now; TimeToStruct(TimeCurrent(), now);
   MqlDateTime anc; TimeToStruct(g_dayAnchorDate, anc);
   if(g_dayAnchorDate==0 || now.day!=anc.day || now.mon!=anc.mon || now.year!=anc.year)
   {
      g_dayAnchorDate = TimeCurrent();
      g_dayAnchorEq   = AccountInfoDouble(ACCOUNT_EQUITY);
      g_ddLogged      = false;
   }
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_dayAnchorEq<=0) return true;
   double dd = (g_dayAnchorEq - eq) / g_dayAnchorEq * 100.0;
   if(dd >= InpMaxDailyDD) {
      if(!g_ddLogged) {
         PrintFormat("⚠ DAILY DD %.2f%% >= %.1f%% — stop jusqu'a demain", dd, InpMaxDailyDD);
         g_ddLogged = true;
      }
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Tracking positions (FIX #8 + FIX #12)                            |
//+------------------------------------------------------------------+
int FindTracked(ulong ticket)
{
   for(int i=0; i<ArraySize(g_tracked); i++)
      if(g_tracked[i].ticket == ticket) return i;
   return -1;
}

void RegisterPosition(ulong ticket)
{
   int n = ArraySize(g_tracked);
   ArrayResize(g_tracked, n+1);
   g_tracked[n].ticket  = ticket;
   g_tracked[n].accumPnL= 0.0;
   g_tracked[n].beArmed = false;
}

void RemoveTracked(int idx)
{
   int n = ArraySize(g_tracked);
   if(idx<0 || idx>=n) return;
   for(int i=idx; i<n-1; i++) g_tracked[i] = g_tracked[i+1];
   ArrayResize(g_tracked, n-1);
}

//+------------------------------------------------------------------+
//| Gestion positions                                                |
//+------------------------------------------------------------------+
void ManagePositions()
{
   long stopsLvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLvl * _Point;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!ticket) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curPrice  = PositionGetDouble(POSITION_PRICE_CURRENT);
      double volume    = PositionGetDouble(POSITION_VOLUME);
      double curSL     = PositionGetDouble(POSITION_SL);
      double curTP     = PositionGetDouble(POSITION_TP);

      double profitUSD = (pt==POSITION_TYPE_BUY) ? (curPrice-openPrice)
                                                  : (openPrice-curPrice);

      int idx = FindTracked(ticket);
      if(idx<0) { RegisterPosition(ticket); idx = ArraySize(g_tracked)-1; }

      // Partial close (FIX #3)
      if(InpUsePartialClose && profitUSD >= InpPartialUSD)
      {
         double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         if(step<=0) step=0.01;
         double closeVol = MathFloor(volume*InpPartialRatio/step)*step;
         if(closeVol>=minLot && closeVol<volume)
         {
            if(g_trade.PositionClosePartial(ticket, closeVol))
               PrintFormat("✓ PARTIAL %.2f lots @ %.2f  (+%.2f USD)",
                           closeVol, curPrice, profitUSD);
         }
      }

      // Break-Even une seule fois (FIX #12)
      if(InpUseBreakEven && !g_tracked[idx].beArmed && profitUSD >= InpPartialUSD)
      {
         double newSL = 0;
         if(pt==POSITION_TYPE_BUY  && curSL<openPrice)
            newSL = openPrice + InpBreakEvenUSD;
         else if(pt==POSITION_TYPE_SELL && curSL>openPrice)
            newSL = openPrice - InpBreakEvenUSD;

         // FIX #11 : stops level
         if(newSL > 0 && MathAbs(curPrice - newSL) >= minDist)
         {
            if(g_trade.PositionModify(ticket, newSL, curTP))
            {
               g_tracked[idx].beArmed = true;
               PrintFormat("✓ BE arme @ %.2f", newSL);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Ouvertures                                                       |
//+------------------------------------------------------------------+
void OpenBuy(bool volOK, bool silverOK, bool fibOK)
{
   if(!volOK || !silverOK || !fibOK) return;
   if((int)(TimeCurrent()-g_lastTrade) < InpCooldownSec) return;

   double atr = BufVal(h_ATR_H1, 0, 1);
   if(atr<=0||atr==EMPTY_VALUE) return;

   double slDist = atr * InpATR_SL_Mult;
   if(slDist <= 0) return;
   double lots = CalcLotSize(slDist);
   if(lots<=0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl  = ask - slDist;
   double tp  = ask + slDist * InpRewardRatio;

   long stopsLvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLvl * _Point;
   if(ask - sl < minDist || tp - ask < minDist) return;  // FIX #11

   if(g_trade.Buy(lots, _Symbol, ask, sl, tp, "SOS-PRO-BUY"))
   {
      g_lastTrade = TimeCurrent();
      g_totalBuy++;
      RegisterPosition(g_trade.ResultOrder());
      PrintFormat("▲ BUY %.2f @ %.2f SL=%.2f TP=%.2f", lots, ask, sl, tp);
   }
   else PrintFormat("✗ BUY rejected: %d %s",
                    g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
}

void OpenSell(bool volOK, bool silverOK, bool fibOK)
{
   if(!volOK || !silverOK || !fibOK) return;
   if((int)(TimeCurrent()-g_lastTrade) < InpCooldownSec) return;

   double atr = BufVal(h_ATR_H1, 0, 1);
   if(atr<=0||atr==EMPTY_VALUE) return;

   double slDist = atr * InpATR_SL_Mult;
   if(slDist <= 0) return;
   double lots = CalcLotSize(slDist);
   if(lots<=0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl  = bid + slDist;
   double tp  = bid - slDist * InpRewardRatio;

   long stopsLvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLvl * _Point;
   if(sl - bid < minDist || bid - tp < minDist) return;

   if(g_trade.Sell(lots, _Symbol, bid, sl, tp, "SOS-PRO-SELL"))
   {
      g_lastTrade = TimeCurrent();
      g_totalSell++;
      RegisterPosition(g_trade.ResultOrder());
      PrintFormat("▼ SELL %.2f @ %.2f SL=%.2f TP=%.2f", lots, bid, sl, tp);
   }
   else PrintFormat("✗ SELL rejected: %d %s",
                    g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Affichage                                                        |
//+------------------------------------------------------------------+
void DisplayPRO(ETrend d1, ETrend h4, ESignal h1,
                bool volOK, bool silverOK, bool fibOK)
{
   string sd1 = (d1==TR_UP)?"UP ▲":(d1==TR_DOWN)?"DOWN ▼":"—";
   string sh4 = (h4==TR_UP)?"UP ▲":(h4==TR_DOWN)?"DOWN ▼":"—";
   string sh1 = (h1==SG_BUY)?"BUY ▲":(h1==SG_SELL)?"SELL ▼":"—";
   int    tot = g_totalBuy+g_totalSell;
   double wr  = (tot>0)?((double)g_wins/tot*100.0):0.0;
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd  = (g_dayAnchorEq>0)?(g_dayAnchorEq-eq)/g_dayAnchorEq*100.0:0.0;
   double spreadUSD = SymbolInfoDouble(_Symbol,SYMBOL_ASK) - SymbolInfoDouble(_Symbol,SYMBOL_BID);

   string txt = "\n  " + EA_NAME + "\n";
   txt += "  ══════════════════════════════════════\n";
   txt += "  " + _Symbol + " | " + TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES) + "\n";
   txt += "  D1: " + sd1 + "  H4: " + sh4 + "  H1: " + sh1 + "\n";
   txt += "  Vol:" + (volOK?"✓":"✗") + " HA:" + (silverOK?"✓":"✗") +
          " Fib:" + (fibOK?"✓":"✗") + "  Spread:" + DoubleToString(spreadUSD,2) + "$\n";
   txt += "  Daily DD : " + DoubleToString(dd,2) + "% / " + DoubleToString(InpMaxDailyDD,0) + "%\n";
   txt += "  Balance  : $" + DoubleToString(bal,2) + "  Equity: $" + DoubleToString(eq,2) + "\n";
   txt += "  Trades   : " + IntegerToString(tot) + " (B" + IntegerToString(g_totalBuy) +
          "/S" + IntegerToString(g_totalSell) + ")  WR " + DoubleToString(wr,1) + "%\n";
   txt += "  Wins/L   : " + IntegerToString(g_wins) + "/" + IntegerToString(g_losses) +
          "  PnL: $" + DoubleToString(g_totalProfit,2) + "\n";
   Comment(txt);
}

//+------------------------------------------------------------------+
//| OnInit / OnDeinit                                                |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("== ", EA_NAME, " initialisation ==");

   if(InpRestrictSymbols)  // FIX #1
   {
      bool ok = false;
      for(int i=0; i<ArraySize(SupportedSymbols); i++)
         if(_Symbol==SupportedSymbols[i]) { ok=true; break; }
      if(!ok) {
         Print("✗ Symbole '", _Symbol, "' non whiteliste (decoche InpRestrictSymbols pour autoriser)");
         return INIT_PARAMETERS_INCORRECT;
      }
   }

   if(!InitIndicators()) return INIT_FAILED;

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(50);
   g_trade.SetTypeFillingBySymbol(_Symbol);  // FIX #4

   g_startBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dayAnchorDate = TimeCurrent();
   g_dayAnchorEq   = AccountInfoDouble(ACCOUNT_EQUITY);

   Print("✓ ", _Symbol, " | Risk ", InpRiskPercent, "% | RR 1:", InpRewardRatio);
   Print("✓ Session ", InpTradeHourStart, "h-", InpTradeHourEnd, "h (heure broker)");
   Print("✓ Spread cap ", InpMaxSpreadUSD, " USD | Partial @ +",
         InpPartialUSD, " USD | BE +", InpBreakEvenUSD, " USD");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
   ReleaseIndicators();
   int tot = g_totalBuy+g_totalSell;
   double wr = (tot>0)?((double)g_wins/tot*100.0):0.0;
   PrintFormat("== Session : %d trades, W=%d L=%d (%.1f%%), PnL=$%.2f ==",
               tot, g_wins, g_losses, wr, g_totalProfit);
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   ManagePositions();

   if(!SpreadOK()||!VolatilityOK()||!SessionOK()) { Comment(""); return; }
   if(!DrawdownOK()) return;

   // FIX #10 : signal evalue seulement a la cloture d'une H1
   if(InpEvalOnH1CloseOnly)
   {
      datetime curH1 = iTime(_Symbol, PERIOD_H1, 0);
      if(curH1 == g_lastH1Bar) return;
      g_lastH1Bar = curH1;
   }

   ETrend  d1 = AnalyzeD1();
   ETrend  h4 = AnalyzeH4();
   ESignal h1 = AnalyzeH1();

   bool volOK    = VolumeOK(h1);
   bool silverOK = SilverTrendOK(h1);
   bool fibOK    = FibOK(h1);

   if(PositionsTotal() == 0)
   {
      if(d1==TR_UP && h4==TR_UP && h1==SG_BUY)
         OpenBuy(volOK, silverOK, fibOK);
      else if(d1==TR_DOWN && h4==TR_DOWN && h1==SG_SELL)
         OpenSell(volOK, silverOK, fibOK);
   }

   DisplayPRO(d1, h4, h1, volOK, silverOK, fibOK);
}

//+------------------------------------------------------------------+
//| OnTradeTransaction — stats par TRADE (FIX #8)                   |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &req,
                        const MqlTradeResult      &res)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if((long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;

   ulong posID = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   g_totalProfit += profit;

   int idx = FindTracked(posID);
   if(idx >= 0)
   {
      g_tracked[idx].accumPnL += profit;
      // Si la position n'existe plus -> close, on compte
      if(!PositionSelectByTicket(posID))
      {
         if(g_tracked[idx].accumPnL > 0) g_wins++;
         else if(g_tracked[idx].accumPnL < 0) g_losses++;
         RemoveTracked(idx);
      }
   }
}
