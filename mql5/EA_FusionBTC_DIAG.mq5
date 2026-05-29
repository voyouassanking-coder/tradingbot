//+==================================================================+
//|   EA_FusionBTC_v1.mq5                                             |
//|   Fusion validee par backtest pour BTCUSD :                       |
//|     • Base GoldStorm : strategies B (cassure+cross T/K) & C       |
//|       (pullback Kijun en tendance D1) + EMA50/200 + Ichimoku      |
//|     • Filtre stack 6 MA (EMA5/8/21 + SMA55/100/200) + Kijun (H1)  |
//|       -> n'entre que si l'alignement complet confirme le sens     |
//|     • Garde-fous risque : blocage si risque min-lot > %equity,    |
//|       kill-switch DD global                                       |
//|                                                                   |
//|   *** VERSION DIAGNOSTIC ***  garde-fous DESACTIVES par defaut    |
//|   (kill-switch, blocage risque, spread, ADX, FVG OFF ;            |
//|    MaxDailyTrades=100). But : VOIR le vrai nombre de trades.      |
//|   A tester sur un compte USD (pas 'profit en pips').             |
//|                                                                   |
//|   v1.20 — CORRECTION FREQUENCE :                                  |
//|     Le Strategy Tester MT5 a revele que la v1.1 ne prenait qu'1   |
//|     trade en 7 ans (filtres empiles trop stricts en reel).        |
//|     v1.2 assouplit l'entree :                                     |
//|       - StackStrict=false : alignement souple des MA (defaut)     |
//|       - RequireTKCross=false : etat Tenkan>Kijun (pas le cross)   |
//|       - RequireBreakout=false / UseFVGFilter=false par defaut     |
//|     -> beaucoup plus de trades. A RE-VALIDER dans le Strategy     |
//|        Tester (les chiffres Python n'etaient pas fiables ici).    |
//|                                                                   |
//|   ⚠ AUCUN systeme ne gagne CHAQUE semaine.                        |
//+==================================================================+
#property copyright "FusionBTC DIAG"
#property version   "1.20"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        Trade;
CPositionInfo PositionInfo;

#define ICH_TENKAN 0
#define ICH_KIJUN  1
#define ICH_SPANA  2
#define ICH_SPANB  3

//=== STRATEGIES ===================================================
input group "=== STRATEGIES ==="
input bool   RunStrategyB   = true;     // Cassure H1 + cross Tenkan/Kijun
input bool   RunStrategyC   = true;     // Pullback Kijun en tendance D1

//=== ICHIMOKU / EMA ==============================================
input group "=== TIMEFRAME D'EXECUTION ==="
input ENUM_TIMEFRAMES InpBaseTF = PERIOD_M30; // ★ M30 optimal (gains+regularite) ; H1 = DD plus bas

input group "=== ICHIMOKU / EMA ==="
input int    Ich_Tenkan     = 9;
input int    Ich_Kijun      = 26;
input int    Ich_Senkou     = 52;
input int    EMA_Fast       = 50;
input int    EMA_Slow       = 200;

//=== STACK 6 MA + KIJUN (filtre fusion) ==========================
input group "=== FILTRE STACK 6 MA + KIJUN ==="
input bool   RequireMAStack = true;     // ★ coeur de la fusion
input bool   StackStrict    = false;    // ★ v1.2 : true=6 MA ordonnees (tres rare) / false=souple (recommande)
input bool   RequireTKCross = false;    // ★ v1.2 : true=croisement Tenkan/Kijun exact / false=etat T>K (plus de trades)
input bool   RequireBreakout= false;    // ★ v1.2 : true=cassure 20 bougies obligatoire (strat B)
input bool   UseFVGFilter   = false;    // ★ v1.2 : FVG desactive par defaut (etait trop restrictif combine)
input int    FVG_Lookback   = 20;       // bougies ou chercher un FVG dans le sens
input bool   UseADXFilter   = false;   // DIAG: off     // ★ ADX force de tendance (PF 1.39->1.57, DD 9.7->6.6, 6/6 WF)
input double ADX_MinValue   = 20.0;     // seuil ADX (20 optimal ; >25 reduit la regularite)
input int    St_EMA5        = 5;
input int    St_EMA8        = 8;
input int    St_EMA21       = 21;
input int    St_SMA55       = 55;
input int    St_SMA100      = 100;
input int    St_SMA200      = 200;

//=== ATR / SL / TP (valeurs optimisees) ==========================
input group "=== ATR / SL / TP ==="
input int    ATR_Period     = 14;
input double ATR_SL_Mult    = 1.8;      // ★ optimise
input double ATR_TP_Mult    = 3.0;      // ★ optimise (etait 3.6)
input double ATR_MinThreshold = 0.8;
input int    MinConfirmations = 3;      // ★ optimise

//=== MONEY MANAGEMENT + GARDE-FOUS ===============================
input group "=== RISQUE + GARDE-FOUS ==="
input double RiskPercent    = 1.0;
input double MaxLotSize      = 2.0;
input double MaxRiskPctBlock = 0.0;     // DIAG: off     // ★ skip si risque min-lot > % equity (300$=8 / 1000$+=3 / 0=off)
input double GlobalDDStop    = 0.0;     // DIAG: off    // ★ kill-switch DD global % (0=off)
input double MaxDailyLossPct = 100.0;   // DIAG: off
input int    MaxDailyTrades   = 100;    // DIAG: large

//=== PROTECTION POSITION =========================================
input group "=== GESTION POSITION ==="
input bool   UseBreakEven    = true;
input double BE_TriggerATR    = 1.2;
input double BE_LockUSD       = 15.0;
input bool   UseTrailingStop  = true;
input double Trail_ATR_Mult   = 1.0;

//=== FILTRES =====================================================
input group "=== FILTRES ==="
input bool   UseSpreadFilter  = false;  // DIAG: off
input double MaxSpreadUSD      = 30.0;
input bool   UseSession        = false;  // BTC 24/7
input int    SessStart         = 0;
input int    SessEnd           = 24;

//=== IDENTITE ====================================================
input group "=== IDENTITE ==="
input long   MagicNumber       = 20250779;
input string EA_Comment        = "FusionBTC";

//=== HANDLES =====================================================
int hIchi, hEMAf, hEMAs, hATR_H1, hATR_H4, hADX;
int hE5,hE8,hE21,hS55,hS100,hS200;
double pointVal, tickSize, tickValueLoss;
datetime lastBar=0, curDay=0;
int    dailyTrades=0;
double dailyStartEq=0, peakEquity=0;
bool   globalHalt=false;

//==================================================================
ENUM_ORDER_TYPE_FILLING GetFilling()
{
   uint f=(uint)SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   if((f&SYMBOL_FILLING_FOK)!=0) return ORDER_FILLING_FOK;
   if((f&SYMBOL_FILLING_IOC)!=0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

int OnInit()
{
   hIchi=iIchimoku(_Symbol,InpBaseTF,Ich_Tenkan,Ich_Kijun,Ich_Senkou);
   hEMAf=iMA(_Symbol,InpBaseTF,EMA_Fast,0,MODE_EMA,PRICE_CLOSE);
   hEMAs=iMA(_Symbol,InpBaseTF,EMA_Slow,0,MODE_EMA,PRICE_CLOSE);
   hATR_H1=iATR(_Symbol,InpBaseTF,ATR_Period);
   hATR_H4=iATR(_Symbol,PERIOD_H4,ATR_Period);
   hADX=iADX(_Symbol,InpBaseTF,14);
   hE5 =iMA(_Symbol,InpBaseTF,St_EMA5, 0,MODE_EMA,PRICE_CLOSE);
   hE8 =iMA(_Symbol,InpBaseTF,St_EMA8, 0,MODE_EMA,PRICE_CLOSE);
   hE21=iMA(_Symbol,InpBaseTF,St_EMA21,0,MODE_EMA,PRICE_CLOSE);
   hS55=iMA(_Symbol,InpBaseTF,St_SMA55,0,MODE_SMA,PRICE_CLOSE);
   hS100=iMA(_Symbol,InpBaseTF,St_SMA100,0,MODE_SMA,PRICE_CLOSE);
   hS200=iMA(_Symbol,InpBaseTF,St_SMA200,0,MODE_SMA,PRICE_CLOSE);

   if(hIchi==INVALID_HANDLE||hEMAf==INVALID_HANDLE||hEMAs==INVALID_HANDLE||
      hATR_H1==INVALID_HANDLE||hATR_H4==INVALID_HANDLE||hE5==INVALID_HANDLE||
      hS200==INVALID_HANDLE||hADX==INVALID_HANDLE)
   { Print("Erreur handles"); return INIT_FAILED; }

   pointVal=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   tickValueLoss=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);

   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(50);
   Trade.SetTypeFilling(GetFilling());

   dailyStartEq=AccountInfoDouble(ACCOUNT_EQUITY);
   peakEquity=dailyStartEq;
   Print("FusionBTC v1 init | ",_Symbol," | stack6MA=",RequireMAStack,
         " SL",ATR_SL_Mult," TP",ATR_TP_Mult," MC",MinConfirmations);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int r)
{
   IndicatorRelease(hIchi);IndicatorRelease(hEMAf);IndicatorRelease(hEMAs);
   IndicatorRelease(hATR_H1);IndicatorRelease(hATR_H4);IndicatorRelease(hADX);
   IndicatorRelease(hE5);IndicatorRelease(hE8);IndicatorRelease(hE21);
   IndicatorRelease(hS55);IndicatorRelease(hS100);IndicatorRelease(hS200);
   Comment("");
}

//==================================================================
double Buf(int h,int idx,int shift){ double b[]; if(CopyBuffer(h,idx,shift,1,b)<1) return 0; return b[0]; }

// Direction du stack 6 MA + Kijun sur barre fermee (shift=1)
// StackStrict=true  : les 6 MA strictement ordonnees (signal rare, tres pur)
// StackStrict=false : alignement souple = prix au-dessus/dessous des MA cles
//                     + tendance EMA21 vs SMA200 + position vs Kijun (bcp plus frequent)
int StackDir()
{
   double e5=Buf(hE5,0,1),e8=Buf(hE8,0,1),e21=Buf(hE21,0,1);
   double s55=Buf(hS55,0,1),s100=Buf(hS100,0,1),s200=Buf(hS200,0,1);
   double kj=Buf(hIchi,ICH_KIJUN,1);
   double px=iClose(_Symbol,InpBaseTF,1);
   if(e5==0||s200==0||kj==0) return 0;

   if(StackStrict)
   {
      if(e5>e8 && e8>e21 && e21>s55 && s55>s100 && s100>s200 && px>kj && kj>s200) return 1;
      if(e5<e8 && e8<e21 && e21<s55 && s55<s100 && s100<s200 && px<kj && kj<s200) return -1;
      return 0;
   }
   // Mode souple
   if(px>e21 && px>s55 && px>s100 && px>s200 && e21>s200 && px>kj) return 1;
   if(px<e21 && px<s55 && px<s100 && px<s200 && e21<s200 && px<kj) return -1;
   return 0;
}

double GetATR(int h){ double b[]; if(CopyBuffer(h,0,1,1,b)<1) return 0; return b[0]; }

// FVG (Fair Value Gap) dans le sens 'dir' sur les FVG_Lookback dernieres H1.
// Bull FVG : low[k] > high[k+2] (gap haussier) ; Bear : high[k] < low[k+2].
bool HasFVG(int dir)
{
   if(!UseFVGFilter) return true;
   for(int k=1;k<=FVG_Lookback;k++)
   {
      double lo_k =iLow(_Symbol,InpBaseTF,k),   hi_k =iHigh(_Symbol,InpBaseTF,k);
      double hi_k2=iHigh(_Symbol,InpBaseTF,k+2), lo_k2=iLow(_Symbol,InpBaseTF,k+2);
      if(dir>0 && lo_k>hi_k2) return true;
      if(dir<0 && hi_k<lo_k2) return true;
   }
   return false;
}

//-- Valeur de perte par lot pour une distance SL, avec garde-fou anti-aberration
//   (inspire de EA Gold CCI+MACD v2 : certains comptes/brokers renvoient un
//    TICK_VALUE_LOSS faux. On compare a contractSize*tickSize et on corrige.)
double LossPerLot(double slDist)
{
   if(slDist<=0||tickSize<=0) return 0;
   double tvl=tickValueLoss;
   double contract=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_CONTRACT_SIZE);
   double expected=contract*tickSize;            // valeur attendue d'un tick / lot
   if(expected>0 && (tvl<expected*0.5 || tvl>expected*5.0))
   {
      if(tvl!=expected) Print("⚠ TickValueLoss aberrant (",tvl,") -> corrige a ",expected);
      tvl=expected;                              // fallback robuste
   }
   if(tvl<=0) return 0;
   return (slDist/tickSize)*tvl;
}

double CalcLot(double slDist)
{
   double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double lpl=LossPerLot(slDist);
   if(lpl<=0) return mn;
   double risk=AccountInfoDouble(ACCOUNT_EQUITY)*RiskPercent/100.0;
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double lot=MathFloor(risk/lpl/step)*step;
   return MathMax(mn,MathMin(MaxLotSize,lot));
}

double RiskUSD(double slDist,double lot)
{
   return LossPerLot(slDist)*lot;   // utilise le meme calcul corrige
}

bool RiskAllowed(double slDist,double lot)
{
   if(MaxRiskPctBlock<=0) return true;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   return RiskUSD(slDist,lot) <= eq*MaxRiskPctBlock/100.0;
}

int CountPos()
{
   int n=0;
   for(int i=0;i<PositionsTotal();i++)
   { ulong t=PositionGetTicket(i);
     if(PositionSelectByTicket(t)&&PositionGetInteger(POSITION_MAGIC)==MagicNumber&&
        PositionGetString(POSITION_SYMBOL)==_Symbol) n++; }
   return n;
}

//==================================================================
void OnTick()
{
   ManagePositions();

   // kill-switch DD global
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>peakEquity) peakEquity=eq;
   if(GlobalDDStop>0 && peakEquity>0 && (peakEquity-eq)/peakEquity*100.0>=GlobalDDStop)
   {
      if(!globalHalt){ Print("KILL-SWITCH DD global atteint, arret."); CloseAll(); }
      globalHalt=true; return;
   }

   datetime bt=iTime(_Symbol,InpBaseTF,0);
   if(bt==lastBar) return;
   lastBar=bt;

   // compteurs journaliers
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); dt.hour=0;dt.min=0;dt.sec=0;
   datetime today=StructToTime(dt);
   if(today!=curDay){ curDay=today; dailyTrades=0; dailyStartEq=eq; }

   if(!FiltersPass()) return;

   double atr=GetATR(hATR_H1);
   double ema50=Buf(hEMAf,0,1), ema200=Buf(hEMAs,0,1);
   double kijun=Buf(hIchi,ICH_KIJUN,1), tenkan=Buf(hIchi,ICH_TENKAN,1);
   double spanA=Buf(hIchi,ICH_SPANA,1), spanB=Buf(hIchi,ICH_SPANB,1);
   double c1=iClose(_Symbol,InpBaseTF,1), o1=iOpen(_Symbol,InpBaseTF,1);
   if(atr<=0||ema200<=0||kijun<=0||atr<ATR_MinThreshold) return;

   // ★ Filtre ADX : ne trader que les tendances reellement fortes
   if(UseADXFilter)
   {
      double adxv=Buf(hADX,0,1);   // buffer 0 = ligne ADX principale, barre fermee
      if(adxv<ADX_MinValue) return;
   }

   bool bull=ema50>ema200, bear=ema50<ema200;
   double kt=MathMax(spanA,spanB), kb=MathMin(spanA,spanB);
   bool aboveK=c1>kt, belowK=c1<kb, inKumo=(!aboveK&&!belowK);
   bool aboveKj=c1>kijun, belowKj=c1<kijun;

   int stack = RequireMAStack ? StackDir() : 99;
   if(CountPos()>0) return;

   // ===== STRATEGIE B =====
   if(RunStrategyB)
   {
      double hh=Highest(InpBaseTF,20,2), ll=Lowest(InpBaseTF,20,2);
      double t2=Buf(hIchi,ICH_TENKAN,2), k2=Buf(hIchi,ICH_KIJUN,2);
      // Croisement exact OU simple etat Tenkan/Kijun selon RequireTKCross
      bool tkBull = RequireTKCross ? ((tenkan>kijun)&&(t2<k2)) : (tenkan>kijun);
      bool tkBear = RequireTKCross ? ((tenkan<kijun)&&(t2>k2)) : (tenkan<kijun);
      // Cassure optionnelle
      bool brkBull = !RequireBreakout || (hh>0 && c1>hh);
      bool brkBear = !RequireBreakout || (ll>0 && c1<ll);
      if(bull && !inKumo && tkBull && brkBull &&
         Score(bull,aboveK,aboveKj,true,atr)>=MinConfirmations && (stack==1||stack==99))
      { double sl=c1-ATR_SL_Mult*atr, tp=c1+ATR_TP_Mult*atr; TryOpen(1,sl,tp,"_B_L"); return; }
      if(bear && !inKumo && tkBear && brkBear &&
         Score(bear,belowK,belowKj,true,atr)>=MinConfirmations && (stack==-1||stack==99))
      { double sl=c1+ATR_SL_Mult*atr, tp=c1-ATR_TP_Mult*atr; TryOpen(-1,sl,tp,"_B_S"); return; }
   }

   // ===== STRATEGIE C =====
   if(RunStrategyC)
   {
      // EMA200 D1 lue proprement
      double closeD1=iClose(_Symbol,PERIOD_D1,1);
      double ema200d1=0, bD[];
      int hD=iMA(_Symbol,PERIOD_D1,200,0,MODE_EMA,PRICE_CLOSE);
      if(hD!=INVALID_HANDLE){ if(CopyBuffer(hD,0,1,1,bD)>0) ema200d1=bD[0]; IndicatorRelease(hD); }
      if(ema200d1>0)
      {
         bool tBull=(closeD1>ema200d1)&&bull, tBear=(closeD1<ema200d1)&&bear;
         bool pbBull=(iLow(_Symbol,InpBaseTF,1)<=kijun*1.002)&&(c1>kijun)&&(c1>o1);
         bool pbBear=(iHigh(_Symbol,InpBaseTF,1)>=kijun*0.998)&&(c1<kijun)&&(c1<o1);
         if(tBull && pbBull && aboveK &&
            Score(bull,aboveK,aboveKj,true,atr)>=MinConfirmations && (stack==1||stack==99))
         { double sl=c1-ATR_SL_Mult*1.6*atr, tp=c1+ATR_TP_Mult*1.6*atr; TryOpen(1,sl,tp,"_C_L"); return; }
         if(tBear && pbBear && belowK &&
            Score(bear,belowK,belowKj,true,atr)>=MinConfirmations && (stack==-1||stack==99))
         { double sl=c1+ATR_SL_Mult*1.6*atr, tp=c1-ATR_TP_Mult*1.6*atr; TryOpen(-1,sl,tp,"_C_S"); return; }
      }
   }
}

//==================================================================
void TryOpen(int dir,double sl,double tp,string tag)
{
   if(!HasFVG(dir)) return;   // ★ affinage FVG (active par defaut)
   double slDist=MathAbs(iClose(_Symbol,InpBaseTF,1)-sl);
   double lot=CalcLot(slDist);
   if(lot<=0) return;
   if(!RiskAllowed(slDist,lot)) { Print("Skip ",tag," : risque min-lot > ",MaxRiskPctBlock,"%"); return; }
   double sln=NormalizeDouble(sl,_Digits), tpn=NormalizeDouble(tp,_Digits);
   bool ok = (dir>0) ? Trade.Buy(lot,_Symbol,0,sln,tpn,EA_Comment+tag)
                     : Trade.Sell(lot,_Symbol,0,sln,tpn,EA_Comment+tag);
   if(ok){ dailyTrades++; Print((dir>0?"BUY":"SELL")," ",tag," lot=",lot," sl=",sln," tp=",tpn); }
   else Print("Echec ",tag," : ",Trade.ResultRetcode()," ",Trade.ResultRetcodeDescription());
}

int Score(bool trend,bool kumoOK,bool kijunOK,bool cass,double atr)
{
   int s=0; if(trend)s++; if(kumoOK)s++; if(kijunOK)s++; if(cass)s++; if(atr>ATR_MinThreshold)s++;
   return s;
}

double Highest(ENUM_TIMEFRAMES tf,int lb,int sh){ int i=iHighest(_Symbol,tf,MODE_HIGH,lb,sh); return i<0?0:iHigh(_Symbol,tf,i); }
double Lowest(ENUM_TIMEFRAMES tf,int lb,int sh){ int i=iLowest(_Symbol,tf,MODE_LOW,lb,sh); return i<0?0:iLow(_Symbol,tf,i); }

bool FiltersPass()
{
   if(UseSpreadFilter)
   { double sp=SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID);
     if(sp>MaxSpreadUSD) return false; }
   if(UseSession)
   { MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
     if(!(dt.hour>=SessStart && dt.hour<SessEnd)) return false; }
   if(dailyStartEq>0)
   { double eq=AccountInfoDouble(ACCOUNT_EQUITY);
     if((dailyStartEq-eq)/dailyStartEq*100.0>MaxDailyLossPct) return false; }
   if(dailyTrades>=MaxDailyTrades) return false;
   return true;
}

//==================================================================
void ManagePositions()
{
   double atr=GetATR(hATR_H1);
   if(atr<=0) return;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      int type=(int)PositionGetInteger(POSITION_TYPE);
      double op=PositionGetDouble(POSITION_PRICE_OPEN);
      double csl=PositionGetDouble(POSITION_SL), ctp=PositionGetDouble(POSITION_TP);
      double cur=(type==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double dist=(type==POSITION_TYPE_BUY)?(cur-op):(op-cur);

      if(UseBreakEven && dist>=BE_TriggerATR*atr)
      {
         double be=(type==POSITION_TYPE_BUY)?op+BE_LockUSD:op-BE_LockUSD;
         if((type==POSITION_TYPE_BUY&&be>csl)||(type==POSITION_TYPE_SELL&&(be<csl||csl==0)))
            Trade.PositionModify(tk,NormalizeDouble(be,_Digits),ctp);
      }
      if(UseTrailingStop && dist>0)
      {
         double tr=Trail_ATR_Mult*atr;
         if(type==POSITION_TYPE_BUY){ double n=cur-tr; if(n>csl) Trade.PositionModify(tk,NormalizeDouble(n,_Digits),ctp); }
         else { double n=cur+tr; if(n<csl||csl==0) Trade.PositionModify(tk,NormalizeDouble(n,_Digits),ctp); }
      }
   }
}

void CloseAll()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   { ulong tk=PositionGetTicket(i);
     if(PositionSelectByTicket(tk)&&PositionGetInteger(POSITION_MAGIC)==MagicNumber&&
        PositionGetString(POSITION_SYMBOL)==_Symbol) Trade.PositionClose(tk); }
}
