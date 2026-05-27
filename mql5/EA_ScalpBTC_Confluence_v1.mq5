//+==================================================================+
//|   EA_ScalpBTC_Confluence_v1.mq5                                   |
//|   Scalping BTCUSD — Ichimoku multi-TF + SMC confluence            |
//|                                                                   |
//|   Spec :                                                          |
//|     • Symbole : BTCUSD                                            |
//|     • Exécution M1, biais M15 + H1                                |
//|     • Trades 2 min moyenne, 5 min max                             |
//|     • Confluence Ichimoku (M15 + H1) + stack MA (6) + SMC          |
//|     • Triggers : OTE Fib, FVG retest, breaker block, engulfing    |
//|     • Ordre stop au break de la bougie de signal (valide 1 bougie)|
//|     • Pas de SL, TP fixe 5 USD prix, BE à +2 USD (après 30 s)     |
//|     • Time-stop 5 min, force-close fin de session                 |
//|     • Sessions Londres+NY 09:00–23:00 GMT, mardi–samedi           |
//|     • News : lockout 10×M15, close all à l'entrée d'une fenêtre   |
//|     • Caps : 100 trades/jour, 5 SL consécutifs, -10 USD journée   |
//+==================================================================+
#property copyright "ScalpBTC Confluence v1"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\SymbolInfo.mqh>

CTrade        Trade;
CPositionInfo PositionInfo;
COrderInfo    OrderInfo;
CSymbolInfo   SymbolInfoObj;

//══════════════════════════════════════════════════════════════════
// INPUTS
//══════════════════════════════════════════════════════════════════
input group "=== GÉNÉRAL ==="
input long   InpMagic           = 770002;
input string InpComment         = "ScalpBTC_CFL";
input double InpFixedLot        = 0.01;     // Lot fixe (no-SL → pas de risk sizing)
input bool   InpVerboseLog      = true;

input group "=== TP / BE / TIME ==="
input double InpTPPriceUSD      = 5.0;      // TP en distance de prix BTC (USD)
input double InpBETriggerUSD    = 2.0;      // BE armé quand gain ≥ 2 USD de prix
input double InpBEOffsetUSD     = 0.10;     // Offset BE (couvre commission éventuelle)
input int    InpBEArmDelaySec   = 30;       // Délai après entrée avant que BE soit éligible
input int    InpMaxTradeMinutes = 5;        // Time-stop (durée max)

input group "=== SESSIONS (heure broker = GMT supposé) ==="
input bool   InpUseSessions     = true;
input int    InpSessionStartH   = 9;        // Ouverture Londres
input int    InpSessionEndH     = 23;       // Fin NY
input bool   InpSkipSunMon      = true;     // Trade mardi–samedi seulement
input int    InpForceCloseEndH  = 23;       // Force-close à cette heure

input group "=== CAPS / LOSS-STREAK ==="
input int    InpDailyMaxTrades  = 100;
input int    InpMaxConsecLoss   = 5;
input double InpDailyLossCapUSD = 10.0;     // Stop journée si perte cumulée ≥ ce montant
input int    InpLockoutM15Bars  = 10;       // Bougies M15 d'attente après lockout

input group "=== NEWS (fenêtres manuelles) ==="
input string InpNews1           = "";       // Format: "YYYY.MM.DD HH:MM+DUR" (DUR en min)
input string InpNews2           = "";
input string InpNews3           = "";
input string InpNews4           = "";
input string InpNews5           = "";
input bool   InpManualNewsHalt  = false;    // Flag d'arrêt manuel (à flipper en live)

input group "=== BIAIS — ICHIMOKU MULTI-TF ==="
input ENUM_TIMEFRAMES InpBiasTF1 = PERIOD_M15;
input ENUM_TIMEFRAMES InpBiasTF2 = PERIOD_H1;
input int    InpTenkan           = 9;
input int    InpKijun            = 26;
input int    InpSenkouB          = 52;

input group "=== BIAIS — MA STACK (sur TF1) ==="
input int    InpEMA1             = 5;
input int    InpEMA2             = 8;
input int    InpEMA3             = 21;
input int    InpEMA4             = 55;
input int    InpSMA1             = 100;
input int    InpSMA2             = 200;
input int    InpMASlopeBars      = 2;       // MA[1] vs MA[1+N] pour pente

input group "=== RANGE DETECTION (sur TF1) ==="
input double InpKijunFlatPctATR  = 0.20;    // |Kijun[1]-Kijun[5]| < ATR × ce mult → plate
input double InpTKDistPctATR     = 0.35;    // |Tenkan-Kijun| < ATR × ce mult → collées
input double InpThinCloudPctATR  = 0.40;    // |SenkouA-SenkouB| < ATR × ce mult → fin
input int    InpRangeATRPeriod   = 14;

input group "=== TRIGGERS M1 ==="
input int    InpMinConfluence    = 1;       // 1=tout signal seul, 2=magique
input int    InpSwingLookback    = 60;      // Bars M1 pour swing high/low
input int    InpFractalWidth     = 2;       // Fractal 2-bars-each-side (5 bars)
input double InpOTE_Low          = 0.62;    // OTE inférieure
input double InpOTE_High         = 0.79;    // OTE supérieure
input int    InpFVG_Lookback     = 40;      // Bars pour chercher FVG actif
input double InpFVG_MinSizeUSD   = 1.5;     // Taille min FVG (USD)
input bool   InpUseOTE           = true;
input bool   InpUseFVG           = true;
input bool   InpUseBreaker       = true;
input bool   InpUseEngulfing     = true;

input group "=== EXÉCUTION ==="
input int    InpDeviationPoints  = 100;
input int    InpStopOrderOffsetPt= 5;       // Offset au-dessus/dessous high/low signal (en points)
input int    InpPendingExpireBars= 1;       // Bougies M1 de validité du stop pendant

//══════════════════════════════════════════════════════════════════
// HANDLES & BUFFERS
//══════════════════════════════════════════════════════════════════
int hIchi_TF1, hIchi_TF2;
int hMA[6];                 // EMA5, EMA8, EMA21, EMA55, SMA100, SMA200 sur TF1
int hATR_TF1;
int hATR_M1;

double bufTenkan1[], bufKijun1[], bufSpanA1[], bufSpanB1[], bufChikou1[];
double bufTenkan2[], bufKijun2[], bufSpanA2[], bufSpanB2[], bufChikou2[];
double bufMA0[], bufMA1[], bufMA2[], bufMA3[], bufMA4[], bufMA5[];
double bufATR_TF1[];
double bufATR_M1[];

// Helpers pour accéder uniformément aux 6 buffers MA
double MABuf(int i, int shift)
{
   switch(i)
   {
      case 0: return bufMA0[shift];
      case 1: return bufMA1[shift];
      case 2: return bufMA2[shift];
      case 3: return bufMA3[shift];
      case 4: return bufMA4[shift];
      case 5: return bufMA5[shift];
   }
   return 0;
}

//══════════════════════════════════════════════════════════════════
// ÉTAT
//══════════════════════════════════════════════════════════════════
datetime g_lastBarM1        = 0;
datetime g_dayAnchorDate    = 0;
double   g_dayAnchorEq      = 0;
double   g_dayRealizedUSD   = 0;
int      g_dayTradesCount   = 0;
int      g_consecLosses     = 0;
datetime g_lockoutUntil     = 0;     // Fin du lockout (loss streak, daily cap, news)
datetime g_newsWindows[10][2];        // start/end pairs (max 5×2)
int      g_newsCount        = 0;
bool     g_newsActiveCached = false;
ulong    g_pendingTicket    = 0;
datetime g_pendingExpire    = 0;
int      g_pendingDir       = 0;
double   g_lastClosedPnL    = 0;

//══════════════════════════════════════════════════════════════════
// OnInit / OnDeinit
//══════════════════════════════════════════════════════════════════
int OnInit()
{
   if(!SymbolInfoObj.Name(_Symbol)) { Print("❌ Symbole introuvable"); return INIT_FAILED; }
   SymbolInfoObj.RefreshRates();

   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints(InpDeviationPoints);
   Trade.SetTypeFillingBySymbol(_Symbol);

   hIchi_TF1 = iIchimoku(_Symbol, InpBiasTF1, InpTenkan, InpKijun, InpSenkouB);
   hIchi_TF2 = iIchimoku(_Symbol, InpBiasTF2, InpTenkan, InpKijun, InpSenkouB);
   if(hIchi_TF1==INVALID_HANDLE || hIchi_TF2==INVALID_HANDLE) { Print("❌ Ichimoku handles"); return INIT_FAILED; }

   int periods[6] = {InpEMA1, InpEMA2, InpEMA3, InpEMA4, InpSMA1, InpSMA2};
   ENUM_MA_METHOD methods[6] = {MODE_EMA, MODE_EMA, MODE_EMA, MODE_EMA, MODE_SMA, MODE_SMA};
   for(int i=0; i<6; i++)
   {
      hMA[i] = iMA(_Symbol, InpBiasTF1, periods[i], 0, methods[i], PRICE_CLOSE);
      if(hMA[i] == INVALID_HANDLE) { PrintFormat("❌ MA handle #%d", i); return INIT_FAILED; }
   }
   ArraySetAsSeries(bufMA0, true); ArraySetAsSeries(bufMA1, true);
   ArraySetAsSeries(bufMA2, true); ArraySetAsSeries(bufMA3, true);
   ArraySetAsSeries(bufMA4, true); ArraySetAsSeries(bufMA5, true);

   hATR_TF1 = iATR(_Symbol, InpBiasTF1, InpRangeATRPeriod);
   hATR_M1  = iATR(_Symbol, PERIOD_M1,  14);
   if(hATR_TF1==INVALID_HANDLE || hATR_M1==INVALID_HANDLE) { Print("❌ ATR handles"); return INIT_FAILED; }

   ArraySetAsSeries(bufTenkan1, true); ArraySetAsSeries(bufKijun1, true);
   ArraySetAsSeries(bufSpanA1,  true); ArraySetAsSeries(bufSpanB1, true);
   ArraySetAsSeries(bufChikou1, true);
   ArraySetAsSeries(bufTenkan2, true); ArraySetAsSeries(bufKijun2, true);
   ArraySetAsSeries(bufSpanA2,  true); ArraySetAsSeries(bufSpanB2, true);
   ArraySetAsSeries(bufChikou2, true);
   ArraySetAsSeries(bufATR_TF1, true);
   ArraySetAsSeries(bufATR_M1,  true);

   ParseNewsWindows();
   ResetDailyAnchor();
   EventSetTimer(15);

   Print("✅ ScalpBTC Confluence v1 init | ", _Symbol);
   PrintFormat("   Bias: %s + %s | MA stack: %d %d %d %d %d %d",
               EnumToString(InpBiasTF1), EnumToString(InpBiasTF2),
               InpEMA1, InpEMA2, InpEMA3, InpEMA4, InpSMA1, InpSMA2);
   PrintFormat("   TP=%.2f USD | BE@%.2f USD (delay %ds) | Tmax=%dmin",
               InpTPPriceUSD, InpBETriggerUSD, InpBEArmDelaySec, InpMaxTradeMinutes);
   PrintFormat("   Session %02d-%02d, Tue-Sat=%s, News windows=%d",
               InpSessionStartH, InpSessionEndH, (InpSkipSunMon?"yes":"no"), g_newsCount);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hIchi_TF1); IndicatorRelease(hIchi_TF2);
   IndicatorRelease(hATR_TF1);  IndicatorRelease(hATR_M1);
   for(int i=0; i<6; i++) IndicatorRelease(hMA[i]);
   EventKillTimer();
}

//══════════════════════════════════════════════════════════════════
// OnTick
//══════════════════════════════════════════════════════════════════
void OnTick()
{
   SymbolInfoObj.RefreshRates();

   ManageOpenPositions();
   ManagePendingOrder();

   // News : check à chaque tick (close all si on entre dans une fenêtre)
   bool nowNews = IsInNewsWindow(TimeCurrent()) || InpManualNewsHalt;
   if(nowNews && !g_newsActiveCached)
   {
      // Transition off→on : on ferme tout et on arme le lockout
      if(InpVerboseLog) Print("📰 News window ENTRÉE → close all + lockout");
      CloseAllPositionsAndOrders();
      ArmLockout("news");
   }
   g_newsActiveCached = nowNews;

   datetime cur = iTime(_Symbol, PERIOD_M1, 0);
   if(cur == g_lastBarM1) return;
   g_lastBarM1 = cur;

   RollDailyIfNeeded();
   if(!LoadBuffers()) return;

   // Force-close session
   if(IsAfterForceCloseHour()) { CloseAllPositionsAndOrders(); return; }

   // Gates d'entrée
   if(!SessionOK())                 return;
   if(g_newsActiveCached)            return;
   if(TimeCurrent() < g_lockoutUntil) return;
   if(g_dayTradesCount >= InpDailyMaxTrades) return;
   if(g_dayRealizedUSD <= -InpDailyLossCapUSD) { ArmLockout("daily-cap"); return; }
   if(HasOpenPositionOrOrder())     return;
   if(IsRange())                    return;

   int bias = GetBias();
   if(bias == 0)                    return;

   int dir = GetTrigger(bias);
   if(dir == 0)                     return;

   PlaceStopOrder(dir);
}

//══════════════════════════════════════════════════════════════════
// LOAD BUFFERS
//══════════════════════════════════════════════════════════════════
bool LoadBuffers()
{
   int need = MathMax(60, InpSwingLookback + 10);

   if(CopyBuffer(hIchi_TF1, 0, 0, need, bufTenkan1) < 30) return false;
   if(CopyBuffer(hIchi_TF1, 1, 0, need, bufKijun1)  < 30) return false;
   if(CopyBuffer(hIchi_TF1, 2, 0, need, bufSpanA1)  < 30) return false;
   if(CopyBuffer(hIchi_TF1, 3, 0, need, bufSpanB1)  < 30) return false;
   if(CopyBuffer(hIchi_TF1, 4, 0, need, bufChikou1) < 30) return false;

   if(CopyBuffer(hIchi_TF2, 0, 0, 60, bufTenkan2) < 30) return false;
   if(CopyBuffer(hIchi_TF2, 1, 0, 60, bufKijun2)  < 30) return false;
   if(CopyBuffer(hIchi_TF2, 2, 0, 60, bufSpanA2)  < 30) return false;
   if(CopyBuffer(hIchi_TF2, 3, 0, 60, bufSpanB2)  < 30) return false;
   if(CopyBuffer(hIchi_TF2, 4, 0, 60, bufChikou2) < 30) return false;

   if(CopyBuffer(hMA[0], 0, 0, 10, bufMA0) < 5) return false;
   if(CopyBuffer(hMA[1], 0, 0, 10, bufMA1) < 5) return false;
   if(CopyBuffer(hMA[2], 0, 0, 10, bufMA2) < 5) return false;
   if(CopyBuffer(hMA[3], 0, 0, 10, bufMA3) < 5) return false;
   if(CopyBuffer(hMA[4], 0, 0, 10, bufMA4) < 5) return false;
   if(CopyBuffer(hMA[5], 0, 0, 10, bufMA5) < 5) return false;

   if(CopyBuffer(hATR_TF1, 0, 0, 10, bufATR_TF1) < 5) return false;
   if(CopyBuffer(hATR_M1,  0, 0, 10, bufATR_M1)  < 5) return false;
   return true;
}

//══════════════════════════════════════════════════════════════════
// SESSION / TEMPS
//══════════════════════════════════════════════════════════════════
bool SessionOK()
{
   if(!InpUseSessions) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(InpSkipSunMon && (dt.day_of_week == 0 || dt.day_of_week == 1)) return false;
   if(InpSessionStartH <= InpSessionEndH)
      return (dt.hour >= InpSessionStartH && dt.hour < InpSessionEndH);
   return (dt.hour >= InpSessionStartH || dt.hour < InpSessionEndH);
}

bool IsAfterForceCloseHour()
{
   if(!InpUseSessions) return false;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return dt.hour >= InpForceCloseEndH;
}

//══════════════════════════════════════════════════════════════════
// NEWS WINDOWS
//══════════════════════════════════════════════════════════════════
void ParseNewsWindows()
{
   g_newsCount = 0;
   string inputs[5];
   inputs[0] = InpNews1; inputs[1] = InpNews2; inputs[2] = InpNews3;
   inputs[3] = InpNews4; inputs[4] = InpNews5;
   for(int i=0; i<5; i++)
   {
      string s = inputs[i];
      StringTrimLeft(s); StringTrimRight(s);
      if(StringLen(s) < 5) continue;

      int plus = StringFind(s, "+");
      int dur  = 30;
      string dtStr = s;
      if(plus > 0)
      {
         dtStr = StringSubstr(s, 0, plus);
         dur   = (int)StringToInteger(StringSubstr(s, plus+1));
         if(dur <= 0) dur = 30;
      }
      datetime start = StringToTime(dtStr);
      if(start <= 0) continue;
      g_newsWindows[g_newsCount][0] = start;
      g_newsWindows[g_newsCount][1] = start + dur * 60;
      g_newsCount++;
   }
}

bool IsInNewsWindow(datetime t)
{
   for(int i=0; i<g_newsCount; i++)
      if(t >= g_newsWindows[i][0] && t < g_newsWindows[i][1]) return true;
   return false;
}

void ArmLockout(const string reason)
{
   long M15sec = PeriodSeconds(PERIOD_M15);
   g_lockoutUntil = TimeCurrent() + InpLockoutM15Bars * M15sec;
   if(InpVerboseLog) PrintFormat("🔒 Lockout (%s) jusqu'à %s",
                                 reason, TimeToString(g_lockoutUntil, TIME_DATE|TIME_MINUTES));
}

//══════════════════════════════════════════════════════════════════
// BIAS : Ichimoku TF1 + TF2 + MA stack
//══════════════════════════════════════════════════════════════════
int GetBias()
{
   int b1 = IchimokuBias(bufTenkan1, bufKijun1, bufSpanA1, bufSpanB1, InpBiasTF1);
   if(b1 == 0) return 0;
   int b2 = IchimokuBias(bufTenkan2, bufKijun2, bufSpanA2, bufSpanB2, InpBiasTF2);
   if(b2 == 0 || b2 != b1) return 0;
   int m = MAStackBias(b1);
   if(m == 0) return 0;
   return b1;
}

// Vérifie les 5 conditions Ichimoku sur une TF, retourne +1/-1/0
int IchimokuBias(const double &tenkan[], const double &kijun[],
                 const double &spanA[],  const double &spanB[],
                 ENUM_TIMEFRAMES tf)
{
   // Prix de référence : close de la dernière bougie close sur la TF
   double close1 = iClose(_Symbol, tf, 1);
   if(close1 <= 0) return 0;

   // Cloud à la position actuelle (Senkou décalé 26 → on lit shift 26)
   double cloudA_now = spanA[26];
   double cloudB_now = spanB[26];
   double cloudTop    = MathMax(cloudA_now, cloudB_now);
   double cloudBot    = MathMin(cloudA_now, cloudB_now);

   // Future cloud (26 ahead) = shift 0 dans le buffer
   double cloudA_fut = spanA[0];
   double cloudB_fut = spanB[0];

   // Chikou : close[0] vs close[26]
   double close0  = iClose(_Symbol, tf, 0);
   double close26 = iClose(_Symbol, tf, 26);

   // Conditions BUY
   bool above   = close1 > cloudTop;
   bool tkCross = tenkan[1] > kijun[1];           // golden
   bool chikou  = close0 > close26;
   bool futGreen= cloudA_fut > cloudB_fut;
   bool aboveKj = close1 > kijun[1];
   if(above && tkCross && chikou && futGreen && aboveKj) return 1;

   // Conditions SELL
   bool below   = close1 < cloudBot;
   bool tkDeath = tenkan[1] < kijun[1];
   bool chikouD = close0 < close26;
   bool futRed  = cloudA_fut < cloudB_fut;
   bool belowKj = close1 < kijun[1];
   if(below && tkDeath && chikouD && futRed && belowKj) return -1;

   return 0;
}

// 6 MA sur TF1 : pente uniforme dans le sens du bias
int MAStackBias(int dir)
{
   for(int i=0; i<6; i++)
   {
      double now  = MABuf(i, 1);
      double past = MABuf(i, 1 + InpMASlopeBars);
      if(dir > 0 && !(now > past)) return 0;
      if(dir < 0 && !(now < past)) return 0;
   }
   // Stack ordonné : EMA5 > EMA8 > EMA21 > EMA55 > SMA100 > SMA200 (pour buy)
   for(int i=0; i<5; i++)
   {
      if(dir > 0 && !(MABuf(i, 1) > MABuf(i+1, 1))) return 0;
      if(dir < 0 && !(MABuf(i, 1) < MABuf(i+1, 1))) return 0;
   }
   return dir;
}

//══════════════════════════════════════════════════════════════════
// RANGE detection (sur TF1)
//══════════════════════════════════════════════════════════════════
bool IsRange()
{
   double atr = bufATR_TF1[1];
   if(atr <= 0) return false;

   double kijunSpan = MathAbs(bufKijun1[1] - bufKijun1[5]);
   bool kijunFlat   = kijunSpan < atr * InpKijunFlatPctATR;

   double tkDist    = MathAbs(bufTenkan1[1] - bufKijun1[1]);
   bool stuck       = tkDist < atr * InpTKDistPctATR;

   double cloudThick= MathAbs(bufSpanA1[26] - bufSpanB1[26]);
   bool thinCloud   = cloudThick < atr * InpThinCloudPctATR;

   // Prix qui évolue dans/autour du nuage sur les 10 dernières bougies TF1
   double cloudTop = MathMax(bufSpanA1[26], bufSpanB1[26]);
   double cloudBot = MathMin(bufSpanA1[26], bufSpanB1[26]);
   int    insideOrAround = 0;
   for(int i=1; i<=10; i++)
   {
      double c = iClose(_Symbol, InpBiasTF1, i);
      if(c >= cloudBot - atr*0.5 && c <= cloudTop + atr*0.5) insideOrAround++;
   }
   bool aroundCloud = insideOrAround >= 7;

   int score = (kijunFlat?1:0) + (stuck?1:0) + (thinCloud?1:0) + (aroundCloud?1:0);
   return score >= 3;
}

//══════════════════════════════════════════════════════════════════
// TRIGGER : OTE + FVG + Breaker + Engulfing → confluence
//══════════════════════════════════════════════════════════════════
int GetTrigger(int bias)
{
   int votes = 0;
   if(InpUseOTE       && OTETrigger(bias))       votes++;
   if(InpUseFVG       && FVGRetestTrigger(bias)) votes++;
   if(InpUseBreaker   && BreakerTrigger(bias))   votes++;
   if(InpUseEngulfing && EngulfingTrigger(bias)) votes++;

   if(votes >= InpMinConfluence) return bias;
   return 0;
}

//-------------------------------------------------------------------
// OTE : Fibonacci 62-79% du dernier swing M1
//-------------------------------------------------------------------
bool FindSwings(int lookback, double &swingHigh, int &shIdx,
                double &swingLow,  int &slIdx)
{
   swingHigh = -DBL_MAX; swingLow = DBL_MAX;
   shIdx = -1; slIdx = -1;
   int w = InpFractalWidth;
   for(int i = w+1; i <= lookback; i++)
   {
      double h = iHigh(_Symbol, PERIOD_M1, i);
      double l = iLow (_Symbol, PERIOD_M1, i);
      bool isHigh = true, isLow = true;
      for(int k = 1; k <= w && (isHigh || isLow); k++)
      {
         if(h <= iHigh(_Symbol, PERIOD_M1, i-k) || h <= iHigh(_Symbol, PERIOD_M1, i+k)) isHigh = false;
         if(l >= iLow (_Symbol, PERIOD_M1, i-k) || l >= iLow (_Symbol, PERIOD_M1, i+k)) isLow  = false;
      }
      if(isHigh && h > swingHigh) { swingHigh = h; shIdx = i; }
      if(isLow  && l < swingLow ) { swingLow  = l; slIdx = i; }
   }
   return (shIdx > 0 && slIdx > 0);
}

bool OTETrigger(int bias)
{
   double sh, sl; int shi, sli;
   if(!FindSwings(InpSwingLookback, sh, shi, sl, sli)) return false;
   double range = sh - sl;
   if(range <= 0) return false;

   double close1 = iClose(_Symbol, PERIOD_M1, 1);
   if(bias > 0 && shi < sli) // dernière leg = haussière (low avant high)
   {
      double oteHi = sh - range * InpOTE_Low;
      double oteLo = sh - range * InpOTE_High;
      return (close1 >= oteLo && close1 <= oteHi);
   }
   if(bias < 0 && shi > sli) // dernière leg = baissière
   {
      double oteLo = sl + range * InpOTE_Low;
      double oteHi = sl + range * InpOTE_High;
      return (close1 >= oteLo && close1 <= oteHi);
   }
   return false;
}

//-------------------------------------------------------------------
// FVG retest : 3-bar imbalance, retest de la zone
//-------------------------------------------------------------------
bool FVGRetestTrigger(int bias)
{
   double close1 = iClose(_Symbol, PERIOD_M1, 1);
   double low1   = iLow  (_Symbol, PERIOD_M1, 1);
   double high1  = iHigh (_Symbol, PERIOD_M1, 1);

   // Scanne du plus récent vers le passé : FVG à pivot p si gap entre p-1 et p+1
   for(int p = 3; p <= InpFVG_Lookback; p++)
   {
      double hPrev = iHigh(_Symbol, PERIOD_M1, p+1);
      double lPrev = iLow (_Symbol, PERIOD_M1, p+1);
      double hNext = iHigh(_Symbol, PERIOD_M1, p-1);
      double lNext = iLow (_Symbol, PERIOD_M1, p-1);

      if(bias > 0)
      {
         // Bullish FVG : low de la bougie récente > high de la bougie ancienne
         if(lNext > hPrev)
         {
            double gapTop = lNext;
            double gapBot = hPrev;
            if(gapTop - gapBot < InpFVG_MinSizeUSD) continue;
            // Vérifie que la zone n'a pas été "fermée" entre p-1 et la bougie 1
            bool stillOpen = true;
            for(int k = p-2; k >= 2; k--)
               if(iLow(_Symbol, PERIOD_M1, k) <= gapBot) { stillOpen = false; break; }
            if(!stillOpen) continue;
            // Retest : la bougie 1 entre dans la zone et clôture au-dessus du bas
            if(low1 <= gapTop && close1 > gapBot && close1 > iOpen(_Symbol, PERIOD_M1, 1))
               return true;
         }
      }
      else
      {
         if(hNext < lPrev)
         {
            double gapTop = lPrev;
            double gapBot = hNext;
            if(gapTop - gapBot < InpFVG_MinSizeUSD) continue;
            bool stillOpen = true;
            for(int k = p-2; k >= 2; k--)
               if(iHigh(_Symbol, PERIOD_M1, k) >= gapTop) { stillOpen = false; break; }
            if(!stillOpen) continue;
            if(high1 >= gapBot && close1 < gapTop && close1 < iOpen(_Symbol, PERIOD_M1, 1))
               return true;
         }
      }
   }
   return false;
}

//-------------------------------------------------------------------
// Breaker block : structure cassée puis retestée
//   Simplification : on détecte la cassure du dernier swing opposé puis
//   retest de la zone du swing comme nouveau support/résistance.
//-------------------------------------------------------------------
bool BreakerTrigger(int bias)
{
   double sh, sl; int shi, sli;
   if(!FindSwings(InpSwingLookback, sh, shi, sl, sli)) return false;
   double close1 = iClose(_Symbol, PERIOD_M1, 1);
   double low1   = iLow  (_Symbol, PERIOD_M1, 1);
   double high1  = iHigh (_Symbol, PERIOD_M1, 1);
   double atr    = bufATR_M1[1];
   if(atr <= 0) return false;
   double tol = atr * 0.5;

   if(bias > 0)
   {
      // On veut : swing high cassé à la hausse (close récent > sh), puis retest depuis le haut
      bool broken = false;
      for(int k = 1; k < shi; k++)
         if(iClose(_Symbol, PERIOD_M1, k) > sh) { broken = true; break; }
      if(!broken) return false;
      // Retest : la bougie 1 touche la zone [sh-tol, sh+tol] et close > sh
      if(low1 <= sh + tol && close1 > sh) return true;
   }
   else
   {
      bool broken = false;
      for(int k = 1; k < sli; k++)
         if(iClose(_Symbol, PERIOD_M1, k) < sl) { broken = true; break; }
      if(!broken) return false;
      if(high1 >= sl - tol && close1 < sl) return true;
   }
   return false;
}

//-------------------------------------------------------------------
// Engulfing à la clôture de la bougie 1
//-------------------------------------------------------------------
bool EngulfingTrigger(int bias)
{
   double o1 = iOpen (_Symbol, PERIOD_M1, 1);
   double c1 = iClose(_Symbol, PERIOD_M1, 1);
   double o2 = iOpen (_Symbol, PERIOD_M1, 2);
   double c2 = iClose(_Symbol, PERIOD_M1, 2);

   if(bias > 0)
      return (c1 > o1) && (c2 < o2) && (c1 >= o2) && (o1 <= c2);
   else
      return (c1 < o1) && (c2 > o2) && (c1 <= o2) && (o1 >= c2);
}

//══════════════════════════════════════════════════════════════════
// EXÉCUTION : stop order au break de la bougie signal
//══════════════════════════════════════════════════════════════════
void PlaceStopOrder(int dir)
{
   double high1 = iHigh(_Symbol, PERIOD_M1, 1);
   double low1  = iLow (_Symbol, PERIOD_M1, 1);
   int    dig   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = _Point;
   double offset= InpStopOrderOffsetPt * point;

   datetime expiry = TimeCurrent() + InpPendingExpireBars * PeriodSeconds(PERIOD_M1);

   double triggerPrice, tp;
   if(dir > 0)
   {
      triggerPrice = NormalizeDouble(high1 + offset, dig);
      tp           = NormalizeDouble(triggerPrice + InpTPPriceUSD, dig);
      if(Trade.BuyStop(InpFixedLot, triggerPrice, _Symbol, 0.0, tp, ORDER_TIME_SPECIFIED, expiry, InpComment))
      {
         g_pendingTicket = Trade.ResultOrder();
         g_pendingExpire = expiry;
         g_pendingDir    = 1;
         if(InpVerboseLog) PrintFormat("⤴ BuyStop @%.2f TP=%.2f expire=%s",
                                       triggerPrice, tp, TimeToString(expiry, TIME_MINUTES));
      }
      else PrintFormat("✗ BuyStop rejected: %d %s", Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
   }
   else
   {
      triggerPrice = NormalizeDouble(low1 - offset, dig);
      tp           = NormalizeDouble(triggerPrice - InpTPPriceUSD, dig);
      if(Trade.SellStop(InpFixedLot, triggerPrice, _Symbol, 0.0, tp, ORDER_TIME_SPECIFIED, expiry, InpComment))
      {
         g_pendingTicket = Trade.ResultOrder();
         g_pendingExpire = expiry;
         g_pendingDir    = -1;
         if(InpVerboseLog) PrintFormat("⤵ SellStop @%.2f TP=%.2f expire=%s",
                                       triggerPrice, tp, TimeToString(expiry, TIME_MINUTES));
      }
      else PrintFormat("✗ SellStop rejected: %d %s", Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
   }
}

void ManagePendingOrder()
{
   if(g_pendingTicket == 0) return;
   if(!OrderInfo.Select(g_pendingTicket))
   {
      // ordre exécuté ou supprimé → reset
      g_pendingTicket = 0; g_pendingDir = 0; g_pendingExpire = 0;
      return;
   }
   if(TimeCurrent() >= g_pendingExpire)
   {
      Trade.OrderDelete(g_pendingTicket);
      g_pendingTicket = 0; g_pendingDir = 0; g_pendingExpire = 0;
      if(InpVerboseLog) Print("⌛ Pending order expiré, supprimé");
   }
}

//══════════════════════════════════════════════════════════════════
// MANAGE OPEN POSITIONS : BE après 30s à +2 USD, time-stop 5 min
//══════════════════════════════════════════════════════════════════
void ManageOpenPositions()
{
   int    dig   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   long   stops = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stops * _Point;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!PositionInfo.SelectByIndex(i)) continue;
      if(PositionInfo.Symbol() != _Symbol) continue;
      if(PositionInfo.Magic()  != InpMagic) continue;

      ulong  tk    = PositionInfo.Ticket();
      double opn   = PositionInfo.PriceOpen();
      double sl    = PositionInfo.StopLoss();
      double tp    = PositionInfo.TakeProfit();
      datetime ot  = (datetime)PositionInfo.Time();
      double bid   = SymbolInfoObj.Bid();
      double ask   = SymbolInfoObj.Ask();
      ENUM_POSITION_TYPE pt = PositionInfo.PositionType();
      bool   isBuy = (pt == POSITION_TYPE_BUY);
      double price = isBuy ? bid : ask;
      double gainUSD = isBuy ? (price - opn) : (opn - price);
      int    ageSec  = (int)(TimeCurrent() - ot);

      //─── Time-stop 5 min ─────────────────────────────────────────
      if(ageSec >= InpMaxTradeMinutes * 60)
      {
         Trade.PositionClose(tk);
         if(InpVerboseLog) PrintFormat("⏱ Time-stop close (%ds)", ageSec);
         continue;
      }

      //─── BE après délai + gain seuil ─────────────────────────────
      if(ageSec >= InpBEArmDelaySec && gainUSD >= InpBETriggerUSD)
      {
         double beSL = isBuy ? NormalizeDouble(opn + InpBEOffsetUSD, dig)
                             : NormalizeDouble(opn - InpBEOffsetUSD, dig);
         bool improves = isBuy ? (sl < beSL - _Point) : (sl > beSL + _Point || sl == 0);
         if(improves && MathAbs(price - beSL) > minDist)
         {
            if(Trade.PositionModify(tk, beSL, tp))
               if(InpVerboseLog) PrintFormat("➤ BE armé @%.2f (gain=%.2f USD)", beSL, gainUSD);
         }
      }
   }
}

//══════════════════════════════════════════════════════════════════
// CLOSE ALL (news, force-close, daily cap)
//══════════════════════════════════════════════════════════════════
void CloseAllPositionsAndOrders()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!PositionInfo.SelectByIndex(i)) continue;
      if(PositionInfo.Symbol() != _Symbol || PositionInfo.Magic() != InpMagic) continue;
      Trade.PositionClose(PositionInfo.Ticket());
   }
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      if(!OrderInfo.SelectByIndex(i)) continue;
      if(OrderInfo.Symbol() != _Symbol || OrderInfo.Magic() != InpMagic) continue;
      Trade.OrderDelete(OrderInfo.Ticket());
   }
   g_pendingTicket = 0;
}

bool HasOpenPositionOrOrder()
{
   for(int i=0; i<PositionsTotal(); i++)
      if(PositionInfo.SelectByIndex(i) &&
         PositionInfo.Symbol()==_Symbol &&
         PositionInfo.Magic()==InpMagic) return true;
   for(int i=0; i<OrdersTotal(); i++)
      if(OrderInfo.SelectByIndex(i) &&
         OrderInfo.Symbol()==_Symbol &&
         OrderInfo.Magic()==InpMagic) return true;
   return false;
}

//══════════════════════════════════════════════════════════════════
// TRADE TRANSACTION : suivi P&L, comptage trades, loss streak
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

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);

   if(entry == DEAL_ENTRY_IN)
   {
      g_dayTradesCount++;
      if(InpVerboseLog) PrintFormat("📈 Trade #%d ouvert", g_dayTradesCount);
   }
   else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
   {
      double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                    + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                    + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      g_dayRealizedUSD += profit;
      g_lastClosedPnL   = profit;

      if(profit < 0)
      {
         g_consecLosses++;
         if(InpVerboseLog) PrintFormat("✗ Perte %.2f USD | streak=%d", profit, g_consecLosses);
         if(g_consecLosses >= InpMaxConsecLoss) ArmLockout("loss-streak");
      }
      else if(profit > 0)
      {
         g_consecLosses = 0;
         if(InpVerboseLog) PrintFormat("✓ Gain %.2f USD", profit);
      }
   }
}

//══════════════════════════════════════════════════════════════════
// DAILY ROLL
//══════════════════════════════════════════════════════════════════
void RollDailyIfNeeded()
{
   MqlDateTime now; TimeToStruct(TimeCurrent(), now);
   MqlDateTime anc; TimeToStruct(g_dayAnchorDate, anc);
   if(g_dayAnchorDate == 0 || now.day != anc.day || now.mon != anc.mon || now.year != anc.year)
      ResetDailyAnchor();
}

void ResetDailyAnchor()
{
   g_dayAnchorDate  = TimeCurrent();
   g_dayAnchorEq    = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayRealizedUSD = 0;
   g_dayTradesCount = 0;
   g_consecLosses   = 0;
   if(InpVerboseLog) PrintFormat("🔄 Day reset @ eq=%.2f", g_dayAnchorEq);
}

//══════════════════════════════════════════════════════════════════
// DASHBOARD
//══════════════════════════════════════════════════════════════════
void OnTimer()
{
   if(ArraySize(bufATR_M1) < 2) return;
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   string biasS = "—";
   int b = 0;
   if(ArraySize(bufKijun1) > 30 && ArraySize(bufKijun2) > 30) b = GetBias();
   if(b > 0) biasS = "↑ LONG";
   else if(b < 0) biasS = "↓ SHORT";
   string state = "ACTIF";
   if(TimeCurrent() < g_lockoutUntil) state = "LOCKOUT";
   else if(g_newsActiveCached)         state = "NEWS";
   else if(!SessionOK())               state = "HORS SESSION";
   else if(IsAfterForceCloseHour())    state = "FORCE-CLOSE";

   Comment(
      "ScalpBTC Confluence v1 — ", _Symbol, "\n",
      "─────────────────────────────────\n",
      "État        : ", state, "\n",
      "Biais (TF1+TF2) : ", biasS, "\n",
      "ATR M1      : ", DoubleToString(bufATR_M1[1], 2), " USD\n",
      "─────────────────────────────────\n",
      "Trades jour : ", IntegerToString(g_dayTradesCount), "/", IntegerToString(InpDailyMaxTrades), "\n",
      "P&L jour    : ", DoubleToString(g_dayRealizedUSD, 2), " USD",
         " (cap -", DoubleToString(InpDailyLossCapUSD, 2), ")\n",
      "Pertes consec: ", IntegerToString(g_consecLosses), "/", IntegerToString(InpMaxConsecLoss), "\n",
      "Equity      : ", DoubleToString(eq, 2), "\n",
      "Lockout fin : ", (g_lockoutUntil > TimeCurrent() ?
                         TimeToString(g_lockoutUntil, TIME_DATE|TIME_MINUTES) : "—")
   );
}
