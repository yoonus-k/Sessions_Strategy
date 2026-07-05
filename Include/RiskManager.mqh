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

   double    ValuePerLotPerPrice() const
     {
      double tickVal =SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_VALUE);
      double tickSize=SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_SIZE);
      if(tickSize<=0) return(0);
      return(tickVal/tickSize); // money per 1.0 price unit per 1.0 lot
     }

public:
   void Init(const SSettings &s,const string symbol)
     {
      m_s=s; m_symbol=symbol;
      m_sessionKey=""; m_trades=0; m_wins=0;
     }

   double CapitalRef() const { return(AccountInfoDouble(ACCOUNT_BALANCE)); }

   //--- Lot size for a fixed 0.95% capital risk over the SL distance
   double LotForRisk(const double entry,const double sl) const
     {
      double priceRisk=MathAbs(entry-sl);
      double vpp=ValuePerLotPerPrice();
      if(priceRisk<=0 || vpp<=0) return(0);
      double riskMoney=CapitalRef()*m_s.riskPercent/100.0;
      double lots=riskMoney/(priceRisk*vpp);

      double step=SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_STEP);
      double vmin=SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MIN);
      double vmax=SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MAX);
      if(step>0) lots=MathFloor(lots/step)*step;
      lots=MathMax(vmin,MathMin(vmax,lots));
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
