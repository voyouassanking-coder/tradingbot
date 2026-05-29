//+==================================================================+
//|   EA_MAStack_Kijun_M5.mq5                                         |
//|   Scalping M5 BTCUSD — strategie PURE : 6 MA alignees + Kijun26   |
//|                                                                   |
//|   ┌─────────────────────────────────────────────────────────┐   |
//|   │  AVERTISSEMENT — RESULTAT DE BACKTEST                     │   |
//|   │  Teste sur ~11 mois de M5 BTCUSDm (juin25-mai26) :        │   |
//|   │  cette strategie PURE (6 MA + Kijun) en M5 est PERDANTE   │   |
//|   │  sur toutes les variantes testees (profit factor 0.7-0.9, │   |
//|   │  < 1.0). Resultat stable IS/OOS/walk-forward.             │   |
//|   │  => NE PAS UTILISER EN REEL sans edge supplementaire.     │   |
//|   │  Fournit a but pedagogique / base d'experimentation.      │   |
//|   │  La piste qui fonctionne : multi-TF D1+H4+H1 + stack 6 MA │   |
//|   │  sur H1 (voir SOSFinancial_PRO_FIXED v1.2).               │   |
//|   └─────────────────────────────────────────────────────────┘   |
//|                                                                   |
//|   Logique :                                                       |
//|     Stack haussier : EMA5>EMA8>EMA21>SMA55>SMA100>SMA200          |
//|     + prix > Kijun26 > SMA200                                     |
//|     (inverse pour le stack baissier)                              |
//|     Entree : a l'apparition d'un nouvel alignement OU pullback    |
//|     Sortie : SL/TP ATR, ou perte de l'alignement                 |
//+==================================================================+
#property copyright "MAStack Kijun M5"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        Trade;
CPositionInfo PositionInfo;

//─── Money management ─────────────────────────────────────────────
input group "=== RISQUE ==="
input bool   InpFixedLot      = true;    // true = lot fixe, false = % risque
input double InpLot           = 0.01;    // Lot fixe
input double InpRiskPct       = 1.0;     // % risque si InpFixedLot=false
input int    InpATRPeriod     = 14;
input double InpATR_SL_Mult   = 1.5;     // SL = ATR x mult
input double InpRR            = 2.0;     // TP = SL x RR

//─── Moyennes mobiles (les 6 + Kijun) ─────────────────────────────
input group "=== STACK 6 MA + KIJUN ==="
input int    InpEMA5          = 5;
input int    InpEMA8          = 8;
input int    InpEMA21         = 21;
input int    InpSMA55         = 55;
input int    InpSMA100        = 100;
input int    InpSMA200        = 200;
input int    InpKijun         = 26;
input bool   InpUseKijun      = true;    // exiger confirmation Kijun

//─── Entree / sortie ──────────────────────────────────────────────
input group "=== ENTREE / SORTIE ==="
enum ENUM_ENTRY { ENTRY_FRESH=0, ENTRY_PULLBACK=1, ENTRY_ALWAYS=2 };
input ENUM_ENTRY InpEntry      = ENTRY_FRESH;     // Type de declencheur
input double     InpPullbackATR= 0.5;             // Tolerance pullback (x ATR)
enum ENUM_EXIT  { EXIT_SLTP=0, EXIT_STACK_BREAK=1, EXIT_BOTH=2 };
input ENUM_EXIT  InpExit       = EXIT_SLTP;       // Mode de sortie
input int        InpTimeStopBars = 0;             // Time-stop en bougies (0=off)
input int        InpCooldownBars = 3;             // Attente apres sortie

//─── Filtres ──────────────────────────────────────────────────────
input group "=== FILTRES ==="
input bool   InpUseSession    = false;
input int    InpSessStart     = 8;
input int    InpSessEnd       = 21;
input double InpMaxSpreadUSD  = 30.0;

input group "=== DIVERS ==="
input long   InpMagic         = 770005;
input int    InpDeviation     = 50;
input bool   InpVerbose       = true;

//─── Handles ──────────────────────────────────────────────────────
int hEMA5,hEMA8,hEMA21,hSMA55,hSMA100,hSMA200,hATR;
double bE5[],bE8[],bE21[],bS55[],bS100[],bS200[],bATR[];
datetime g_lastBar=0;
int      g_lastExitBarIndex=-100000;
int      g_barCounter=0;

//──────────────────────────────────────────────────────────────────
int OnInit()
{
   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints(InpDeviation);
   Trade.SetTypeFillingBySymbol(_Symbol);

   hEMA5  = iMA(_Symbol, PERIOD_M5, InpEMA5,  0, MODE_EMA, PRICE_CLOSE);
   hEMA8  = iMA(_Symbol, PERIOD_M5, InpEMA8,  0, MODE_EMA, PRICE_CLOSE);
   hEMA21 = iMA(_Symbol, PERIOD_M5, InpEMA21, 0, MODE_EMA, PRICE_CLOSE);
   hSMA55 = iMA(_Symbol, PERIOD_M5, InpSMA55, 0, MODE_SMA, PRICE_CLOSE);
   hSMA100= iMA(_Symbol, PERIOD_M5, InpSMA100,0, MODE_SMA, PRICE_CLOSE);
   hSMA200= iMA(_Symbol, PERIOD_M5, InpSMA200,0, MODE_SMA, PRICE_CLOSE);
   hATR   = iATR(_Symbol, PERIOD_M5, InpATRPeriod);

   if(hEMA5==INVALID_HANDLE||hEMA8==INVALID_HANDLE||hEMA21==INVALID_HANDLE||
      hSMA55==INVALID_HANDLE||hSMA100==INVALID_HANDLE||hSMA200==INVALID_HANDLE||
      hATR==INVALID_HANDLE)
   { Print("❌ Erreur handles"); return INIT_FAILED; }

   ArraySetAsSeries(bE5,true);  ArraySetAsSeries(bE8,true);  ArraySetAsSeries(bE21,true);
   ArraySetAsSeries(bS55,true); ArraySetAsSeries(bS100,true);ArraySetAsSeries(bS200,true);
   ArraySetAsSeries(bATR,true);

   EventSetTimer(10);
   Print("✅ MAStack Kijun M5 demarre | ATTENTION: strategie perdante en backtest pur, voir en-tete.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int r)
{
   IndicatorRelease(hEMA5); IndicatorRelease(hEMA8); IndicatorRelease(hEMA21);
   IndicatorRelease(hSMA55);IndicatorRelease(hSMA100);IndicatorRelease(hSMA200);
   IndicatorRelease(hATR);
   EventKillTimer(); Comment("");
}

//──────────────────────────────────────────────────────────────────
double Kijun(int shift)
{
   double hi[],lo[]; ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true);
   if(CopyHigh(_Symbol,PERIOD_M5,shift,InpKijun,hi)<InpKijun) return EMPTY_VALUE;
   if(CopyLow (_Symbol,PERIOD_M5,shift,InpKijun,lo)<InpKijun) return EMPTY_VALUE;
   return (hi[ArrayMaximum(hi,0,InpKijun)] + lo[ArrayMinimum(lo,0,InpKijun)])/2.0;
}

// Direction du stack a la bougie 'shift' : +1 / -1 / 0
int StackDir(int shift)
{
   double e5=bE5[shift], e8=bE8[shift], e21=bE21[shift];
   double s55=bS55[shift], s100=bS100[shift], s200=bS200[shift];
   double px=iClose(_Symbol,PERIOD_M5,shift);
   double kij=InpUseKijun ? Kijun(shift) : 0;
   if(InpUseKijun && kij==EMPTY_VALUE) return 0;

   bool up = e5>e8 && e8>e21 && e21>s55 && s55>s100 && s100>s200;
   bool dn = e5<e8 && e8<e21 && e21<s55 && s55<s100 && s100<s200;
   if(InpUseKijun){ up = up && px>kij && kij>s200; dn = dn && px<kij && kij<s200; }
   if(up) return 1;
   if(dn) return -1;
   return 0;
}

//──────────────────────────────────────────────────────────────────
bool LoadBuffers()
{
   if(CopyBuffer(hEMA5,0,0,5,bE5)<4) return false;
   if(CopyBuffer(hEMA8,0,0,5,bE8)<4) return false;
   if(CopyBuffer(hEMA21,0,0,5,bE21)<4) return false;
   if(CopyBuffer(hSMA55,0,0,5,bS55)<4) return false;
   if(CopyBuffer(hSMA100,0,0,5,bS100)<4) return false;
   if(CopyBuffer(hSMA200,0,0,5,bS200)<4) return false;
   if(CopyBuffer(hATR,0,0,5,bATR)<4) return false;
   return true;
}

int CountPos()
{
   int n=0;
   for(int i=0;i<PositionsTotal();i++)
      if(PositionInfo.SelectByIndex(i)&&PositionInfo.Symbol()==_Symbol&&PositionInfo.Magic()==InpMagic) n++;
   return n;
}

double CalcLot(double slDist)
{
   if(InpFixedLot) return InpLot;
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double risk=bal*InpRiskPct/100.0;
   double tickSz=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickVL=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(tickSz<=0||tickVL<=0||step<=0) return mn;
   double lossPerLot=(slDist/tickSz)*tickVL;
   if(lossPerLot<=0) return mn;
   double lot=MathFloor(risk/lossPerLot/step)*step;
   return MathMax(mn,MathMin(mx,lot));
}

//──────────────────────────────────────────────────────────────────
void OnTick()
{
   datetime cur=iTime(_Symbol,PERIOD_M5,0);
   if(cur==g_lastBar) return;       // 1 evaluation par bougie M5
   g_lastBar=cur;
   g_barCounter++;

   if(!LoadBuffers()) return;

   // --- gestion position (sortie sur perte d'alignement) ---
   if(CountPos()>0)
   {
      ManageExits();
      return; // une position a la fois
   }

   // --- filtres ---
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(InpUseSession && !(dt.hour>=InpSessStart && dt.hour<InpSessEnd)) { Dash(0); return; }
   double spread=SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(spread>InpMaxSpreadUSD) { Dash(0); return; }
   if(g_barCounter - g_lastExitBarIndex < InpCooldownBars) { Dash(0); return; }

   int dir=StackDir(1);     // barre fermee
   Dash(dir);
   if(dir==0) return;

   // --- declencheur ---
   bool take=false;
   if(InpEntry==ENTRY_ALWAYS) take=true;
   else if(InpEntry==ENTRY_FRESH) take = (StackDir(2)!=dir);   // nouvel alignement
   else if(InpEntry==ENTRY_PULLBACK)
   {
      double atr=bATR[1];
      double low1=iLow(_Symbol,PERIOD_M5,1), high1=iHigh(_Symbol,PERIOD_M5,1);
      double cl1=iClose(_Symbol,PERIOD_M5,1);
      if(dir>0) take = (low1 <= bE8[1]+atr*InpPullbackATR) && (cl1>bE8[1]);
      else      take = (high1>= bE8[1]-atr*InpPullbackATR) && (cl1<bE8[1]);
   }
   if(!take) return;

   OpenTrade(dir);
}

//──────────────────────────────────────────────────────────────────
void OpenTrade(int dir)
{
   double atr=bATR[1];
   double slDist=atr*InpATR_SL_Mult;
   if(slDist<10) return;
   double lot=CalcLot(slDist);
   int dig=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   long stops=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minD=stops*_Point;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

   if(dir>0)
   {
      double sl=NormalizeDouble(ask-slDist,dig);
      double tp=NormalizeDouble(ask+slDist*InpRR,dig);
      if(ask-sl<minD||tp-ask<minD) return;
      if(Trade.Buy(lot,_Symbol,ask,sl,tp,"MAStackM5") && InpVerbose)
         PrintFormat("▲ BUY %.2f @%.2f SL=%.2f TP=%.2f",lot,ask,sl,tp);
   }
   else
   {
      double sl=NormalizeDouble(bid+slDist,dig);
      double tp=NormalizeDouble(bid-slDist*InpRR,dig);
      if(sl-bid<minD||bid-tp<minD) return;
      if(Trade.Sell(lot,_Symbol,bid,sl,tp,"MAStackM5") && InpVerbose)
         PrintFormat("▼ SELL %.2f @%.2f SL=%.2f TP=%.2f",lot,bid,sl,tp);
   }
}

//──────────────────────────────────────────────────────────────────
void ManageExits()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!PositionInfo.SelectByIndex(i)) continue;
      if(PositionInfo.Symbol()!=_Symbol||PositionInfo.Magic()!=InpMagic) continue;
      bool isBuy=(PositionInfo.PositionType()==POSITION_TYPE_BUY);
      int dir=isBuy?1:-1;

      bool doClose=false;
      // perte d'alignement
      if(InpExit==EXIT_STACK_BREAK||InpExit==EXIT_BOTH)
         if(StackDir(1)!=dir) doClose=true;
      // time stop
      if(!doClose && InpTimeStopBars>0)
      {
         int bars=(int)((TimeCurrent()-(datetime)PositionInfo.Time())/PeriodSeconds(PERIOD_M5));
         if(bars>=InpTimeStopBars) doClose=true;
      }
      // (le SL/TP fixe est gere par le broker automatiquement)

      if(doClose)
      {
         Trade.PositionClose(PositionInfo.Ticket());
         g_lastExitBarIndex=g_barCounter;
         if(InpVerbose) Print("✓ Sortie (alignement perdu / time-stop)");
      }
   }
}

//──────────────────────────────────────────────────────────────────
void OnTimer(){ if(LoadBuffers()) Dash(StackDir(1)); }

void Dash(int dir)
{
   string s = dir>0?"↑ STACK HAUSSIER":(dir<0?"↓ STACK BAISSIER":"— non aligne");
   Comment(
      "MAStack Kijun M5 — ", _Symbol, "\n",
      "─────────────────────────────\n",
      "⚠ Strategie perdante en backtest pur (voir code)\n",
      "Etat stack : ", s, "\n",
      "Positions  : ", IntegerToString(CountPos()), "\n",
      "Entry=", EnumToString(InpEntry), " Exit=", EnumToString(InpExit), "\n",
      "RR=", DoubleToString(InpRR,1), " SLx", DoubleToString(InpATR_SL_Mult,1)
   );
}
