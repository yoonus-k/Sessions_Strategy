//+------------------------------------------------------------------+
//|                                            SessionsStrategy.mq5   |
//|         Session-based discretionary-bias EA for XAUUSD (M2)       |
//|                                                                   |
//|  Trader arms BUY/SELL/NONE on the panel; EA enforces the charter: |
//|  sessions, timing, sweep, CHoCH/IFVG entry, 0.95% risk, BE at 2%, |
//|  dynamic 4-10% take-profit, and per-session trade caps.           |
//+------------------------------------------------------------------+
#property copyright "Sessions Strategy"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include "Include/Common.mqh"
#include "Include/SessionManager.mqh"
#include "Include/BiasPanel.mqh"
#include "Include/Liquidity.mqh"
#include "Include/EntryModels.mqh"
#include "Include/RiskManager.mqh"
#include "Include/DynamicTP.mqh"
#include "Include/TradeJournal.mqh"
#include "Include/Visuals.mqh"
#include "Include/Dashboard.mqh"

//--- Inputs --------------------------------------------------------
input group "General"
input ENUM_TIMEFRAMES InpTF                 = PERIOD_M2;   // Working timeframe
input long            InpMagic              = 920001;      // Magic number
input ENUM_BIAS       InpForcedBias         = BIAS_NONE;   // Forced bias (backtest only; NONE = use panel)

input group "Timezone / Sessions (Riyadh local time)"
input double          InpBrokerToRiyadhHr   = 0.0;         // Server -> Riyadh offset (hours)
input string          InpAsiaStart          = "03:00";     // Asia session start
input string          InpAsiaEnd            = "06:00";     // Asia session end
input string          InpNYStart            = "15:00";     // NY session start
input string          InpNYEnd              = "18:00";     // NY session end
input int             InpEntryWindowMinutes = 90;          // Entry window from open (min)

input group "Asia prior-day range (rule 2)"
input int             InpDayCloseHour       = 0;           // Day-close hour (Riyadh)
input int             InpRangeLengthHours   = 4;           // Range length (hours)

input group "Structure / Entry"
input int             InpSwingStrength      = 2;           // Swing strength (N) for sweep-target swings
input int             InpChochSwing         = 1;           // Swing strength (N) for the CHoCH reaction high/low
input ENUM_ENTRY_MODEL InpEntryModel        = ENTRY_EITHER; // Entry: CHoCH or IFVG, whichever fires first
input double          InpChochRetrace       = 0.25;        // CHoCH limit retrace of breaking leg (0..1)
input double          InpPreSweepHours      = 8.0;         // Look this many hours left of session open for the low/high to sweep
input int             InpChochTimeoutBars   = 3;           // CHoCH limit: bars to wait for fill, then market fallback (0=off)

input group "Risk"
input double          InpRiskPercent        = 0.95;        // Risk per trade (% capital)
input ENUM_SL_ANCHOR  InpSLAnchor           = SL_ANCHOR_CHOCH_LEG; // SL anchor (CHoCH leg extreme / sweep wick)
input double          InpSLBufferPoints     = 0;           // SL pad beyond wick (points)
input double          InpBreakEvenAtPercent = 2.0;         // Move SL to BE at (%)

input group "Targets"
input double          InpDefaultTargetPct   = 4.0;         // Default target (%)
input double          InpMaxTargetPct       = 10.0;        // Hard cap (%)
input bool            InpUsePartialTP       = true;        // Partial close at default target
input double          InpPartialPercent     = 50.0;        // Partial size (%)

input group "Momentum runner"
input double          InpMomentumBodyATR    = 1.3;         // Displacement (body >= x*ATR)
input int             InpMomentumStallBars  = 3;           // Stall / progress window (bars)
input double          InpAtrContractionFac  = 0.6;         // Exhaustion (ATR < x*ATR@entry)
input double          InpTrailPadPoints     = 0;           // Structure-trail pad (points)

input group "Session caps"
input int             InpMaxTradesPerSession= 2;           // Max trades per session
input bool            InpStopAfterFirstWin  = true;        // Stop after first win
input bool            InpTradeMonday        = true;        // Allow trading on Monday
input bool            InpTradeFriday        = true;        // Allow trading on Friday

input group "Logging"
input bool            InpWriteJournal       = true;        // Write CSV journal
input bool            InpDebug              = false;       // Print per-bar detection trace to Experts log

input group "Visuals"
input bool            InpShowVisuals        = true;        // Draw range/session boxes
input color           InpColorRange         = clrGoldenrod;// Prev-day 4H range
input color           InpColorAsia          = clrDodgerBlue;// Asia session range
input color           InpColorNY            = clrTomato;   // NY session range
input bool            InpShowSignals        = true;        // Draw sweep / CHoCH / IFVG / trades
input color           InpColorChoch         = clrAqua;     // CHoCH leg & levels
input color           InpColorIfvg          = clrMediumOrchid;// IFVG zone
input color           InpColorSweep         = clrKhaki;    // Swept liquidity level
input bool            InpShowSwings         = true;        // Draw detected swing highs/lows
input color           InpColorSwingHi       = clrTomato;   // Swing-high dots
input color           InpColorSwingLo       = clrLimeGreen;// Swing-low dots
input int             InpSwingDrawLookback  = 300;         // Swing draw lookback (bars)
input bool            InpShowFVGs           = true;        // Draw live FVG / IFVG zones
input color           InpColorFvg           = clrSlateGray;// Non-inverted FVG zone
input int             InpMaxFVGs            = 8;           // Max live FVG zones shown
input bool            InpShowDashboard      = true;        // Show status dashboard

//--- Globals -------------------------------------------------------
SSettings        g_s;
CSessionManager  g_session;
CBiasPanel       g_panel;
CLiquidity       g_liq;
CEntryModels     g_entry;
CRiskManager     g_risk;
CDynamicTP       g_dtp;
CTradeJournal    g_journal;
CVisuals         g_visuals;
CDashboard       g_dash;
CTrade           g_trade;

SStratState      g_state;
datetime         g_lastBar=0;
ulong            g_openTicket=0;      // position ticket
long             g_openPositionId=0;  // position identifier (for history)
ulong            g_pendingTicket=0;   // working CHoCH limit order
string           g_pendingModel="";
datetime         g_pendingPlacedBar=0;// bar the limit was placed on (for the market fallback)
string           g_openSession="";
string           g_openBias="";
string           g_openModel="";      // entry model of the open trade (report)
string           g_openDay="";        // Riyadh week-day the trade opened on
double           g_openLots=0;
string           g_lastSessionKey="";

//+------------------------------------------------------------------+
int ParseHM(const string hm)
  {
   string parts[]; int k=StringSplit(hm,':',parts);
   if(k<2) return(0);
   return((int)StringToInteger(parts[0])*60+(int)StringToInteger(parts[1]));
  }

//+------------------------------------------------------------------+
void BuildSettings()
  {
   g_s.tf                    =InpTF;
   g_s.magic                 =InpMagic;
   g_s.brokerToRiyadhOffsetHr=InpBrokerToRiyadhHr;
   g_s.asiaStartMin          =ParseHM(InpAsiaStart);
   g_s.asiaEndMin            =ParseHM(InpAsiaEnd);
   g_s.nyStartMin            =ParseHM(InpNYStart);
   g_s.nyEndMin              =ParseHM(InpNYEnd);
   g_s.dayCloseHourRiyadh    =InpDayCloseHour;
   g_s.rangeLengthHours      =InpRangeLengthHours;
   g_s.entryWindowMinutes    =InpEntryWindowMinutes;
   g_s.swingStrength         =InpSwingStrength;
   g_s.chochSwing            =InpChochSwing;
   g_s.entryModel            =InpEntryModel;
   g_s.chochEntryRetrace     =InpChochRetrace;
   g_s.preSweepHours         =InpPreSweepHours;
   g_s.riskPercent           =InpRiskPercent;
   g_s.slAnchor              =InpSLAnchor;
   g_s.slBufferPoints        =InpSLBufferPoints;
   g_s.breakEvenAtPercent    =InpBreakEvenAtPercent;
   g_s.defaultTargetPercent  =InpDefaultTargetPct;
   g_s.maxTargetPercent      =InpMaxTargetPct;
   g_s.usePartialTP          =InpUsePartialTP;
   g_s.partialPercent        =InpPartialPercent;
   g_s.momentumBodyATR       =InpMomentumBodyATR;
   g_s.momentumStallBars     =InpMomentumStallBars;
   g_s.atrContractionFactor  =InpAtrContractionFac;
   g_s.trailPadPoints        =InpTrailPadPoints;
   g_s.maxTradesPerSession   =InpMaxTradesPerSession;
   g_s.stopAfterFirstWin     =InpStopAfterFirstWin;
   g_s.tradeMonday           =InpTradeMonday;
   g_s.tradeFriday           =InpTradeFriday;
   g_s.writeJournal          =InpWriteJournal;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   BuildSettings();
   string sym=_Symbol;
   g_session.Init(g_s,sym);
   g_panel.Init(ChartID());
   g_liq.Init(g_s,sym);
   g_entry.Init(g_s,sym);
   g_risk.Init(g_s,sym);
   g_dtp.Init(g_s,sym);
   g_journal.Init(g_s.writeJournal,sym);
   g_visuals.Init(ChartID(),InpShowVisuals,InpColorRange,InpColorAsia,InpColorNY);
   g_visuals.InitSignals(InpShowSignals,InpColorChoch,InpColorIfvg,InpColorSweep);
   g_visuals.InitSwings(InpShowSwings,InpColorSwingHi,InpColorSwingLo);
   g_visuals.SetFvgColor(InpColorFvg);
   g_dash.Init(ChartID(),sym);

   // backtest convenience: arm a fixed bias without clicking the panel
   if(InpForcedBias!=BIAS_NONE) g_panel.SetBias(InpForcedBias);

   g_trade.SetExpertMagicNumber(g_s.magic);
   g_trade.SetTypeFillingBySymbol(sym);
   g_trade.SetDeviationInPoints(20);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_panel.Destroy();
   g_visuals.Destroy();
   g_dash.Destroy();
   g_dtp.Deinit();
  }

//+------------------------------------------------------------------+
//| Refresh the cheap live fields + redraw the dashboard immediately  |
//| (so bias/session update instantly, even while the tester is paused)|
//+------------------------------------------------------------------+
void RefreshDashboardLive()
  {
   datetime now=TimeCurrent();
   g_state.bias        =g_panel.Bias();
   g_state.session     =g_session.CurrentSession(now);
   g_state.inWindow    =g_session.InEntryWindow(now);
   g_state.positionOpen=(g_openTicket!=0);
   g_state.pending     =(g_pendingTicket!=0);
   if(g_state.positionOpen && PositionSelectByTicket(g_openTicket))
      g_state.floatPct=g_risk.FloatPercent(PositionGetDouble(POSITION_PROFIT));
   // keep day / max-trades live every tick
   MqlDateTime _drl; TimeToStruct(ToRiyadh(now,g_s),_drl);
   g_state.dayAllowed=!(_drl.day_of_week==1 && !g_s.tradeMonday) &&
                      !(_drl.day_of_week==5 && !g_s.tradeFriday);
   g_state.maxTrades =g_s.maxTradesPerSession;
   if(g_state.bias==BIAS_NONE)
      g_state.note="arm a bias (BUY/SELL)";
   else if(!g_state.dayAllowed)
      g_state.note=(_drl.day_of_week==1)?"Monday trading disabled":"Friday trading disabled";
   else if(g_state.session==SESSION_NONE)
      g_state.note="armed - out of session";
   else if(g_state.note=="arm a bias (BUY/SELL)" ||
           g_state.note=="Monday trading disabled" ||
           g_state.note=="Friday trading disabled")
      g_state.note="armed - evaluating on bar close";
   if(InpShowDashboard) g_dash.Update(g_state);
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   ENUM_BIAS prev=g_panel.Bias();
   if(g_panel.OnChartEvent(id,sparam))
     {
      if(g_panel.Bias()!=prev) g_liq.Reset(); // new bias -> fresh sweep
      RefreshDashboardLive();                 // reflect the click at once
     }
  }

//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t=iTime(_Symbol,g_s.tf,0);
   if(t!=g_lastBar){ g_lastBar=t; return(true); }
   return(false);
  }

//+------------------------------------------------------------------+
//| Detect a closed position, register result, journal it            |
//+------------------------------------------------------------------+
void CheckClosedPosition()
  {
   if(g_openTicket==0) return;
   if(PositionSelectByTicket(g_openTicket)) return; // still open

   // gather realized P/L from history
   double total=0; datetime closeTime=TimeCurrent(); double exit=0;
   if(HistorySelectByPosition(g_openPositionId))
     {
      int deals=HistoryDealsTotal();
      for(int i=0;i<deals;i++)
        {
         ulong d=HistoryDealGetTicket(i);
         total+=HistoryDealGetDouble(d,DEAL_PROFIT)
               +HistoryDealGetDouble(d,DEAL_SWAP)
               +HistoryDealGetDouble(d,DEAL_COMMISSION);
         if(HistoryDealGetInteger(d,DEAL_ENTRY)==DEAL_ENTRY_OUT)
           {
            closeTime=(datetime)HistoryDealGetInteger(d,DEAL_TIME);
            exit     =HistoryDealGetDouble(d,DEAL_PRICE);
           }
        }
     }
   bool win=(total>0);
   g_risk.RegisterClose(win);
   g_journal.LogTrade(g_openDay,closeTime,g_openSession,g_openBias,g_openModel,
                      g_openLots,total,AccountInfoDouble(ACCOUNT_BALANCE));
   PrintFormat("[SS] POSITION CLOSED: %I64u exit %.2f, P/L %.2f (%.2f%%) -> %s",
               g_openTicket,exit,total,g_risk.FloatPercent(total),win?"WIN":"LOSS");

   g_openTicket=0; g_openPositionId=0;
   g_dtp.Clear();
  }

//+------------------------------------------------------------------+
//| Bookkeeping once a position is confirmed open (market or fill)    |
//+------------------------------------------------------------------+
void OnPositionOpened(const ulong posTicket,const string model)
  {
   if(!PositionSelectByTicket(posTicket))
     {
      PrintFormat("[SS] WARNING: position %I64u not found after open - tracking failed",posTicket);
      return;
     }
   g_openTicket    =posTicket;
   g_openPositionId=(long)PositionGetInteger(POSITION_IDENTIFIER);
   bool   isBuy=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
   double entry=PositionGetDouble(POSITION_PRICE_OPEN);
   double lots =PositionGetDouble(POSITION_VOLUME);
   double sl   =PositionGetDouble(POSITION_SL);
   datetime now=TimeCurrent();
   ENUM_SESSION ses=g_session.CurrentSession(now);
   g_openSession=(ses==SESSION_ASIA)?"ASIA":(ses==SESSION_NY)?"NY":"-";
   g_openBias   =isBuy?"BUY":"SELL";
   g_openModel  =model;
   g_openDay    =DayOfWeekName(ToRiyadh(now,g_s)); // same day base as the Mon/Fri filter
   g_openLots   =lots;

   g_risk.RegisterOpen();
   g_dtp.OnNewTrade(g_openTicket,isBuy,entry);

   double tp=PositionGetDouble(POSITION_TP);
   g_visuals.DrawTrade(TimeToString(now,TIME_DATE|TIME_MINUTES)+"_"+(string)posTicket,
                       isBuy,entry,sl,tp,now);

   PrintFormat("[SS] POSITION OPENED: %s %s %.2f lots @ %.2f, SL %.2f, TP %.2f (model %s, session %s)",
               g_openBias,_Symbol,lots,entry,sl,tp,model,g_openSession);
   Alert(StringFormat("SS: OPENED %s %.2f lots @ %.2f, SL %.2f (%s)",
                      g_openBias,lots,entry,sl,model));

   g_liq.Reset(); // next trade needs a fresh sweep
  }

//+------------------------------------------------------------------+
//| Watch the working CHoCH limit: cancel on timeout, detect fill    |
//+------------------------------------------------------------------+
void ManagePending()
  {
   if(g_pendingTicket==0) return;
   datetime now=TimeCurrent();

   if(OrderSelect(g_pendingTicket))                 // still working
     {
      ENUM_BIAS bias=g_panel.Bias();
      bool wantBuy=(OrderGetInteger(ORDER_TYPE)==ORDER_TYPE_BUY_LIMIT);
      bool biasOK =(wantBuy && bias==BIAS_BUY) || (!wantBuy && bias==BIAS_SELL);
      // rule 3: no fill allowed past the entry window; also drop if bias changed
      if(!g_session.InEntryWindow(now) || !biasOK)
        {
         PrintFormat("[SS] LIMIT %I64u CANCELLED: %s (never filled)",
                     g_pendingTicket,!biasOK?"bias changed":"entry window closed");
         g_trade.OrderDelete(g_pendingTicket);
         g_pendingTicket=0; g_pendingModel=""; g_pendingPlacedBar=0;
         return;
        }
      // momentum fallback: still unfilled after N bars means price never
      // pulled back to the retrace level (displacement move) -> chase it
      // with a MARKET entry using the same SL anchor, resized to the risk %
      if(InpChochTimeoutBars>0 && g_pendingPlacedBar>0)
        {
         int elapsed=(int)((iTime(_Symbol,g_s.tf,0)-g_pendingPlacedBar)/PeriodSeconds(g_s.tf));
         if(elapsed>=InpChochTimeoutBars)
           {
            double sl=OrderGetDouble(ORDER_SL);
            string model=g_pendingModel;
            PrintFormat("[SS] LIMIT %I64u NOT FILLED after %d bars (no pullback) -> switching to MARKET entry",
                        g_pendingTicket,elapsed);
            g_trade.OrderDelete(g_pendingTicket);
            g_pendingTicket=0; g_pendingModel=""; g_pendingPlacedBar=0;
            OpenMarket(wantBuy,sl,model);
           }
        }
      return;
     }

   // no longer a working order -> filled or removed
   if(PositionSelectByTicket(g_pendingTicket))
      OnPositionOpened(g_pendingTicket,g_pendingModel);
   else
     {
      // fallback: locate our freshly opened position
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong t=PositionGetTicket(i);
         if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC)==g_s.magic)
           { OnPositionOpened(t,g_pendingModel); break; }
        }
     }
   g_pendingTicket=0; g_pendingModel=""; g_pendingPlacedBar=0;
  }

//+------------------------------------------------------------------+
//| Extreme of the bars from 'fromT' to now (lowest low for a buy,    |
//| highest high for a sell) — the local leg that produced the entry. |
//+------------------------------------------------------------------+
double LegExtremeSince(const datetime fromT,const bool isBuy)
  {
   MqlRates r[];
   int n=CopyRates(_Symbol,g_s.tf,fromT,TimeCurrent(),r);
   if(n<=0) return(0);
   double ext=isBuy?DBL_MAX:-DBL_MAX;
   for(int i=0;i<n;i++)
     {
      if(isBuy){ if(r[i].low <ext) ext=r[i].low;  }
      else     { if(r[i].high>ext) ext=r[i].high; }
     }
   if(isBuy)  return(ext<DBL_MAX ?ext:0);
   return(ext>-DBL_MAX?ext:0);
  }

//+------------------------------------------------------------------+
//| Market entry with a given SL: clamp, size, send, register.        |
//| Prints an English journal line on success or failure.             |
//+------------------------------------------------------------------+
bool OpenMarket(const bool isBuy,double sl,const string model)
  {
   double bid  =SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask  =SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double minDist=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*point;
   double entry=isBuy?ask:bid;

   if(isBuy && entry-sl<minDist) sl=entry-minDist;
   if(!isBuy&& sl-entry<minDist) sl=entry+minDist;
   if((isBuy && sl>=entry) || (!isBuy && sl<=entry))
     {
      PrintFormat("[SS] MARKET SKIPPED (%s %s): invalid SL %.2f vs entry %.2f",
                  model,isBuy?"BUY":"SELL",sl,entry);
      return(false);
     }

   double lots=g_risk.LotForRisk(entry,sl);
   if(lots<=0)
     {
      PrintFormat("[SS] MARKET SKIPPED (%s %s): lot size = 0 (SL distance %.2f)",
                  model,isBuy?"BUY":"SELL",MathAbs(entry-sl));
      return(false);
     }
   double tp=g_risk.PriceForPercent(g_s.maxTargetPercent,lots,isBuy,entry);

   bool ok=isBuy ? g_trade.Buy (lots,_Symbol,entry,sl,tp,"SS "+model)
                 : g_trade.Sell(lots,_Symbol,entry,sl,tp,"SS "+model);
   if(!ok)
     {
      PrintFormat("[SS] MARKET %s FAILED (%s): retcode=%d %s",
                  isBuy?"BUY":"SELL",model,
                  g_trade.ResultRetcode(),g_trade.ResultRetcodeDescription());
      Alert(StringFormat("SS: MARKET %s FAILED - %s",
                         isBuy?"BUY":"SELL",g_trade.ResultRetcodeDescription()));
      return(false);
     }
   ulong deal=g_trade.ResultDeal();
   long posId=0;
   if(HistoryDealSelect(deal)) posId=(long)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
   OnPositionOpened((ulong)posId,model);
   return(true);
  }

//+------------------------------------------------------------------+
//| Build & send the order for a confirmed signal                    |
//+------------------------------------------------------------------+
void PlaceOrder(const ENUM_BIAS bias,SEntrySignal &sig)
  {
   bool   isBuy =(bias==BIAS_BUY);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double point =SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double buf   =g_s.slBufferPoints*point;
   // SL anchor: the extreme of the ENTRY PATTERN's own leg, not the session
   // extreme — a session-open spike can sit far away from the actual setup.
   //  CHoCH -> breaking-leg extreme; IFVG -> extreme of the reclaim leg
   //  (since the zone formed). SWEEP_WICK mode keeps the session extreme.
   double anchor=g_liq.SweepExtreme();
   if(g_s.slAnchor==SL_ANCHOR_CHOCH_LEG)
     {
      if(sig.model=="CHoCH")
         anchor=isBuy?sig.legLo:sig.legHi;
      else if(sig.model=="IFVG" && sig.zoneTime>0)
        {
         double ext=LegExtremeSince(sig.zoneTime,isBuy);
         if(ext>0) anchor=ext;
        }
     }
   double sl    =isBuy?anchor-buf:anchor+buf;
   long   stopsLvl=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minDist =stopsLvl*point;

   bool   useLimit=sig.useLimit;
   double entry=0;
   if(useLimit)
     {
      entry=sig.price;
      if(isBuy && entry>=ask) useLimit=false; // price already past retrace -> market
      if(!isBuy&& entry<=bid) useLimit=false;
      if(!useLimit)
         PrintFormat("[SS] %s: price already beyond the retrace level %.2f -> MARKET entry",
                     sig.model,sig.price);
     }
   if(!useLimit){ OpenMarket(isBuy,sl,sig.model); return; }

   if(isBuy && ask-entry<minDist) entry=ask-minDist;
   if(!isBuy&& entry-bid<minDist) entry=bid+minDist;
   if(isBuy && entry-sl<minDist) sl=entry-minDist;
   if(!isBuy&& sl-entry<minDist) sl=entry+minDist;
   if((isBuy && sl>=entry) || (!isBuy && sl<=entry))
     {
      PrintFormat("[SS] LIMIT SKIPPED (%s %s): invalid SL %.2f vs entry %.2f",
                  sig.model,isBuy?"BUY":"SELL",sl,entry);
      return;
     }

   double lots=g_risk.LotForRisk(entry,sl);
   if(lots<=0)
     {
      PrintFormat("[SS] LIMIT SKIPPED (%s %s): lot size = 0 (SL distance %.2f)",
                  sig.model,isBuy?"BUY":"SELL",MathAbs(entry-sl));
      return;
     }
   double tp=g_risk.PriceForPercent(g_s.maxTargetPercent,lots,isBuy,entry);

   bool ok=isBuy
           ? g_trade.BuyLimit (lots,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,"SS "+sig.model)
           : g_trade.SellLimit(lots,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,"SS "+sig.model);
   if(!ok)
     {
      PrintFormat("[SS] LIMIT %s FAILED (%s): retcode=%d %s",
                  isBuy?"BUY":"SELL",sig.model,
                  g_trade.ResultRetcode(),g_trade.ResultRetcodeDescription());
      Alert(StringFormat("SS: LIMIT %s FAILED - %s",
                         isBuy?"BUY":"SELL",g_trade.ResultRetcodeDescription()));
      return;
     }
   g_pendingTicket=g_trade.ResultOrder();
   g_pendingModel =sig.model;
   g_pendingPlacedBar=iTime(_Symbol,g_s.tf,0);
   PrintFormat("[SS] %s %s LIMIT PLACED @ %.2f (SL %.2f, %.2f lots) - waiting for pullback fill",
               sig.model,isBuy?"BUY":"SELL",entry,sl,lots);
  }

//+------------------------------------------------------------------+
//| Evaluate every condition each bar, fill state, act when valid    |
//+------------------------------------------------------------------+
void EvaluateAndAct(const datetime now)
  {
   SStratState st;
   st.bias=g_panel.Bias();
   st.session=g_session.CurrentSession(now);
   st.inWindow=g_session.InEntryWindow(now);
   st.rangeValid=g_session.RangeValid();
   st.rangeHi=g_session.RangeHigh(); st.rangeLo=g_session.RangeLow();
   st.rangeExited=false; st.swept=false; st.sweptLevel=0; st.sweepWick=0;
   st.entryMet=false; st.entryModel=""; st.entryPrice=0; st.entryIsLimit=false;
   st.positionOpen=(g_openTicket!=0); st.pending=(g_pendingTicket!=0);
   st.floatPct=0; st.note="";

   string sk=g_session.SessionKey(now); // session change handled in OnTick
   g_risk.SyncSession(sk);
   st.trades=g_risk.Trades(); st.wins=g_risk.Wins(); st.canOpen=g_risk.CanOpen();
   st.maxTrades=g_s.maxTradesPerSession;
   MqlDateTime _dtw; TimeToStruct(ToRiyadh(now,g_s),_dtw);
   st.dayAllowed=!(_dtw.day_of_week==1 && !g_s.tradeMonday) &&
                 !(_dtw.day_of_week==5 && !g_s.tradeFriday);
   string dayDisabledNote=(_dtw.day_of_week==1 && !g_s.tradeMonday)?"Monday trading disabled":
                          (_dtw.day_of_week==5 && !g_s.tradeFriday)?"Friday trading disabled":"";

   if(st.positionOpen && PositionSelectByTicket(g_openTicket))
      st.floatPct=g_risk.FloatPercent(PositionGetDouble(POSITION_PROFIT));

   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

   // bound ALL detection to bars from the session open onward
   datetime ss=(st.session!=SESSION_NONE)?g_session.SessionStartServer(now):0;
   g_entry.SetWindow(ss);

   if(st.session==SESSION_ASIA && st.rangeValid)
      st.rangeExited=g_session.AsiaRangeExited(ss);

   // sweep + entry evaluated whenever armed & in session (for the dashboard),
   // independent of the entry window
   SEntrySignal sig; bool haveSig=false;
   if(st.bias!=BIAS_NONE && st.session!=SESSION_NONE)
     {
      g_liq.Update(st.bias,ss);
      st.swept=g_liq.Swept(); st.sweptLevel=g_liq.SweptLevel(); st.sweepWick=g_liq.SweepExtreme();
      if(st.swept)
        {
         haveSig=g_entry.CheckEntry(st.bias,sig);
         st.entryMet=haveSig;
         if(haveSig)
           { st.entryModel=sig.model; st.entryIsLimit=sig.useLimit; st.entryPrice=sig.useLimit?sig.price:bid; }
        }
     }

   // draw the detected pattern even before we act
   if(haveSig)
     {
      string sigKey=TimeToString(now,TIME_DATE|TIME_MINUTES);
      if(sig.model=="CHoCH")
         g_visuals.DrawChoch(sigKey,st.bias==BIAS_BUY,sig.legLoTime,sig.legLo,
                             sig.legHiTime,sig.legHi,sig.structTime,sig.structLevel,sig.price,now);
      else
         g_visuals.DrawIFVG(sigKey,sig.zoneTime,now,sig.zoneLo,sig.zoneHi);
     }

   bool gateAsia=(st.session!=SESSION_ASIA) || (st.rangeValid && st.rangeExited);
   bool canAttempt = st.bias!=BIAS_NONE && st.session!=SESSION_NONE && st.inWindow
                     && g_openTicket==0 && g_pendingTicket==0 && st.canOpen && gateAsia && st.dayAllowed;

   if(canAttempt && st.swept && haveSig)
     {
      PlaceOrder(st.bias,sig);
      st.note="ORDER SENT: "+sig.model;
      st.pending=(g_pendingTicket!=0);
      st.positionOpen=(g_openTicket!=0);
     }
   else
     {
      if(st.bias==BIAS_NONE)                                  st.note="arm a bias (BUY/SELL)";
      else if(st.positionOpen)                               st.note="managing position";
      else if(st.pending)                                    st.note="limit pending";
      else if(st.session==SESSION_NONE)                      st.note="out of session";
      else if(!st.canOpen)                                   st.note="session cap reached";
      else if(!st.dayAllowed)                                st.note=dayDisabledNote;
      else if(st.session==SESSION_ASIA && !st.rangeValid)    st.note="Asia 4H range n/a";
      else if(st.session==SESSION_ASIA && !st.rangeExited)   st.note="Asia: range not exited yet";
      else if(!st.inWindow)                                  st.note="entry window closed";
      else if(!st.swept)                                     st.note="waiting liquidity sweep";
      else if(!haveSig)                                      st.note="waiting CHoCH/IFVG";
     }

   g_state=st;

   if(InpDebug && st.session!=SESSION_NONE && st.bias!=BIAS_NONE)
      PrintFormat("[SS %s] bias=%s swept=%s tgt=%.2f wick=%.2f entry=%s(%s@%.2f) win=%s canOpen=%s pos=%s -> %s",
                  TimeToString(now,TIME_MINUTES),
                  (st.bias==BIAS_BUY?"BUY":"SELL"),
                  (st.swept?"Y":"n"),g_liq.TargetLevel(),g_liq.SweepExtreme(),
                  (st.entryMet?"MET":"no"),st.entryModel,st.entryPrice,
                  (st.inWindow?"Y":"n"),(st.canOpen?"Y":"n"),
                  (st.positionOpen?"Y":"n"),st.note);
  }

//+------------------------------------------------------------------+
//| Live 4H range box during its build window (e.g. 20:00 -> 00:00).   |
//| Drawn the moment the window opens, anchored at the start, develops |
//| to 'now', and is NOT wiped — it stays for the next Asia session    |
//| (which shares the same object key). Runs outside any session.      |
//+------------------------------------------------------------------+
void UpdateRangeBox(const datetime now)
  {
   if(!InpShowVisuals) return;
   datetime ws,we;
   if(!g_session.RangeWindow(now,ws,we)) return; // only inside 20:00->00:00
   MqlRates r[]; int n=CopyRates(_Symbol,g_s.tf,ws,now,r);
   if(n<=0) return;
   double hi=-DBL_MAX,lo=DBL_MAX;
   for(int i=0;i<n;i++){ if(r[i].high>hi) hi=r[i].high; if(r[i].low<lo) lo=r[i].low; }
   // endSrv=we (close) sets the object key; right edge develops to 'now'
   g_visuals.DrawPriorRange(ws,we,now,hi,lo);
  }

//+------------------------------------------------------------------+
//| Draw / update the prior-day range and active session boxes        |
//+------------------------------------------------------------------+
void UpdateVisuals(const datetime now)
  {
   // nothing is drawn outside an active session
   ENUM_SESSION ses=g_session.CurrentSession(now);
   if(ses==SESSION_NONE) return;
   datetime ss=g_session.SessionStartServer(now);

   // prior-day last-4h range (rule 2) — Asia reference
   if(ses==SESSION_ASIA && g_session.RangeValid())
     {
      datetime proj=g_session.SessionEndServer(now);
      if(proj<=0) proj=now+6*3600;
      g_visuals.DrawPriorRange(g_session.RangeStartSrv(),g_session.RangeEndSrv(),
                               proj,g_session.RangeHigh(),g_session.RangeLow());
     }

   // the single marked low/high to be swept (trails to newest; turns
   // "SWEPT" once price takes it)
   ENUM_BIAS bias=g_panel.Bias();
   if(bias!=BIAS_NONE && g_liq.TargetLevel()>0)
     {
      datetime fromT=(g_liq.TargetTime()>0)?g_liq.TargetTime():ss;
      g_visuals.DrawSweepTarget(bias==BIAS_BUY,g_liq.TargetLevel(),fromT,now,g_liq.Swept());
     }

   // developing box for the active session
   MqlRates r[];
   int n=CopyRates(_Symbol,g_s.tf,ss,now,r);
   if(n<=0) return;
   double hi=-DBL_MAX,lo=DBL_MAX;
   for(int i=0;i<n;i++){ if(r[i].high>hi) hi=r[i].high; if(r[i].low<lo) lo=r[i].low; }
   g_visuals.DrawSessionBox(ses,ss,now,hi,lo);
  }

//+------------------------------------------------------------------+
//| Mark detected swing highs/lows (the structure skeleton)          |
//+------------------------------------------------------------------+
void UpdateSwings(const datetime fromTime)
  {
   if(!InpShowSwings || fromTime<=0) return;
   int N=g_s.swingStrength;
   MqlRates r[]; ArraySetAsSeries(r,true);
   int n=CopyRates(_Symbol,g_s.tf,fromTime,TimeCurrent(),r); // session bars only
   if(n<2*N+2) return;
   for(int i=N;i<n-N;i++)
     {
      if(IsSwingHigh(r,n,i,N)) g_visuals.DrawSwing(r[i].time,r[i].high,true);
      if(IsSwingLow (r,n,i,N)) g_visuals.DrawSwing(r[i].time,r[i].low, false);
     }
  }

//+------------------------------------------------------------------+
//| Draw live FVG / IFVG zones + the CHoCH watch level               |
//+------------------------------------------------------------------+
void UpdateLivePatterns(const datetime now)
  {
   if(InpShowFVGs)
     {
      // draw only the NEWEST fvg/ifvg (index 0 = most recent), ignore older ones
      SFvg fv[]; ArrayResize(fv,4);
      int c=g_entry.CollectFVGs(fv,4,120);
      if(c>0) g_visuals.DrawFVG(0,fv[0].t,now,fv[0].lo,fv[0].hi,fv[0].inverted,fv[0].bullish);
      g_visuals.ClearFVGs(1,InpMaxFVGs);
     }

   ENUM_BIAS bias=g_panel.Bias();
   if(bias!=BIAS_NONE)
     {
      double lvl; datetime t;
      if(g_entry.WatchLevel(bias,lvl,t))
         g_visuals.DrawWatch(bias==BIAS_BUY,lvl,(t>0?t:now),now);
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   datetime now=TimeCurrent();

   // poll the bias buttons every tick — this is what makes the panel work
   // in the Strategy Tester (OnChartEvent is not called there)
   if(g_panel.PollClicks())
      g_liq.Reset();                 // new bias -> fresh sweep

   // session boundary (entering OR leaving a session): wipe this session's
   // drawings immediately - sweep target, CHoCH/IFVG, swings, session box,
   // trade levels, and the Prior-Day 4H range card. The range card is
   // rebuilt from scratch during the next 20:00->00:00 window. Reset the
   // sweep state either way.
   string sk=g_session.SessionKey(now);
   if(sk!=g_lastSessionKey)
     {
      g_visuals.ClearSessionDrawings();
      g_liq.Reset();
      g_lastSessionKey=sk;
     }

   g_session.ComputeRangeIfNeeded(now);

   // manage any open position every tick (BE, runner, caps)
   if(g_openTicket!=0)
      g_dtp.Manage(g_trade,g_risk,g_entry);

   CheckClosedPosition();
   ManagePending();   // detect CHoCH limit fills / cancel on timeout

   // bar-close work
   if(IsNewBar())
     {
      // live 4H range box during its 20:00->00:00 window (outside sessions);
      // it persists and the Asia session reuses the same object key
      UpdateRangeBox(now);

      // While a trade or pending order is live, do NOT run detection or draw
      // new setups — just manage the open position (rule 14 focus).
      if(g_openTicket!=0 || g_pendingTicket!=0)
        {
         g_state.note=(g_openTicket!=0)?"managing position":"limit pending";
        }
      else
        {
         EvaluateAndAct(now);
         UpdateVisuals(now);

         ENUM_SESSION ses=g_session.CurrentSession(now);
         if(ses!=SESSION_NONE)
           {
            datetime ss=g_session.SessionStartServer(now);
            UpdateSwings(ss);
            UpdateLivePatterns(now);
           }
         else
            g_visuals.ClearFVGs(0,InpMaxFVGs); // wipe stale patterns out of session
        }
     }

   RefreshDashboardLive(); // keep bias/session/position live every tick
  }
//+------------------------------------------------------------------+
