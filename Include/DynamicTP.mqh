//+------------------------------------------------------------------+
//|                                                    DynamicTP.mqh  |
//|  Momentum + structure runner (README Section 6).                 |
//|   +2%  -> break-even (rule 7)                                    |
//|   +4%  -> default target: optional partial, then runner          |
//|   4-10%-> trail behind structure, extend while momentum is STRONG |
//|   +10% -> hard cap (rule 11)                                     |
//|  Never auto-closes before +4% (rule 14).                         |
//+------------------------------------------------------------------+
#ifndef SESSIONS_STRATEGY_DYNAMICTP_MQH
#define SESSIONS_STRATEGY_DYNAMICTP_MQH

#include <Trade/Trade.mqh>
#include "Common.mqh"
#include "Liquidity.mqh"
#include "EntryModels.mqh"
#include "RiskManager.mqh"

class CDynamicTP
  {
private:
   SSettings m_s;
   string    m_symbol;
   int       m_atrHandle;
   // per-trade state
   bool      m_active;
   ulong     m_ticket;
   bool      m_isBuy;
   double    m_entry;
   double    m_atrAtEntry;
   bool      m_beDone;
   bool      m_partialDone;

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
   void Momentum(CEntryModels &em,bool &strong,bool &weak)
     {
      strong=false; weak=false;
      MqlRates r[]; ArraySetAsSeries(r,true);
      int sb=MathMax(2,m_s.momentumStallBars);
      int n=CopyRates(m_symbol,m_s.tf,0,3*sb+4,r);
      if(n<sb+2) return;
      double atr=ATR(); if(atr<=0) return;

      double body=MathAbs(r[1].close-r[1].open);
      bool dirOK=m_isBuy?(r[1].close>r[1].open):(r[1].close<r[1].open);
      bool displacement=dirOK && body>=m_s.momentumBodyATR*atr;

      // progress: a new extreme in trade direction on the last bar
      bool progress=true;
      for(int k=2;k<=sb;k++)
        {
         if(m_isBuy && r[k].high>=r[1].high){ progress=false; break; }
         if(!m_isBuy&& r[k].low <=r[1].low ){ progress=false; break; }
        }

      // opposing CHoCH = a genuine close-confirmed reversal against us
      SEntrySignal os;
      ENUM_BIAS opp=m_isBuy?BIAS_SELL:BIAS_BUY;
      bool oppCHoCH=em.CheckCHoCH(opp,os);

      // ONLY a real reversal forces an early exit. Stalls, ATR contraction
      // and single opposite candles are NOT exits — the trade keeps riding
      // the structure trail toward the 10% cap (let winners run).
      weak   = oppCHoCH;
      strong = displacement && progress;
     }

public:
   void Init(const SSettings &s,const string symbol)
     {
      m_s=s; m_symbol=symbol; m_active=false;
      m_atrHandle=iATR(symbol,s.tf,14);
     }
   void Deinit(){ if(m_atrHandle!=INVALID_HANDLE) IndicatorRelease(m_atrHandle); }

   bool  Active() const { return(m_active); }
   ulong Ticket() const { return(m_ticket); }

   void OnNewTrade(const ulong ticket,const bool isBuy,const double entry)
     {
      m_active=true; m_ticket=ticket; m_isBuy=isBuy; m_entry=entry;
      m_atrAtEntry=ATR();
      m_beDone=false; m_partialDone=false;
     }

   void Clear(){ m_active=false; m_ticket=0; }

   //--- Called every new bar while a position is open
   void Manage(CTrade &trade,CRiskManager &rm,CEntryModels &em)
     {
      if(!m_active) return;
      if(!PositionSelectByTicket(m_ticket)){ Clear(); return; }

      double lots  =PositionGetDouble(POSITION_VOLUME);
      double profit=PositionGetDouble(POSITION_PROFIT);
      double sl    =PositionGetDouble(POSITION_SL);
      double tp    =PositionGetDouble(POSITION_TP);
      double pct   =rm.FloatPercent(profit);

      // 1) Break-even at +2% (rule 7)
      if(!m_beDone && pct>=m_s.breakEvenAtPercent)
        {
         double be=m_entry;
         if((m_isBuy && (sl<be||sl==0)) || (!m_isBuy && (sl>be||sl==0)))
            trade.PositionModify(m_ticket,be,tp);
         m_beDone=true;
        }

      // Nothing else acts before the +4% default target (rule 14)
      if(pct<m_s.defaultTargetPercent) return;

      // 2) Hard cap at +10% (rule 11)
      if(pct>=m_s.maxTargetPercent){ trade.PositionClose(m_ticket); Clear(); return; }

      // 3) Optional partial at the default target
      if(m_s.usePartialTP && !m_partialDone)
        {
         double step=SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_STEP);
         double vmin=SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MIN);
         double part=lots*m_s.partialPercent/100.0;
         if(step>0) part=MathFloor(part/step)*step;
         if(part>=vmin && (lots-part)>=vmin)
            trade.PositionClosePartial(m_ticket,part);
         m_partialDone=true;
        }

      // 4) Runner: momentum decides extend vs take-profit
      bool strong,weak; Momentum(em,strong,weak);
      if(weak){ trade.PositionClose(m_ticket); Clear(); return; }

      // STRONG (or neutral): trail behind the latest structure swing
      double swing;
      if(NearestSwing(m_isBuy,swing))
        {
         double pad=m_s.trailPadPoints*SymbolInfoDouble(m_symbol,SYMBOL_POINT);
         double newSL=m_isBuy?swing-pad:swing+pad;
         // never below break-even, only ratchet in our favor
         if(m_isBuy)  newSL=MathMax(newSL,m_entry);
         else         newSL=MathMin(newSL,m_entry);
         bool improve=m_isBuy?(newSL>sl):(newSL<sl || sl==0);
         if(improve) trade.PositionModify(m_ticket,newSL,tp);
        }
     }
  };

#endif // SESSIONS_STRATEGY_DYNAMICTP_MQH
