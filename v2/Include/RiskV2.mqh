//+------------------------------------------------------------------+
//|                                                       RiskV2.mqh  |
//|  P4 - SL/TP/sizing (spec Sec10). Pure calculation - never places  |
//|  orders; TradeManagerV2.mqh consumes Compute()'s output to send   |
//|  the actual order.                                                |
//|                                                                   |
//|  SL = protectedExtreme +/- buffer, buffer from slBufferMode:      |
//|   PCT_OF_LEG: slBufferPct * legRange   (default, 0.10)            |
//|   ATR:        slBufferAtrMult * ATR                               |
//|   POINTS:     slBufferPoints * _Point                             |
//|  then widened (never tightened) by minStopAtrMult and, if         |
//|  clampStopsToBroker, the broker's own SYMBOL_TRADE_STOPS_LEVEL.   |
//|  R = |entry-SL|; TP = entry +/- rr*R (rr default 1.5).            |
//|                                                                   |
//|  Lot sizing reuses v1's proven OrderCalcProfit path verbatim      |
//|  (RiskManager.mqh's LossPerLot/LotForRisk) - NEVER manual         |
//|  tickValue/tickSize math, which inflated lots ~100x on some       |
//|  brokers (fixed in v1 commit 87807eb). Rounds DOWN to the volume  |
//|  step and returns 0 (refuse the trade) rather than over-risking   |
//|  when even the broker minimum lot would exceed the risk budget.   |
//|                                                                   |
//|  RM_PERCENT sizes off the INITIAL balance (2026-09-15, user       |
//|  request): riskPercent x whatever ACCOUNT_BALANCE was the moment  |
//|  Init() ran, captured once and never re-read live. The $ risked   |
//|  per trade is therefore constant all run - it does NOT compound   |
//|  up as the account grows, or shrink as it draws down.             |
//|                                                                   |
//|  Pure calculation - never places orders.                         |
//+------------------------------------------------------------------+
#ifndef V2_RISKV2_MQH
#define V2_RISKV2_MQH

#include "V2Common.mqh"

struct SRiskCalc
  {
   bool        valid;
   ENUM_DIR_V2 dir;
   double      entry;
   double      sl;
   double      tp;
   double      r;          // |entry-sl|, in price
   double      lots;
   double      riskMoney;  // money actually at stake at 'lots'
   double      rewardMoney;// riskMoney * rr (TP distance is exactly rr*R by construction)
   string      reason;     // set when !valid
  };

class CRiskV2
  {
private:
   SSettingsV2 m_s;
   string      m_sym;
   int         m_atrHandle;
   double      m_initialBalance;  // captured once in Init() - risk% is a fraction of THIS, never the live balance

   double ATR() const
     {
      if(m_atrHandle==INVALID_HANDLE) return(0.0);
      double a[]; ArraySetAsSeries(a,true);
      if(CopyBuffer(m_atrHandle,0,0,2,a)<1) return(0.0);
      return(a[0]);
     }

   //--- money made by 1.0 lot per 1.0 unit of price move, via the broker's
   //--- own profit calc (correct on any broker, unlike tickValue/tickSize)
   double ValuePerLotPerPrice() const
     {
      double ref=SymbolInfoDouble(m_sym,SYMBOL_BID);
      if(ref<=0) ref=100.0;
      double profit=0.0;
      if(OrderCalcProfit(ORDER_TYPE_BUY,m_sym,1.0,ref,ref+1.0,profit) && profit>0)
         return(profit);
      double tickVal =SymbolInfoDouble(m_sym,SYMBOL_TRADE_TICK_VALUE);
      double tickSize=SymbolInfoDouble(m_sym,SYMBOL_TRADE_TICK_SIZE);
      if(tickSize<=0) return(0);
      return(tickVal/tickSize);
     }

   int Digits_() const { return((int)SymbolInfoInteger(m_sym,SYMBOL_DIGITS)); }
   double Point_() const { return(SymbolInfoDouble(m_sym,SYMBOL_POINT)); }

   double SlBuffer(const double legRange) const
     {
      switch(m_s.slBufferMode)
        {
         case SLB_ATR:    { double a=ATR(); return((a>0)?m_s.slBufferAtrMult*a:0.0); }
         case SLB_POINTS: return(m_s.slBufferPoints*Point_());
         default:         return(m_s.slBufferPct*MathMax(0.0,legRange)); // SLB_PCT_OF_LEG
        }
     }

public:
   void Init(const SSettingsV2 &s,const string sym)
     {
      m_s=s; m_sym=sym;
      m_atrHandle=(s.atrPeriod>0)?iATR(sym,s.tf,s.atrPeriod):INVALID_HANDLE;
      m_initialBalance=AccountInfoDouble(ACCOUNT_BALANCE);
     }
   void Deinit(){ if(m_atrHandle!=INVALID_HANDLE) IndicatorRelease(m_atrHandle); }

   double CurrentATR() const { return(ATR()); }
   double InitialBalance() const { return(m_initialBalance); }

   //--- money lost on exactly 1.0 lot if price runs from entry to sl
   double LossPerLot(const double entry,const double sl) const
     {
      bool   isBuy=(sl<entry);
      double profit=0.0;
      if(!OrderCalcProfit(isBuy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,m_sym,1.0,entry,sl,profit))
         return(0.0);
      return(MathAbs(profit));
     }

   //--- fixed money risk per trade: riskPercent of the INITIAL balance
   //--- (captured once in Init(), never the live/current one) - so the
   //--- $ risked per trade never drifts as the account grows or draws
   //--- down (2026-09-15, user request)
   double RiskMoney() const
     {
      if(m_s.riskMode!=RM_PERCENT) return(0.0);
      return(m_initialBalance*m_s.riskPercent/100.0);
     }

   //--- lot size for one trade's risk budget over the SL distance;
   //--- 0 = refuse (even the broker minimum would over-risk)
   double LotForRisk(const double entry,const double sl) const
     {
      if(MathAbs(entry-sl)<=0) return(0.0);
      double lossPerLot=LossPerLot(entry,sl);
      if(lossPerLot<=0) return(0.0);

      double riskMoney=RiskMoney();
      if(riskMoney<=0) return(0.0);
      double lots=riskMoney/lossPerLot;

      double step=SymbolInfoDouble(m_sym,SYMBOL_VOLUME_STEP);
      double vmin=SymbolInfoDouble(m_sym,SYMBOL_VOLUME_MIN);
      double vmax=SymbolInfoDouble(m_sym,SYMBOL_VOLUME_MAX);
      if(step>0) lots=MathFloor(lots/step)*step;
      if(lots>vmax) lots=vmax;
      if(lots<vmin)
        {
         if(vmin*lossPerLot>riskMoney) return(0.0);
         lots=vmin;
        }
      return(lots);
     }

   double LotForEntry(const double entry,const double sl) const
     {
      if(m_s.riskMode==RM_FIXED_LOT)
        {
         double step=SymbolInfoDouble(m_sym,SYMBOL_VOLUME_STEP);
         double vmin=SymbolInfoDouble(m_sym,SYMBOL_VOLUME_MIN);
         double vmax=SymbolInfoDouble(m_sym,SYMBOL_VOLUME_MAX);
         double lots=m_s.fixedLot;
         if(step>0) lots=MathRound(lots/step)*step;
         if(lots<vmin) lots=vmin;
         if(lots>vmax) lots=vmax;
         return(lots);
        }
      return(LotForRisk(entry,sl));
     }

   //--- SL from the trigger's protected extreme, buffered + floored +
   //--- clamped to the broker's minimum stop distance
   double ComputeSL(const ENUM_DIR_V2 dir,const double entry,
                    const double protectedExtreme,const double legRange) const
     {
      double buf=SlBuffer(legRange);
      double sl=(dir==DIR_LONG)?protectedExtreme-buf:protectedExtreme+buf;

      double atr=ATR();
      if(m_s.minStopAtrMult>0.0 && atr>0.0)
        {
         double minDist=m_s.minStopAtrMult*atr;
         if(MathAbs(entry-sl)<minDist)
            sl=(dir==DIR_LONG)?entry-minDist:entry+minDist;
        }

      if(m_s.clampStopsToBroker)
        {
         long stopsLevelPts=SymbolInfoInteger(m_sym,SYMBOL_TRADE_STOPS_LEVEL);
         double minDist=(double)stopsLevelPts*Point_();
         if(minDist>0.0 && MathAbs(entry-sl)<minDist)
            sl=(dir==DIR_LONG)?entry-minDist:entry+minDist;
        }

      return(NormalizeDouble(sl,Digits_()));
     }

   double ComputeTP(const ENUM_DIR_V2 dir,const double entry,const double sl) const
     {
      double r=MathAbs(entry-sl);
      double tp=(dir==DIR_LONG)?entry+m_s.rr*r:entry-m_s.rr*r;
      return(NormalizeDouble(tp,Digits_()));
     }

   //--- preview: price at rr*R from entry, given only R (no real SL needed
   //--- yet) - used by a dry-run/preview caller (T3d used a local copy of
   //--- this same formula before this module existed; T4 calls this one)
   double PriceForR(const ENUM_DIR_V2 dir,const double entry,const double r) const
     {
      return((dir==DIR_LONG)?entry+m_s.rr*r:entry-m_s.rr*r);
     }

   //+--------------------------------------------------------------+
   //| One-call sizing: SL, TP, lots, and whether the trade is even   |
   //| valid (rejects rather than over-risking / zero-distance SL).   |
   //+--------------------------------------------------------------+
   SRiskCalc Compute(const ENUM_DIR_V2 dir,const double entry,
                     const double protectedExtreme,const double legRange) const
     {
      SRiskCalc c;
      c.dir=dir; c.entry=entry;
      c.sl=ComputeSL(dir,entry,protectedExtreme,legRange);
      c.r=MathAbs(entry-c.sl);
      c.tp=ComputeTP(dir,entry,c.sl);
      c.lots=(c.r>0.0)?LotForEntry(entry,c.sl):0.0;
      c.riskMoney=(c.lots>0.0)?LossPerLot(entry,c.sl)*c.lots:0.0;
      c.rewardMoney=c.riskMoney*m_s.rr;
      c.valid=(c.r>0.0 && c.lots>0.0);
      c.reason=c.valid?"":( (c.r<=0.0)?"zero SL distance":"lot size = 0 (min lot would over-risk)" );
      return(c);
     }
  };

#endif // V2_RISKV2_MQH
