//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh  |
//|  Position sizing (0.95% risk, rule 9), %-of-capital <-> price     |
//|  conversions, break-even (rule 7), and per-session trade caps     |
//|  (rule 10: stop after 1 win, else max 2).                         |
//+------------------------------------------------------------------+
#ifndef SESSIONS_STRATEGY_RISKMANAGER_MQH
#define SESSIONS_STRATEGY_RISKMANAGER_MQH

#include "Common.mqh"

class CRiskManager
  {
private:
   SSettings m_s;
   string    m_symbol;
   // per-session counters
   string    m_sessionKey;
   int       m_trades;
   int       m_wins;

   //--- Money made by 1.0 lot per 1.0 unit of price move, via the broker's
   //    own profit calc (correct on any broker, unlike tickValue/tickSize).
   double    ValuePerLotPerPrice() const
     {
      double ref=SymbolInfoDouble(m_symbol,SYMBOL_BID);
      if(ref<=0) ref=100.0;
      double profit=0.0;
      if(OrderCalcProfit(ORDER_TYPE_BUY,m_symbol,1.0,ref,ref+1.0,profit) && profit>0)
         return(profit);            // money per +1.0 price on 1.0 lot
      // fallback to the raw tick math if the profit calc is unavailable
      double tickVal =SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_VALUE);
      double tickSize=SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_SIZE);
      if(tickSize<=0) return(0);
      return(tickVal/tickSize);
     }

public:
   void Init(const SSettings &s,const string symbol)
     {
      m_s=s; m_symbol=symbol;
      m_sessionKey=""; m_trades=0; m_wins=0;
     }

   double CapitalRef() const { return(AccountInfoDouble(ACCOUNT_BALANCE)); }

   //--- Money lost on exactly 1.0 lot if price runs from entry to the stop.
   //    Uses the broker's own OrderCalcProfit so the result is correct on any
   //    broker/symbol - NOT the manual tickValue/tickSize math, which some
   //    brokers report in scaled units (e.g. tickValue in cents), inflating
   //    the lot size ~100x and turning 0.95% risk into ~95%.
   double LossPerLot(const double entry,const double sl) const
     {
      bool   isBuy=(sl<entry);
      double profit=0.0;
      // a losing exit: BUY closed at a lower SL / SELL closed at a higher SL
      if(!OrderCalcProfit(isBuy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,
                          m_symbol,1.0,entry,sl,profit))
         return(0);
      return(MathAbs(profit)); // money risked per 1.0 lot over this SL distance
     }

   //--- Lot size for a fixed riskPercent% capital risk over the SL distance
   double LotForRisk(const double entry,const double sl) const
     {
      if(MathAbs(entry-sl)<=0) return(0);
      double lossPerLot=LossPerLot(entry,sl);
      if(lossPerLot<=0) return(0);

      double riskMoney=CapitalRef()*m_s.riskPercent/100.0; // 0.95 -> 0.95%
      double lots=riskMoney/lossPerLot;

      double step=SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_STEP);
      double vmin=SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MIN);
      double vmax=SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MAX);
      // round DOWN to the step so realized risk never exceeds the target
      if(step>0) lots=MathFloor(lots/step)*step;
      if(lots>vmax) lots=vmax;
      // if even the broker minimum would risk more than requested, refuse the
      // trade rather than silently over-risking
      if(lots<vmin)
        {
         if(vmin*lossPerLot>riskMoney) return(0);
         lots=vmin;
        }
      return(lots);
     }

   //--- Price level that yields 'pct' % of capital for a given lot size
   double PriceForPercent(const double pct,const double lots,
                          const bool isBuy,const double entry) const
     {
      double vpp=ValuePerLotPerPrice();
      if(vpp<=0 || lots<=0) return(0);
      double money=CapitalRef()*pct/100.0;
      double move=money/(lots*vpp);
      return(isBuy ? entry+move : entry-move);
     }

   //--- Current floating profit of a position as % of capital
   double FloatPercent(const double profitMoney) const
     {
      double cap=CapitalRef();
      if(cap<=0) return(0);
      return(profitMoney/cap*100.0);
     }

   //+----------------------------------------------------------------+
   //| Session caps                                                   |
   //+----------------------------------------------------------------+
   void SyncSession(const string sessionKey)
     {
      if(sessionKey!=m_sessionKey)
        {
         m_sessionKey=sessionKey;
         m_trades=0; m_wins=0;
        }
     }

   bool CanOpen() const
     {
      if(m_s.stopAfterFirstWin && m_wins>0) return(false); // rule 13
      return(m_trades<m_s.maxTradesPerSession);            // rule 10
     }

   void RegisterOpen()              { m_trades++; }
   void RegisterClose(const bool win){ if(win) m_wins++; }

   int  Trades() const { return(m_trades); }
   int  Wins()   const { return(m_wins);   }
  };

#endif // SESSIONS_STRATEGY_RISKMANAGER_MQH
