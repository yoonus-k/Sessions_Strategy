//+------------------------------------------------------------------+
//|                                                TradeAnalytics.mqh |
//|  Per-trade analytics export for backtest research.                |
//|                                                                   |
//|  Records one row per closed position with excursion (MAE/MFE),    |
//|  full setup context, exit anatomy, and an optional counterfactual |
//|  ("would the ORIGINAL stop/target have won?").                    |
//|                                                                   |
//|  MEASUREMENT ONLY - nothing here influences a trading decision.   |
//|                                                                   |
//|  Excursion is folded from COMPLETED BAR highs/lows rather than    |
//|  sampled from ticks, so the exported MAE/MFE is identical under   |
//|  every tester tick model. Tick samples cover only the partial     |
//|  entry and exit bars, which no completed bar can represent.       |
//|                                                                   |
//|  Rows are buffered in memory and written ONCE at the end of the   |
//|  run (see Flush): rewriting the file per trade dominated runtime, |
//|  and buffering also lets rows be emitted in open order even when  |
//|  the counterfactual watcher resolves them out of order.           |
//+------------------------------------------------------------------+
#ifndef SESSIONS_STRATEGY_TRADEANALYTICS_MQH
#define SESSIONS_STRATEGY_TRADEANALYTICS_MQH

#include "Common.mqh"

//+------------------------------------------------------------------+
//| Everything recorded about one trade                              |
//+------------------------------------------------------------------+
struct STradeRecord
  {
   //--- identity / timing
   int              tradeNo;
   ulong            ticket;
   long             positionId;
   datetime         openTime;
   datetime         closeTime;
   datetime         openBar;         // bar the position opened on (excluded from bar folding)
   string           weekday;
   string           session;
   int              minsFromSessionOpen;
   //--- setup context
   bool             isBuy;
   string           bias;
   string           biasSource;
   string           model;
   string           orderKind;       // LIMIT / MARKET / LIMIT_DEGRADED
   int              bosCount;
   double           sweptLevel;
   datetime         sweptTime;
   double           sweepExtreme;
   double           sessionOpenPx;
   double           vwapAtOpen;
   double           rangeHi;
   double           rangeLo;
   bool             rangeExited;
   double           atrAtEntry;
   int              spreadAtEntry;
   //--- execution / risk
   double           requestedPrice;
   double           entryPrice;
   double           lots;
   double           initialSL;
   double           initialTP;
   double           riskMoney;       // 1R in money
   double           riskPct;
   string           riskMode;
   double           balanceOpen;
   double           equityOpen;
   //--- excursion (prices; money/R derived at write time)
   double           mfePrice;
   double           maePrice;
   datetime         mfeTime;
   datetime         maeTime;
   double           mfePriceBeforeBE;
   //--- lifecycle
   bool             beArmed;         // the stop actually moved (modify succeeded)
   datetime         beTime;
   bool             partialTaken;
   double           partialLots;
   double           partialMoney;
   int              trailMoves;
   double           finalSL;
   //--- exit
   double           exitPrice;
   ENUM_EXIT_REASON exitReason;
   double           grossProfit;
   double           commission;
   double           swap;
   double           netProfit;
   double           balanceClose;
   //--- counterfactual
   ENUM_CF_STATE    cfState;
   double           cfMfePrice;
   int              cfBarsLeft;
  };

//+------------------------------------------------------------------+
class CTradeAnalytics
  {
private:
   bool         m_enabled;
   bool         m_useCf;
   int          m_cfBars;
   string       m_file;
   string       m_symbol;
   int          m_digits;
   double       m_point;
   STradeRecord m_rec[];      // every finished trade, in close order
   int          m_count;

   //--- money made by 1.0 lot over a 1.0 price move (broker's own calc)
   double ValuePerLotPerPrice() const
     {
      double ref=SymbolInfoDouble(m_symbol,SYMBOL_BID);
      if(ref<=0) ref=100.0;
      double profit=0.0;
      if(OrderCalcProfit(ORDER_TYPE_BUY,m_symbol,1.0,ref,ref+1.0,profit) && profit>0)
         return(profit);
      double tv=SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_VALUE);
      double ts=SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_SIZE);
      if(ts<=0) return(0);
      return(tv/ts);
     }

   //--- signed favourable / adverse excursion in PRICE for one record
   double FavourableMove(const STradeRecord &r) const
     { return(r.isBuy ? r.mfePrice-r.entryPrice : r.entryPrice-r.mfePrice); }
   double AdverseMove(const STradeRecord &r) const
     { return(r.isBuy ? r.entryPrice-r.maePrice : r.maePrice-r.entryPrice); }

   string D(const double v,const int digits) const { return(DoubleToString(v,digits)); }
   string T(const datetime t) const
     { return(t>0?TimeToString(t,TIME_DATE|TIME_SECONDS):""); }
   string B(const bool b) const { return(b?"1":"0"); }

   string Header() const
     {
      return("trade_no,ticket,position_id,"
             "open_time,close_time,open_time_riyadh,weekday,session,"
             "mins_from_session_open,duration_min,duration_bars,"
             "bias,bias_source,model,order_kind,bos_count,"
             "swept_level,swept_time,sweep_extreme,"
             "session_open_px,vwap_at_open,vwap_distance,"
             "range_hi,range_lo,range_exited,atr_at_entry,spread_at_entry,"
             "requested_price,entry_price,slippage_points,"
             "lots,initial_sl,initial_tp,sl_distance_price,sl_distance_money,"
             "risk_money,risk_pct,risk_mode,balance_open,equity_open,"
             "mfe_price,mfe_money,mfe_r,mfe_time,"
             "mae_price,mae_money,mae_r,mae_time,"
             "mfe_before_be_r,mfe_after_be_r,giveback_r,efficiency,"
             "exit_price,exit_reason,"
             "gross_profit,commission,swap,net_profit,net_r,net_pct_balance,"
             "be_armed,be_time,partial_taken,partial_lots,partial_money,"
             "trail_moves,final_sl,balance_close,"
             "post_exit_outcome,post_exit_mfe_r");
     }

   string Row(const STradeRecord &r,const double vpp,const SSettings &s) const
     {
      double oneR   = r.riskMoney>0?r.riskMoney:0;
      double perPx  = r.lots*vpp;                    // money per 1.0 of price
      double favPx  = FavourableMove(r);
      double advPx  = AdverseMove(r);
      double mfeMon = favPx*perPx;
      double maeMon = advPx*perPx;
      double mfeR   = oneR>0?mfeMon/oneR:0;
      double maeR   = oneR>0?maeMon/oneR:0;
      double netR   = oneR>0?r.netProfit/oneR:0;
      double slDistPx = MathAbs(r.entryPrice-r.initialSL);
      double slDistMon= slDistPx*perPx;

      double beFavPx = r.beArmed
                       ? (r.isBuy?r.mfePriceBeforeBE-r.entryPrice:r.entryPrice-r.mfePriceBeforeBE)
                       : favPx;
      double mfeBeforeR = oneR>0?beFavPx*perPx/oneR:0;
      double mfeAfterR  = r.beArmed?mfeR-mfeBeforeR:0;

      // efficiency: share of the best unrealised gain that was actually kept.
      // Undefined when the trade never went positive - left blank, not 0, so
      // it cannot be averaged into a misleading number.
      string eff = (mfeMon>0) ? D(r.netProfit/mfeMon,4) : "";

      double cfFavPx = r.isBuy?r.cfMfePrice-r.entryPrice:r.entryPrice-r.cfMfePrice;
      string cfR = (r.cfState==CF_NA)?"":D(oneR>0?cfFavPx*perPx/oneR:0,4);

      int durMin  = (int)((r.closeTime-r.openTime)/60);
      int secsPer = PeriodSeconds(s.tf);
      int durBars = secsPer>0?(int)((r.closeTime-r.openTime)/secsPer):0;
      double slipPts = m_point>0
                       ? (r.isBuy?(r.entryPrice-r.requestedPrice):(r.requestedPrice-r.entryPrice))/m_point
                       : 0;

      string o="";
      o+=IntegerToString(r.tradeNo)+","+IntegerToString((long)r.ticket)+","+IntegerToString(r.positionId)+",";
      o+=T(r.openTime)+","+T(r.closeTime)+","+T(ToRiyadh(r.openTime,s))+","+r.weekday+","+r.session+",";
      o+=IntegerToString(r.minsFromSessionOpen)+","+IntegerToString(durMin)+","+IntegerToString(durBars)+",";
      o+=r.bias+","+r.biasSource+","+r.model+","+r.orderKind+","+IntegerToString(r.bosCount)+",";
      o+=D(r.sweptLevel,m_digits)+","+T(r.sweptTime)+","+D(r.sweepExtreme,m_digits)+",";
      o+=D(r.sessionOpenPx,m_digits)+","+D(r.vwapAtOpen,m_digits)+","+D(r.sessionOpenPx-r.vwapAtOpen,m_digits)+",";
      o+=D(r.rangeHi,m_digits)+","+D(r.rangeLo,m_digits)+","+B(r.rangeExited)+","+D(r.atrAtEntry,m_digits)+","+IntegerToString(r.spreadAtEntry)+",";
      o+=D(r.requestedPrice,m_digits)+","+D(r.entryPrice,m_digits)+","+D(slipPts,1)+",";
      o+=D(r.lots,2)+","+D(r.initialSL,m_digits)+","+D(r.initialTP,m_digits)+","+D(slDistPx,m_digits)+","+D(slDistMon,2)+",";
      o+=D(r.riskMoney,2)+","+D(r.riskPct,4)+","+r.riskMode+","+D(r.balanceOpen,2)+","+D(r.equityOpen,2)+",";
      o+=D(r.mfePrice,m_digits)+","+D(mfeMon,2)+","+D(mfeR,4)+","+T(r.mfeTime)+",";
      o+=D(r.maePrice,m_digits)+","+D(maeMon,2)+","+D(maeR,4)+","+T(r.maeTime)+",";
      o+=D(mfeBeforeR,4)+","+D(mfeAfterR,4)+","+D(mfeR-netR,4)+","+eff+",";
      o+=D(r.exitPrice,m_digits)+","+ExitReasonName(r.exitReason)+",";
      o+=D(r.grossProfit,2)+","+D(r.commission,2)+","+D(r.swap,2)+","+D(r.netProfit,2)+","+D(netR,4)+",";
      o+=D(r.balanceOpen>0?r.netProfit/r.balanceOpen*100.0:0,4)+",";
      o+=B(r.beArmed)+","+T(r.beTime)+","+B(r.partialTaken)+","+D(r.partialLots,2)+","+D(r.partialMoney,2)+",";
      o+=IntegerToString(r.trailMoves)+","+D(r.finalSL,m_digits)+","+D(r.balanceClose,2)+",";
      o+=CfStateName(r.cfState)+","+cfR;
      return(o);
     }

public:
   void Init(const bool enabled,const bool useCf,const int cfBars,const string symbol)
     {
      m_enabled=enabled; m_useCf=useCf; m_cfBars=cfBars;
      m_symbol=symbol; m_count=0;
      m_digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
      m_point =SymbolInfoDouble(symbol,SYMBOL_POINT);
      ArrayResize(m_rec,0);
      m_file="SessionsStrategy_Trades_"+symbol+".csv";
     }

   int Count() const { return(m_count); }

   //--- Prepare a fresh record when a position opens
   static void Begin(STradeRecord &r)
     {
      r.mfePrice=0; r.maePrice=0; r.mfeTime=0; r.maeTime=0;
      r.mfePriceBeforeBE=0;
      r.beArmed=false; r.beTime=0;
      r.partialTaken=false; r.partialLots=0; r.partialMoney=0;
      r.trailMoves=0; r.finalSL=0;
      r.exitReason=EXIT_UNKNOWN;
      r.grossProfit=0; r.commission=0; r.swap=0; r.netProfit=0;
      r.cfState=CF_NA; r.cfMfePrice=0; r.cfBarsLeft=0;
     }

   //--- Fold one high/low pair into a live record's excursion.
   //    Called per tick with the mark price, and per completed bar with that
   //    bar's true extremes.
   static void Sample(STradeRecord &r,const double hi,const double lo,const datetime t)
     {
      if(r.mfePrice==0){ r.mfePrice=r.entryPrice; r.maePrice=r.entryPrice; }
      if(r.isBuy)
        {
         if(hi>r.mfePrice){ r.mfePrice=hi; r.mfeTime=t; }
         if(lo<r.maePrice){ r.maePrice=lo; r.maeTime=t; }
        }
      else
        {
         if(lo<r.mfePrice){ r.mfePrice=lo; r.mfeTime=t; }
         if(hi>r.maePrice){ r.maePrice=hi; r.maeTime=t; }
        }
      if(!r.beArmed) r.mfePriceBeforeBE=r.mfePrice;
     }

   //--- Take ownership of a finished trade
   void Submit(STradeRecord &r)
     {
      if(!m_enabled) return;
      // Only an EARLY exit poses a counterfactual: a trade that reached its own
      // target or its original stop already answered the question.
      bool early=(r.exitReason==EXIT_BREAK_EVEN || r.exitReason==EXIT_TRAIL_STOP ||
                  r.exitReason==EXIT_CAP        || r.exitReason==EXIT_OPPOSING_CHOCH);
      if(m_useCf && early && r.initialSL>0)
        {
         r.cfState=CF_WATCHING;
         r.cfBarsLeft=m_cfBars;
         r.cfMfePrice=r.exitPrice;
        }
      else
         r.cfState=CF_NA;

      ArrayResize(m_rec,m_count+1);
      m_rec[m_count]=r;
      m_count++;
     }

   //--- Advance every watching counterfactual with a completed bar
   void UpdateCounterfactuals(const double hi,const double lo)
     {
      if(!m_enabled || !m_useCf) return;
      for(int i=0;i<m_count;i++)
        {
         if(m_rec[i].cfState!=CF_WATCHING) continue;
         if(m_rec[i].isBuy)
           {
            if(hi>m_rec[i].cfMfePrice) m_rec[i].cfMfePrice=hi;
            // Both touched inside one bar: no intrabar order is knowable, so
            // assume the stop came first. Biases the answer AGAINST removing
            // the early exit, which is the safe direction to be wrong in.
            if(lo<=m_rec[i].initialSL)                              m_rec[i].cfState=CF_WOULD_LOSE;
            else if(m_rec[i].initialTP>0 && hi>=m_rec[i].initialTP) m_rec[i].cfState=CF_WOULD_WIN;
           }
         else
           {
            if(lo<m_rec[i].cfMfePrice || m_rec[i].cfMfePrice==0) m_rec[i].cfMfePrice=lo;
            if(hi>=m_rec[i].initialSL)                              m_rec[i].cfState=CF_WOULD_LOSE;
            else if(m_rec[i].initialTP>0 && lo<=m_rec[i].initialTP) m_rec[i].cfState=CF_WOULD_WIN;
           }
         if(m_rec[i].cfState==CF_WATCHING && --m_rec[i].cfBarsLeft<=0)
            m_rec[i].cfState=CF_UNRESOLVED;
        }
     }

   //--- Write the whole file, once, in OPEN order
   bool Flush(const SSettings &s)
     {
      if(!m_enabled || m_count<=0) return(false);

      // close order != open order once the counterfactual delays a row;
      // sort so the CSV always reads chronologically by entry
      for(int i=1;i<m_count;i++)
        {
         STradeRecord key=m_rec[i];
         int j=i-1;
         while(j>=0 && m_rec[j].tradeNo>key.tradeNo){ m_rec[j+1]=m_rec[j]; j--; }
         m_rec[j+1]=key;
        }

      int h=FileOpen(m_file,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(h==INVALID_HANDLE)
        {
         PrintFormat("[SS] ANALYTICS: cannot open %s (error %d)",m_file,GetLastError());
         return(false);
        }
      FileWriteString(h,Header()+"\r\n");
      double vpp=ValuePerLotPerPrice();
      int watching=0;
      for(int i=0;i<m_count;i++)
        {
         if(m_rec[i].cfState==CF_WATCHING){ m_rec[i].cfState=CF_UNRESOLVED; watching++; }
         FileWriteString(h,Row(m_rec[i],vpp,s)+"\r\n");
        }
      FileClose(h);
      PrintFormat("[SS] ANALYTICS: wrote %d trades to Common\\Files\\%s%s",
                  m_count,m_file,
                  watching>0?StringFormat(" (%d counterfactuals still open -> UNRESOLVED)",watching):"");
      return(true);
     }
  };

#endif // SESSIONS_STRATEGY_TRADEANALYTICS_MQH
