//+------------------------------------------------------------------+
//|                                                    DynamicTP.mqh  |
//|  Momentum + structure runner (README Section 6).                 |
//|   +2%  -> break-even (rule 7)                                    |
//|   +4%  -> default target: optional partial, then runner          |
//|   4-10%-> trail behind structure, extend while momentum is STRONG |
//|   +10% -> hard cap (rule 11)                                     |
//|  Never auto-closes before +4% (rule 14).                         |
//|                                                                  |
//|  Tracks up to SS_MAX_OPEN positions at once: with                |
//|  addWhenBreakEven the EA may hold several, and each carries its   |
//|  own break-even / partial / entry state.                         |
//+------------------------------------------------------------------+
#ifndef SESSIONS_STRATEGY_DYNAMICTP_MQH
#define SESSIONS_STRATEGY_DYNAMICTP_MQH

#include <Trade/Trade.mqh>
#include "Common.mqh"
#include "Liquidity.mqh"
#include "EntryModels.mqh"
#include "RiskManager.mqh"

//--- per-position lifecycle state
struct STpTrade
  {
   bool      active;
   ulong     ticket;
   bool      isBuy;
   double    entry;
   double    atrAtEntry;
   bool      beDone;
   bool      partialDone;
  };

class CDynamicTP
  {
private:
   SSettings m_s;
   string    m_symbol;
   int       m_atrHandle;
   STpTrade  m_t[SS_MAX_OPEN];

   double ATR() const
     {
      double a[]; ArraySetAsSeries(a,true);
      if(CopyBuffer(m_atrHandle,0,0,2,a)<1) return(0);
      return(a[0]);
     }

   //--- most recent confirmed swing low/high for the structure trail
   bool NearestSwing(const bool wantLow,double &level)
     {
      int N=m_s.swingStrength;
      MqlRates r[]; ArraySetAsSeries(r,true);
      int n=CopyRates(m_symbol,m_s.tf,0,120+2*N,r);
      if(n<2*N+4) return(false);
      for(int i=1+N;i<n-N;i++)
        {
         if(wantLow && IsSwingLow(r,n,i,N)) { level=r[i].low;  return(true); }
         if(!wantLow&& IsSwingHigh(r,n,i,N)){ level=r[i].high; return(true); }
        }
      return(false);
     }

   //--- momentum classification on the last closed bar
   void Momentum(CEntryModels &em,const bool isBuy,bool &strong,bool &weak)
     {
      strong=false; weak=false;
      MqlRates r[]; ArraySetAsSeries(r,true);
      int sb=MathMax(2,m_s.momentumStallBars);
      int n=CopyRates(m_symbol,m_s.tf,0,3*sb+4,r);
      if(n<sb+2) return;
      double atr=ATR(); if(atr<=0) return;

      double body=MathAbs(r[1].close-r[1].open);
      bool dirOK=isBuy?(r[1].close>r[1].open):(r[1].close<r[1].open);
      bool displacement=dirOK && body>=m_s.momentumBodyATR*atr;

      // progress: a new extreme in trade direction on the last bar
      bool progress=true;
      for(int k=2;k<=sb;k++)
        {
         if(isBuy && r[k].high>=r[1].high){ progress=false; break; }
         if(!isBuy&& r[k].low <=r[1].low ){ progress=false; break; }
        }

      // opposing CHoCH = a genuine close-confirmed reversal against us
      SEntrySignal os;
      ENUM_BIAS opp=isBuy?BIAS_SELL:BIAS_BUY;
      bool oppCHoCH=em.CheckCHoCH(opp,os);

      // ONLY a real reversal forces an early exit. Stalls, ATR contraction
      // and single opposite candles are NOT exits — the trade keeps riding
      // the structure trail toward the 10% cap (let winners run).
      weak   = oppCHoCH;
      strong = displacement && progress;
     }

   //--- full lifecycle for ONE tracked position
   void ManageOne(STpTrade &t,CTrade &trade,CRiskManager &rm,CEntryModels &em)
     {
      if(!PositionSelectByTicket(t.ticket)){ t.active=false; return; }

      double lots  =PositionGetDouble(POSITION_VOLUME);
      double profit=PositionGetDouble(POSITION_PROFIT);
      double sl    =PositionGetDouble(POSITION_SL);
      double tp    =PositionGetDouble(POSITION_TP);

      // All three thresholds come from CRiskManager in MONEY, so this logic is
      // identical whether the user configured % of balance or a fixed amount.
      // 1) Break-even (rule 7)
      if(!t.beDone && profit>=rm.BreakEvenMoney())
        {
         double be=t.entry;
         if((t.isBuy && (sl<be||sl==0)) || (!t.isBuy && (sl>be||sl==0)))
            trade.PositionModify(t.ticket,be,tp);
         t.beDone=true;
        }

      // Nothing else acts before the default target (rule 14)
      if(profit<rm.DefaultTargetMoney()) return;

      // 2) Hard cap (rule 11)
      if(profit>=rm.MaxTargetMoney()){ trade.PositionClose(t.ticket); t.active=false; return; }

      // 3) Optional partial at the default target
      if(m_s.usePartialTP && !t.partialDone)
        {
         double step=SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_STEP);
         double vmin=SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MIN);
         double part=lots*m_s.partialPercent/100.0;
         if(step>0) part=MathFloor(part/step)*step;
         if(part>=vmin && (lots-part)>=vmin)
            trade.PositionClosePartial(t.ticket,part);
         t.partialDone=true;
        }

      // 4) Runner: momentum decides extend vs take-profit
      bool strong,weak; Momentum(em,t.isBuy,strong,weak);
      if(weak){ trade.PositionClose(t.ticket); t.active=false; return; }

      // STRONG (or neutral): trail behind the latest structure swing
      double swing;
      if(NearestSwing(t.isBuy,swing))
        {
         double pad=m_s.trailPadPoints*SymbolInfoDouble(m_symbol,SYMBOL_POINT);
         double newSL=t.isBuy?swing-pad:swing+pad;
         // never below break-even, only ratchet in our favor
         if(t.isBuy)  newSL=MathMax(newSL,t.entry);
         else         newSL=MathMin(newSL,t.entry);
         bool improve=t.isBuy?(newSL>sl):(newSL<sl || sl==0);
         if(improve) trade.PositionModify(t.ticket,newSL,tp);
        }
     }

public:
   void Init(const SSettings &s,const string symbol)
     {
      m_s=s; m_symbol=symbol;
      for(int i=0;i<SS_MAX_OPEN;i++) m_t[i].active=false;
      m_atrHandle=iATR(symbol,s.tf,14);
     }
   void Deinit(){ if(m_atrHandle!=INVALID_HANDLE) IndicatorRelease(m_atrHandle); }

   int Count() const
     {
      int n=0;
      for(int i=0;i<SS_MAX_OPEN;i++) if(m_t[i].active) n++;
      return(n);
     }

   void OnNewTrade(const ulong ticket,const bool isBuy,const double entry)
     {
      for(int i=0;i<SS_MAX_OPEN;i++)
        {
         if(m_t[i].active) continue;
         m_t[i].active=true;  m_t[i].ticket=ticket;
         m_t[i].isBuy=isBuy;  m_t[i].entry=entry;
         m_t[i].atrAtEntry=ATR();
         m_t[i].beDone=false; m_t[i].partialDone=false;
         return;
        }
      PrintFormat("[SS] WARNING: DynamicTP has no free slot for %I64u - position will be UNMANAGED",ticket);
     }

   //--- drop one tracked position (it closed), or all of them
   void Clear(const ulong ticket)
     {
      for(int i=0;i<SS_MAX_OPEN;i++)
         if(m_t[i].active && m_t[i].ticket==ticket){ m_t[i].active=false; return; }
     }
   void ClearAll(){ for(int i=0;i<SS_MAX_OPEN;i++) m_t[i].active=false; }

   //--- Called while positions are open: every tick, or on the new bar only
   //    when settings.manageOnBarClose is set (see OnTick).
   void Manage(CTrade &trade,CRiskManager &rm,CEntryModels &em)
     {
      for(int i=0;i<SS_MAX_OPEN;i++)
         if(m_t[i].active) ManageOne(m_t[i],trade,rm,em);
     }
  };

#endif // SESSIONS_STRATEGY_DYNAMICTP_MQH
