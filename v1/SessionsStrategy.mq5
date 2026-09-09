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
#include "Include/Vwap.mqh"
#include "Include/EntryModels.mqh"
#include "Include/RiskManager.mqh"
#include "Include/DynamicTP.mqh"
#include "Include/TradeJournal.mqh"
#include "Include/TradeAnalytics.mqh"
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
input bool            InpUseLondon          = false;       // Enable the London session
input string          InpLondonStart        = "09:00";     // London session start
input string          InpLondonEnd          = "12:00";     // London session end
input string          InpNYStart            = "15:00";     // NY session start
input string          InpNYEnd              = "18:00";     // NY session end
input int             InpEntryWindowMinutes = 30;          // Entry window from open (min)

input group "Bias source (VWAP auto-bias)"
input ENUM_BIAS_MODE   InpBiasMode          = BIAS_MODE_VWAP;  // Bias source: manual panel / VWAP at session open
input ENUM_VWAP_ANCHOR InpVwapAnchor        = VWAP_ANCHOR_DAY; // VWAP anchor period (Pine "Session" = day)
input ENUM_VWAP_SOURCE InpVwapSource        = VWAP_SRC_HLC3;   // VWAP price source (Pine default hlc3)
input bool             InpShowVwap          = true;            // Draw the VWAP curve
input color            InpColorVwap         = C'41,98,255';    // VWAP colour (TradingView #2962FF)
input int              InpVwapDrawBars      = 400;             // Max VWAP segments drawn

input group "Asia prior-day range (rule 2)"
input int             InpDayCloseHour       = 0;           // Day-close hour (Riyadh)
input int             InpRangeLengthHours   = 4;           // Range length (hours)

input group "Structure / Entry"
input int             InpSwingStrength      = 2;           // Swing strength (N) for sweep-target swings
input int             InpChochSwing         = 1;           // Swing strength (N) for the CHoCH reaction high/low
input ENUM_ENTRY_MODEL InpEntryModel        = ENTRY_EITHER; // Entry: CHoCH or IFVG, whichever fires first
input double          InpChochRetrace       = 0.25;        // CHoCH limit retrace of breaking leg (0..1)
input double          InpPreSweepHours      = 8.0;         // Look this many hours left of session open for the low/high to sweep
input double          InpDetectPreHours     = 2.0;         // CHoCH/IFVG structure sees this many hours before session open (0 = session bars only)
input double          InpMaxSlAtrRatio      = 2.5;         // Max initial SL distance vs ATR (0 = no filter)

input group "Risk"
input ENUM_RISK_MODE  InpRiskMode           = RISK_MODE_PERCENT; // Risk & target unit
input double          InpRiskPercent        = 0.5;         // [%] Risk per trade (% capital)
input double          InpRiskMoney          = 500.0;       // [$] Risk per trade (money)
input ENUM_SL_ANCHOR  InpSLAnchor           = SL_ANCHOR_CHOCH_LEG; // SL anchor (CHoCH leg extreme / sweep wick)
input double          InpSLBufferPoints     = 0;           // SL pad beyond wick (points)
input double          InpBreakEvenAtPercent = 0.25;        // [%] Move SL to BE at (%)
input double          InpBreakEvenAtMoney   = 250.0;       // [$] Move SL to BE at (money)

input group "Targets"
input double          InpDefaultTargetPct   = 2.5;         // [%] Default target (%)
input double          InpDefaultTargetMoney = 5000.0;      // [$] Default target (money)
input double          InpMaxTargetPct       = 5.0;         // [%] Hard cap (%)
input double          InpMaxTargetMoney     = 5000.0;      // [$] Hard cap (money)
input bool            InpUsePartialTP       = true;        // Partial close at default target
input double          InpPartialPercent     = 55.0;        // Partial size (%)

input group "Momentum runner"
input double          InpMomentumBodyATR    = 1.3;         // Displacement (body >= x*ATR)
input int             InpMomentumStallBars  = 3;           // Stall / progress window (bars)
input double          InpAtrContractionFac  = 0.6;         // Exhaustion (ATR < x*ATR@entry)
input double          InpTrailPadPoints     = 0;           // Structure-trail pad (points)

input group "Profit ratchet"
input bool            InpUseRatchet         = true;        // Ratchet SL to a rising floor of peak profit
input double          InpRatchetTriggerR    = 2.0;         // Arm once peak profit reaches this many R (peak / risk money)
input double          InpRatchetLockFrac    = 0.5;         // Lock this fraction of peak profit as the floor

input group "Management cadence"
input bool            InpManageOnBarClose   = true;        // Manage position on bar close only (tick-model independent)

input group "Add positions on a risk-free trade"
input bool            InpAddWhenBE          = false;       // Allow a new position once every open one is at break-even
input ENUM_ADD_DIRECTION InpAddDirection    = ADD_DIR_SAME;// Which direction may be added
input int             InpMaxOpenPositions   = 2;           // Max concurrent positions (1-8)

input group "Session caps"
input int             InpMaxTradesPerSession= 3;           // Max trades per session
input bool            InpStopAfterFirstWin  = true;        // Stop after first win
input bool            InpTradeMonday        = true;        // Allow trading on Monday
input bool            InpTradeFriday        = true;        // Allow trading on Friday

input group "Logging"
input bool            InpWriteCsv           = true;        // Write per-trade analytics CSV (MAE/MFE, context, exits)
input bool            InpTrackCounterfactual= true;        // Track what the ORIGINAL SL/TP would have done after an early exit
input int             InpCounterfactualBars = 720;         // How long to watch (bars; 720 = 24h on M2)
input bool            InpWriteJournal       = true;        // Write the styled .xls journal (slower; CSV is a superset)
input bool            InpDebug              = false;       // Print per-bar detection trace to Experts log

input group "Visuals"
input bool            InpShowVisuals        = true;        // Draw range/session boxes
input color           InpColorRange         = clrGoldenrod;// Prev-day 4H range
input color           InpColorAsia          = clrDodgerBlue;// Asia session range
input color           InpColorLondon        = clrMediumSeaGreen;// London session range
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
CVwap            g_vwap;
CEntryModels     g_entry;
CRiskManager     g_risk;
CDynamicTP       g_dtp;
CTradeJournal    g_journal;
CVisuals         g_visuals;
CDashboard       g_dash;
CTrade           g_trade;

SStratState      g_state;
datetime         g_lastBar=0;
int              g_atrHandle=INVALID_HANDLE;   // for the entry-time SL/ATR filter

//--- One tracked position. Normally there is exactly one; with
//--- addWhenBreakEven the EA may hold up to maxOpenPositions at once.
struct SOpenPos
  {
   bool     active;
   ulong    ticket;
   long     positionId;   // for HistorySelectByPosition
   bool     isBuy;
   double   entry;
   double   lots;
   string   session;      // journal fields, captured at open time
   string   bias;
   string   model;
   string   day;
   STradeRecord rec;      // live analytics record, finalised on close
  };
SOpenPos         g_open[SS_MAX_OPEN];
CTradeAnalytics  g_analytics;

//--- context captured at order-send time, consumed by OnPositionOpened
int              g_tradeSeq=0;      // global trade counter (g_risk.Trades() is per-SESSION)
double           g_reqPrice=0;      // the price we ASKED for
string           g_orderKind="";    // LIMIT / MARKET / LIMIT_DEGRADED
int              g_reqSpread=0;

ulong            g_pendingTicket=0;   // working CHoCH limit order
string           g_pendingModel="";
SEntrySignal     g_lastBos;           // newest confirmed BOS (the "liquidity")
datetime         g_pendingBasisTime=0;// structTime of the BOS the limit sits on
int              g_bosCount=0;        // BOS counter for the current pending cycle
string           g_lastSessionKey="";
//--- VWAP auto-bias state
string           g_autoBiasKey="";    // session key the auto bias was decided for
double           g_vwapAtOpen=0;      // VWAP carried into that session open
double           g_sessionOpenPx=0;   // open of the session's first bar
datetime         g_sessionOpenT=0;    // time of that bar
double           g_vwapNow=0;         // live VWAP (refreshed on bar close)
datetime         g_vwapDrawnTo=0;     // last bar the VWAP curve was drawn to
datetime         g_vwapAnchorDrawn=0; // anchor the drawn curve belongs to
string           g_autoBiasWarnKey=""; // session already warned about missing VWAP data

//+------------------------------------------------------------------+
int ParseHM(const string hm)
  {
   string parts[]; int k=StringSplit(hm,':',parts);
   if(k<2) return(0);
   return((int)StringToInteger(parts[0])*60+(int)StringToInteger(parts[1]));
  }

//+------------------------------------------------------------------+
//| Latest completed-bar ATR, for the entry-time SL/ATR filter        |
//+------------------------------------------------------------------+
double CurrentATR()
  {
   double a[]; ArraySetAsSeries(a,true);
   if(CopyBuffer(g_atrHandle,0,0,2,a)<1) return(0);
   return(a[0]);
  }

//+------------------------------------------------------------------+
void BuildSettings()
  {
   g_s.tf                    =InpTF;
   g_s.magic                 =InpMagic;
   g_s.brokerToRiyadhOffsetHr=InpBrokerToRiyadhHr;
   g_s.asiaStartMin          =ParseHM(InpAsiaStart);
   g_s.asiaEndMin            =ParseHM(InpAsiaEnd);
   g_s.useLondon             =InpUseLondon;
   g_s.londonStartMin        =ParseHM(InpLondonStart);
   g_s.londonEndMin          =ParseHM(InpLondonEnd);
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
   g_s.detectPreHours        =InpDetectPreHours;
   g_s.biasMode              =InpBiasMode;
   g_s.vwapAnchor            =InpVwapAnchor;
   g_s.vwapSource            =InpVwapSource;
   g_s.riskMode              =InpRiskMode;
   g_s.riskPercent           =InpRiskPercent;
   g_s.riskMoney             =InpRiskMoney;
   g_s.slAnchor              =InpSLAnchor;
   g_s.slBufferPoints        =InpSLBufferPoints;
   g_s.maxSlAtrRatio         =InpMaxSlAtrRatio;
   g_s.breakEvenAtPercent    =InpBreakEvenAtPercent;
   g_s.breakEvenAtMoney      =InpBreakEvenAtMoney;
   g_s.defaultTargetPercent  =InpDefaultTargetPct;
   g_s.defaultTargetMoney    =InpDefaultTargetMoney;
   g_s.maxTargetPercent      =InpMaxTargetPct;
   g_s.maxTargetMoney        =InpMaxTargetMoney;
   g_s.usePartialTP          =InpUsePartialTP;
   g_s.partialPercent        =InpPartialPercent;
   g_s.useRatchet            =InpUseRatchet;
   g_s.ratchetTriggerR       =InpRatchetTriggerR;
   g_s.ratchetLockFrac       =InpRatchetLockFrac;
   g_s.momentumBodyATR       =InpMomentumBodyATR;
   g_s.momentumStallBars     =InpMomentumStallBars;
   g_s.atrContractionFactor  =InpAtrContractionFac;
   g_s.trailPadPoints        =InpTrailPadPoints;
   g_s.manageOnBarClose      =InpManageOnBarClose;
   g_s.addWhenBreakEven      =InpAddWhenBE;
   g_s.addDirection          =InpAddDirection;
   g_s.maxOpenPositions      =(int)MathMax(1,MathMin(SS_MAX_OPEN,InpMaxOpenPositions));
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
   g_vwap.Init(g_s,sym);
   g_entry.Init(g_s,sym);
   g_risk.Init(g_s,sym);
   g_dtp.Init(g_s,sym);
   g_atrHandle=iATR(sym,g_s.tf,14);
   g_journal.Init(g_s.writeJournal,sym);
   g_analytics.Init(InpWriteCsv,InpTrackCounterfactual,InpCounterfactualBars,sym);
   g_visuals.Init(ChartID(),InpShowVisuals,InpColorRange,InpColorAsia,InpColorLondon,InpColorNY);
   g_visuals.InitSignals(InpShowSignals,InpColorChoch,InpColorIfvg,InpColorSweep);
   g_visuals.InitSwings(InpShowSwings,InpColorSwingHi,InpColorSwingLo);
   g_visuals.SetFvgColor(InpColorFvg);
   g_visuals.InitVwap(InpShowVwap,InpColorVwap);
   g_dash.Init(ChartID(),sym);

   // backtest convenience: arm a fixed bias without clicking the panel.
   // ForcedBias outranks the VWAP auto-bias (see UpdateAutoBias).
   if(InpForcedBias!=BIAS_NONE)
     {
      g_panel.SetBias(InpForcedBias);
      if(InpBiasMode==BIAS_MODE_VWAP)
         Alert("SS: ForcedBias is set - the VWAP auto-bias is DISABLED. Set ForcedBias = NONE in the Inputs tab to use it.");
     }
   else if(InpBiasMode==BIAS_MODE_VWAP)
      PrintFormat("[SS] BIAS MODE: AUTO via VWAP (%s anchor) - the panel is an override only",
                  InpVwapAnchor==VWAP_ANCHOR_WEEK?"week":"day");

   // which risk unit is live decides how EVERY threshold is read — print the
   // resolved numbers so a saved .set can never be ambiguous
   if(g_s.riskMode==RISK_MODE_MONEY)
      PrintFormat("[SS] RISK MODE: FIXED MONEY - risk %.2f, BE at %.2f, default target %.2f, cap %.2f (%s). The %% inputs are IGNORED.",
                  g_s.riskMoney,g_s.breakEvenAtMoney,g_s.defaultTargetMoney,g_s.maxTargetMoney,
                  AccountInfoString(ACCOUNT_CURRENCY));
   else
      PrintFormat("[SS] RISK MODE: PERCENT OF BALANCE - risk %.2f%%, BE at %.2f%%, default target %.2f%%, cap %.2f%% (= %.2f / %.2f / %.2f / %.2f %s at the current balance). The $ inputs are IGNORED.",
                  g_s.riskPercent,g_s.breakEvenAtPercent,g_s.defaultTargetPercent,g_s.maxTargetPercent,
                  g_risk.RiskMoney(),g_risk.BreakEvenMoney(),
                  g_risk.DefaultTargetMoney(),g_risk.MaxTargetMoney(),
                  AccountInfoString(ACCOUNT_CURRENCY));

   // multi-position mode breaks the charter's one-trade-at-a-time rule, and a
   // saved .set can enable it silently — say so on every init
   if(g_s.addWhenBreakEven)
      PrintFormat("[SS] ADD-ON-BREAK-EVEN: ON (%s, max %d concurrent) - a new position may open while existing ones sit at BE",
                  g_s.addDirection==ADD_DIR_COUNTER?"counter-direction only":
                  g_s.addDirection==ADD_DIR_SAME   ?"same-direction only":"same or counter",
                  g_s.maxOpenPositions);

   g_trade.SetExpertMagicNumber(g_s.magic);
   g_trade.SetTypeFillingBySymbol(sym);
   g_trade.SetDeviationInPoints(20);

   // warn immediately if the terminal will reject our orders (retcode 10027)
   if(!(bool)MQLInfoInteger(MQL_TESTER))
     {
      if(!(bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
         Alert("SS: Algo Trading is DISABLED in the terminal (toolbar button / Ctrl+E) - all orders will FAIL");
      else if(!(bool)MQLInfoInteger(MQL_TRADE_ALLOWED))
         Alert("SS: live trading not allowed for this EA - enable 'Allow Algo Trading' in the EA settings (F7 > Common)");
     }
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // Anything still open never produced a close event, so record it here or it
   // would silently vanish from the CSV and skew every aggregate.
   if(InpWriteCsv)
     {
      for(int i=0;i<SS_MAX_OPEN;i++)
        {
         if(!g_open[i].active) continue;
         STradeRecord rec=g_open[i].rec;
         bool beA=false; datetime beT=0; int tm=0; double atr=0;
         if(g_dtp.GetStats(g_open[i].ticket,beA,beT,tm,atr))
           { rec.beArmed=beA; rec.beTime=beT; rec.trailMoves=tm; }
         rec.closeTime =TimeCurrent();
         rec.exitReason=EXIT_END_OF_TEST;
         if(PositionSelectByTicket(g_open[i].ticket))
           {
            rec.exitPrice  =PositionGetDouble(POSITION_PRICE_CURRENT);
            rec.grossProfit=PositionGetDouble(POSITION_PROFIT);
            rec.swap       =PositionGetDouble(POSITION_SWAP);
            rec.netProfit  =rec.grossProfit+rec.swap;
           }
         rec.balanceClose=AccountInfoDouble(ACCOUNT_BALANCE);
         g_analytics.Submit(rec);
        }
     }

   // Both journals buffer in memory and are written once, here: rebuilding a
   // file on every close dominated runtime over a 1,500-trade run.
   g_analytics.Flush(g_s);
   g_journal.Flush();

   g_panel.Destroy();
   g_visuals.Destroy();
   g_dash.Destroy();
   g_dtp.Deinit();
   if(g_atrHandle!=INVALID_HANDLE) IndicatorRelease(g_atrHandle);
  }

//+------------------------------------------------------------------+
//| Refresh the cheap live fields + redraw the dashboard immediately  |
//| (so bias/session update instantly, even while the tester is paused)|
//+------------------------------------------------------------------+
void RefreshDashboardLive()
  {
   datetime now=TimeCurrent();
   g_state.bias        =g_panel.Bias();
   g_state.biasAuto    =(g_s.biasMode==BIAS_MODE_VWAP && InpForcedBias==BIAS_NONE);
   g_state.vwap        =g_vwapNow;
   g_state.vwapAtOpen  =g_vwapAtOpen;
   g_state.sessionOpen =g_sessionOpenPx;
   g_state.session     =g_session.CurrentSession(now);
   g_state.inWindow    =g_session.InEntryWindow(now);
   g_state.openCount   =OpenCount();
   g_state.positionOpen=(g_state.openCount>0);
   g_state.allAtBE     =g_state.positionOpen && AllOpenAtBreakEven();
   g_state.pending     =(g_pendingTicket!=0);
   g_state.floatPct    =g_state.positionOpen?OpenFloatPercent():0;
   // keep day / max-trades live every tick
   MqlDateTime _drl; TimeToStruct(ToRiyadh(now,g_s),_drl);
   g_state.dayAllowed=!(_drl.day_of_week==1 && !g_s.tradeMonday) &&
                      !(_drl.day_of_week==5 && !g_s.tradeFriday);
   g_state.maxTrades =g_s.maxTradesPerSession;
   string noBias=g_state.biasAuto?"waiting session open (VWAP auto-bias)"
                                 :"arm a bias (BUY/SELL)";
   if(g_state.bias==BIAS_NONE)
      g_state.note=noBias;
   else if(!g_state.dayAllowed)
      g_state.note=(_drl.day_of_week==1)?"Monday trading disabled":"Friday trading disabled";
   else if(g_state.session==SESSION_NONE)
      g_state.note="armed - out of session";
   else if(g_state.note==noBias ||
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
//| Open-position slots                                              |
//+------------------------------------------------------------------+
int OpenCount()
  {
   int n=0;
   for(int i=0;i<SS_MAX_OPEN;i++) if(g_open[i].active) n++;
   return(n);
  }

bool IsTracked(const ulong ticket)
  {
   for(int i=0;i<SS_MAX_OPEN;i++)
      if(g_open[i].active && g_open[i].ticket==ticket) return(true);
   return(false);
  }

//--- Is EVERY open position protected at break-even or better? A position
//--- whose SL still sits at the original stop is real risk, so adding on top
//--- of it is refused. Read from the live SL rather than DynamicTP's beDone
//--- flag: if the broker rejected the PositionModify (stops level), beDone is
//--- still set but the stop never actually moved.
bool AllOpenAtBreakEven()
  {
   double tol=SymbolInfoDouble(_Symbol,SYMBOL_POINT)*0.5;
   bool any=false;
   for(int i=0;i<SS_MAX_OPEN;i++)
     {
      if(!g_open[i].active) continue;
      if(!PositionSelectByTicket(g_open[i].ticket)) continue; // gone; reaped below
      any=true;
      double sl=PositionGetDouble(POSITION_SL);
      if(sl==0) return(false);                                // no stop at all
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      bool   isBuy=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      if(isBuy  && sl<entry-tol) return(false);
      if(!isBuy && sl>entry+tol) return(false);
     }
   return(any);
  }

//--- Gate on the NUMBER of positions: the charter default is one at a time.
bool CanOpenAnother()
  {
   int n=OpenCount();
   if(n==0)                        return(true);
   if(!g_s.addWhenBreakEven)       return(false);  // classic one-position rule
   if(n>=g_s.maxOpenPositions)     return(false);
   return(AllOpenAtBreakEven());
  }

//--- Gate on the DIRECTION of the addition. Evaluated against every open
//--- position, so COUNTER means "opposite to all of them" and SAME means
//--- "matching all of them" — with one long and one short already open,
//--- neither mode admits a third.
bool AddDirectionAllowed(const ENUM_BIAS bias)
  {
   if(OpenCount()==0)                  return(true);
   if(g_s.addDirection==ADD_DIR_BOTH)  return(true);
   bool wantBuy=(bias==BIAS_BUY);
   for(int i=0;i<SS_MAX_OPEN;i++)
     {
      if(!g_open[i].active) continue;
      if(g_s.addDirection==ADD_DIR_COUNTER && g_open[i].isBuy==wantBuy) return(false);
      if(g_s.addDirection==ADD_DIR_SAME    && g_open[i].isBuy!=wantBuy) return(false);
     }
   return(true);
  }

//--- Summed floating P/L of everything open, as % of capital
double OpenFloatPercent()
  {
   double sum=0;
   for(int i=0;i<SS_MAX_OPEN;i++)
      if(g_open[i].active && PositionSelectByTicket(g_open[i].ticket))
         sum+=PositionGetDouble(POSITION_PROFIT);
   return(g_risk.FloatPercent(sum));
  }

//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t=iTime(_Symbol,g_s.tf,0);
   if(t!=g_lastBar){ g_lastBar=t; return(true); }
   return(false);
  }

//+------------------------------------------------------------------+
//| Why did this position end? Broker-side fills carry a DEAL_REASON; |
//| an SL fill is then split by WHERE the stop had been moved to, and |
//| an EA-initiated close takes the reason CDynamicTP stamped.        |
//+------------------------------------------------------------------+
ENUM_EXIT_REASON ClassifyExit(const STradeRecord &r,const ENUM_DEAL_REASON dr,
                              const ulong ticket)
  {
   double tol=SymbolInfoDouble(_Symbol,SYMBOL_POINT)*2.0;
   if(dr==DEAL_REASON_TP) return(EXIT_TAKE_PROFIT);
   if(dr==DEAL_REASON_SL)
     {
      if(MathAbs(r.finalSL-r.initialSL)<=tol)   return(EXIT_STOP_LOSS);
      if(MathAbs(r.finalSL-r.entryPrice)<=tol)  return(EXIT_BREAK_EVEN);
      return(EXIT_TRAIL_STOP);
     }
   ENUM_EXIT_REASON stamped=g_dtp.CloseReasonFor(ticket);
   if(stamped!=EXIT_UNKNOWN) return(stamped);
   return(EXIT_UNKNOWN);
  }

//+------------------------------------------------------------------+
//| Excursion sampling. MEASUREMENT ONLY - never gates a decision.    |
//| Per tick we fold the mark price (covers the partial entry/exit    |
//| bars); per new bar we fold the completed bar's true high/low,     |
//| which is what makes MAE/MFE identical across every tick model.    |
//+------------------------------------------------------------------+
void SampleExcursions(const bool newBar)
  {
   if(!InpWriteCsv || OpenCount()==0) return;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   datetime now=TimeCurrent();
   double barHi=0,barLo=0; datetime barT=0;
   if(newBar)
     {
      barHi=iHigh(_Symbol,g_s.tf,1);
      barLo=iLow (_Symbol,g_s.tf,1);
      barT =iTime(_Symbol,g_s.tf,1);
     }
   for(int i=0;i<SS_MAX_OPEN;i++)
     {
      if(!g_open[i].active) continue;
      double mark=g_open[i].rec.isBuy?bid:ask;   // what we would exit at now
      CTradeAnalytics::Sample(g_open[i].rec,mark,mark,now);
      // Skip the bar the position opened on: its high/low include movement
      // from before the entry, which would overstate both excursions.
      if(newBar && barHi>0 && barT>g_open[i].rec.openBar)
         CTradeAnalytics::Sample(g_open[i].rec,barHi,barLo,barT);
      if(PositionSelectByTicket(g_open[i].ticket))
         g_open[i].rec.finalSL=PositionGetDouble(POSITION_SL);
      // pull the break-even flag live: Sample() freezes mfePriceBeforeBE the
      // moment this flips, which is the whole point of the before/after split
      bool beA=false; datetime beT=0; int tm=0; double atr=0;
      if(g_dtp.GetStats(g_open[i].ticket,beA,beT,tm,atr))
        { g_open[i].rec.beArmed=beA; g_open[i].rec.beTime=beT; g_open[i].rec.trailMoves=tm; }
     }
  }

//+------------------------------------------------------------------+
//| Detect a closed position, register result, journal it            |
//+------------------------------------------------------------------+
void CheckClosedPosition()
  {
   for(int i=0;i<SS_MAX_OPEN;i++)
     {
      if(!g_open[i].active) continue;
      if(PositionSelectByTicket(g_open[i].ticket)) continue; // still open

      // gather realized P/L from history, split into its components so the
      // CSV can separate a scratch that paid commission from a real loss
      double total=0,gross=0,comm=0,swp=0;
      datetime closeTime=TimeCurrent(); double exit=0;
      int outDeals=0; double firstOutLots=0,firstOutMoney=0;
      ENUM_DEAL_REASON lastReason=DEAL_REASON_CLIENT;
      if(HistorySelectByPosition(g_open[i].positionId))
        {
         int deals=HistoryDealsTotal();
         for(int k=0;k<deals;k++)
           {
            ulong d=HistoryDealGetTicket(k);
            double dp=HistoryDealGetDouble(d,DEAL_PROFIT);
            double ds=HistoryDealGetDouble(d,DEAL_SWAP);
            double dc=HistoryDealGetDouble(d,DEAL_COMMISSION);
            total+=dp+ds+dc; gross+=dp; swp+=ds; comm+=dc;
            if(HistoryDealGetInteger(d,DEAL_ENTRY)==DEAL_ENTRY_OUT)
              {
               outDeals++;
               if(outDeals==1)
                 {
                  firstOutLots =HistoryDealGetDouble(d,DEAL_VOLUME);
                  firstOutMoney=dp+ds+dc;
                 }
               closeTime =(datetime)HistoryDealGetInteger(d,DEAL_TIME);
               exit      =HistoryDealGetDouble(d,DEAL_PRICE);
               lastReason=(ENUM_DEAL_REASON)HistoryDealGetInteger(d,DEAL_REASON);
              }
           }
        }
      bool win=(total>0);

      //--- finalise the analytics record before the slot is freed
      if(InpWriteCsv)
        {
         STradeRecord rec=g_open[i].rec;
         bool beA=false; datetime beT=0; int tm=0; double atr=0;
         if(g_dtp.GetStats(g_open[i].ticket,beA,beT,tm,atr))
           { rec.beArmed=beA; rec.beTime=beT; rec.trailMoves=tm; }
         rec.closeTime  =closeTime;
         rec.exitPrice  =exit;
         rec.grossProfit=gross; rec.commission=comm; rec.swap=swp; rec.netProfit=total;
         rec.balanceClose=AccountInfoDouble(ACCOUNT_BALANCE);
         rec.partialTaken=(outDeals>1);
         if(rec.partialTaken){ rec.partialLots=firstOutLots; rec.partialMoney=firstOutMoney; }
         rec.exitReason =ClassifyExit(rec,lastReason,g_open[i].ticket);
         g_analytics.Submit(rec);
        }
      g_risk.RegisterClose(win);
      g_journal.LogTrade(g_open[i].day,closeTime,g_open[i].session,g_open[i].bias,
                         g_open[i].model,g_open[i].lots,total,
                         AccountInfoDouble(ACCOUNT_BALANCE));
      PrintFormat("[SS] POSITION CLOSED: %I64u exit %.2f, P/L %.2f (%.2f%%) -> %s (%d still open)",
                  g_open[i].ticket,exit,total,g_risk.FloatPercent(total),
                  win?"WIN":"LOSS",OpenCount()-1);

      g_dtp.Clear(g_open[i].ticket);
      g_open[i].active=false;
     }
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
   int slot=-1;
   for(int i=0;i<SS_MAX_OPEN;i++) if(!g_open[i].active){ slot=i; break; }
   if(slot<0)
     {
      PrintFormat("[SS] WARNING: no free slot for position %I64u - it will be UNTRACKED",posTicket);
      return;
     }

   bool   isBuy=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
   double entry=PositionGetDouble(POSITION_PRICE_OPEN);
   double lots =PositionGetDouble(POSITION_VOLUME);
   double sl   =PositionGetDouble(POSITION_SL);
   datetime now=TimeCurrent();
   ENUM_SESSION ses=g_session.CurrentSession(now);

   g_open[slot].active    =true;
   g_open[slot].ticket    =posTicket;
   g_open[slot].positionId=(long)PositionGetInteger(POSITION_IDENTIFIER);
   g_open[slot].isBuy     =isBuy;
   g_open[slot].entry     =entry;
   g_open[slot].lots      =lots;
   g_open[slot].session   =SessionName(ses);
   g_open[slot].bias      =isBuy?"BUY":"SELL";
   g_open[slot].model     =model;
   g_open[slot].day       =DayOfWeekName(ToRiyadh(now,g_s)); // same day base as the Mon/Fri filter

   //--- analytics record: capture everything the setup knew at this moment
   STradeRecord rec;
   CTradeAnalytics::Begin(rec);
   rec.tradeNo   =++g_tradeSeq;           // NOT g_risk.Trades() - that resets per session
   rec.ticket    =posTicket;
   rec.positionId=g_open[slot].positionId;
   rec.openTime  =now;
   rec.openBar   =iTime(_Symbol,g_s.tf,0);
   rec.weekday   =g_open[slot].day;
   rec.session   =g_open[slot].session;
   rec.minsFromSessionOpen=(ses!=SESSION_NONE)
                           ?(int)((now-g_session.SessionStartServer(now))/60):-1;
   rec.isBuy     =isBuy;
   rec.bias      =g_open[slot].bias;
   rec.biasSource=(InpForcedBias!=BIAS_NONE)?"FORCED"
                  :(g_s.biasMode==BIAS_MODE_VWAP)?"VWAP":"PANEL";
   rec.model     =model;
   rec.orderKind =(g_orderKind!="")?g_orderKind:"MARKET";
   rec.bosCount  =g_bosCount;
   rec.sweptLevel=g_liq.SweptLevel();
   rec.sweptTime =g_liq.TargetTime();
   rec.sweepExtreme=g_liq.SweepExtreme();
   rec.sessionOpenPx=g_sessionOpenPx;
   rec.vwapAtOpen=g_vwapAtOpen;
   rec.rangeHi   =g_session.RangeHigh();
   rec.rangeLo   =g_session.RangeLow();
   // recorded for research only - rule 2 is still NOT an entry gate
   rec.rangeExited=(ses!=SESSION_NONE && g_session.RangeValid())
                   ?g_session.AsiaRangeExited(g_session.SessionStartServer(now)):false;
   rec.spreadAtEntry=g_reqSpread;
   rec.requestedPrice=(g_reqPrice>0)?g_reqPrice:entry;
   rec.entryPrice=entry;
   rec.lots      =lots;
   rec.initialSL =sl;
   rec.initialTP =PositionGetDouble(POSITION_TP);
   rec.finalSL   =sl;
   rec.riskMoney =g_risk.LossPerLot(entry,sl)*lots;   // realised 1R for this fill
   rec.riskPct   =(AccountInfoDouble(ACCOUNT_BALANCE)>0)
                  ?rec.riskMoney/AccountInfoDouble(ACCOUNT_BALANCE)*100.0:0;
   rec.riskMode  =(g_s.riskMode==RISK_MODE_MONEY)?"MONEY":"PERCENT";
   rec.balanceOpen=AccountInfoDouble(ACCOUNT_BALANCE);
   rec.equityOpen =AccountInfoDouble(ACCOUNT_EQUITY);
   rec.mfePrice  =entry; rec.maePrice=entry; rec.mfePriceBeforeBE=entry;
   g_open[slot].rec=rec;
   g_reqPrice=0; g_orderKind=""; g_reqSpread=0;

   g_risk.RegisterOpen();
   g_dtp.OnNewTrade(posTicket,isBuy,entry);

   {
    bool beA; datetime beT; int tm; double atr;
    if(g_dtp.GetStats(posTicket,beA,beT,tm,atr)) g_open[slot].rec.atrAtEntry=atr;
   }

   double tp=PositionGetDouble(POSITION_TP);
   g_visuals.DrawTrade(TimeToString(now,TIME_DATE|TIME_MINUTES)+"_"+(string)posTicket,
                       isBuy,entry,sl,tp,now);

   int n=OpenCount();
   PrintFormat("[SS] POSITION OPENED: %s %s %.2f lots @ %.2f, SL %.2f, TP %.2f (model %s, session %s)%s",
               g_open[slot].bias,_Symbol,lots,entry,sl,tp,model,g_open[slot].session,
               n>1?StringFormat(" [ADDED - %d open]",n):"");
   Alert(StringFormat("SS: OPENED %s %.2f lots @ %.2f, SL %.2f (%s)%s",
                      g_open[slot].bias,lots,entry,sl,model,
                      n>1?StringFormat(" [%d open]",n):""));

   g_bosCount=0; g_pendingBasisTime=0; // BOS-trailing cycle ends on fill
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
         g_pendingTicket=0; g_pendingModel="";
         g_bosCount=0; g_pendingBasisTime=0;
        }
      // NOTE: no time-based market fallback here. Per the BOS-trailing rule
      // the limit WAITS on its BOS no matter how far price runs; only a new
      // BOS (TrailPendingOnNewBos) or the window end can move/cancel it.
      return;
     }

   // no longer a working order -> filled or removed
   if(PositionSelectByTicket(g_pendingTicket))
      OnPositionOpened(g_pendingTicket,g_pendingModel);
   else
     {
      // fallback: locate our freshly opened position. Skip anything already
      // tracked — with several positions live, the newest is the only
      // untracked one, and adopting an older one would double-book it.
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong t=PositionGetTicket(i);
         if(IsTracked(t)) continue;
         if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC)==g_s.magic)
           { OnPositionOpened(t,g_pendingModel); break; }
        }
     }
   g_pendingTicket=0; g_pendingModel="";
   g_bosCount=0; g_pendingBasisTime=0;
  }

//+------------------------------------------------------------------+
//| BOS trailing: while a CHoCH limit is pending, keep detecting new  |
//| structure breaks. The limit always sits on the SECOND-NEWEST BOS: |
//| BOS #2 keeps the order on BOS #1; from BOS #3 on, the order moves |
//| up to the previous newest BOS. The newest BOS is the liquidity.   |
//+------------------------------------------------------------------+
void TrailPendingOnNewBos(const datetime now)
  {
   if(g_pendingTicket==0) return;
   ENUM_BIAS bias=g_panel.Bias();
   if(bias==BIAS_NONE) return;
   ENUM_SESSION ses=g_session.CurrentSession(now);
   if(ses==SESSION_NONE || !g_session.InEntryWindow(now)) return;

   g_entry.SetWindow(g_session.SessionStartServer(now)
                     -(datetime)(g_s.detectPreHours*3600.0));
   g_entry.SetSessionStart(g_session.SessionStartServer(now));
   g_entry.SetNotBefore(g_liq.TargetTime()); // patterns from the sweep leg on

   // an IFVG confirming while the CHoCH limit is still UNFILLED supersedes
   // it: charter order is "first valid trigger after the sweep wins", and
   // the IFVG is an immediate close-confirmed market entry — don't keep
   // waiting on a retrace that may never come
   if(g_s.entryModel!=ENTRY_CHOCH_ONLY)
     {
      SEntrySignal ifvg;
      if(g_entry.CheckIFVG(bias,ifvg))
        {
         PrintFormat("[SS] IFVG confirmed while CHoCH limit %I64u unfilled -> cancelling limit, entering MARKET",
                     g_pendingTicket);
         g_trade.OrderDelete(g_pendingTicket);
         g_pendingTicket=0; g_pendingModel="";
         g_bosCount=0; g_pendingBasisTime=0;
         PlaceOrder(bias,ifvg);
         return;
        }
     }

   SEntrySignal sig;
   if(!g_entry.CheckCHoCH(bias,sig)) return;
   if(sig.structTime==g_lastBos.structTime) return;   // same BOS, nothing new

   g_bosCount++;
   PrintFormat("[SS] NEW BOS #%d (struct %.2f) - newest BOS is now the liquidity",
               g_bosCount,sig.structLevel);

   // from BOS #3 on: lift the limit up to the previous newest BOS
   if(g_lastBos.valid && g_lastBos.structTime!=g_pendingBasisTime)
     {
      SEntrySignal basis=g_lastBos;
      PrintFormat("[SS] MOVING pending limit to BOS @ struct %.2f (retrace %.2f)",
                  basis.structLevel,basis.price);
      g_trade.OrderDelete(g_pendingTicket);
      g_pendingTicket=0; g_pendingModel="";
      PlaceOrder(bias,basis);        // re-place (market fallback if already past)
      if(g_pendingTicket!=0) g_pendingBasisTime=basis.structTime;
     }
   g_lastBos=sig;

   // draw the newest BOS leg (the liquidity being built)
   g_visuals.DrawChoch(TimeToString(now,TIME_DATE|TIME_MINUTES),bias==BIAS_BUY,
                       sig.legLoTime,sig.legLo,sig.legHiTime,sig.legHi,
                       sig.structTime,sig.structLevel,sig.price,now);
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
//+------------------------------------------------------------------+
//| The terminal is the witness when the send is not                 |
//+------------------------------------------------------------------+
// MetaTrader build 6116 returns false from OrderSend for an order the server
// has placed, with an EMPTY result -- retcode 0. CTrade passes that straight
// through, so `ok` is false and ResultOrder() is 0 for a live order. These two
// answer the only question that matters afterwards: does it exist?
//
// Filtered on our own magic, the symbol, the side, the volume and "placed
// since we sent", so they cannot pick up anything but the order we just asked
// for. Nothing here adopts an order this EA is already tracking.

ulong FindOwnWorkingOrder(const ENUM_ORDER_TYPE want,const double lots,
                          const double price,const datetime since)
  {
   double tol=SymbolInfoDouble(_Symbol,SYMBOL_POINT)*100;
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong t=OrderGetTicket(i);
      if(t==0) continue;
      if(t==g_pendingTicket) continue;                       // already ours
      if(OrderGetInteger(ORDER_MAGIC)!=g_s.magic) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)!=want) continue;
      if((datetime)OrderGetInteger(ORDER_TIME_SETUP)<since) continue;
      if(MathAbs(OrderGetDouble(ORDER_VOLUME_CURRENT)-lots)>0.00001) continue;
      if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN)-price)>tol) continue;
      return(t);
     }
   return(0);
  }

ulong FindOwnRecentPosition(const bool isBuy,const double lots,const datetime since)
  {
   long want=isBuy?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if(IsTracked(t)) continue;                             // already ours
      if(PositionGetInteger(POSITION_MAGIC)!=g_s.magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_TYPE)!=want) continue;
      if((datetime)PositionGetInteger(POSITION_TIME)<since) continue;
      if(MathAbs(PositionGetDouble(POSITION_VOLUME)-lots)>0.00001) continue;
      return(t);
     }
   return(0);
  }

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
   double tp=g_risk.PriceForMoney(g_risk.MaxTargetMoney(),lots,isBuy,entry);

   // analytics context, consumed by OnPositionOpened. PlaceOrder may already
   // have marked this as a degraded limit, so do not overwrite that.
   if(g_orderKind=="") g_orderKind="MARKET";
   g_reqPrice =entry;
   g_reqSpread=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);

   datetime sentAt=TimeCurrent();
   bool ok=isBuy ? g_trade.Buy (lots,_Symbol,entry,sl,tp,"SS "+model)
                 : g_trade.Sell(lots,_Symbol,entry,sl,tp,"SS "+model);

   long posId=0;
   if(ok)
     {
      ulong deal=g_trade.ResultDeal();
      if(HistoryDealSelect(deal)) posId=(long)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
     }

   // Same rule as PlaceOrder, and it costs more here: an unadopted POSITION is
   // one the ratchet, the break-even move and the one-position gate all cannot
   // see. See FindOwnRecentPosition.
   if(posId==0)
     {
      ulong found=FindOwnRecentPosition(isBuy,lots,sentAt-2);
      if(found!=0)
        {
         posId=(long)found;
         PrintFormat("[SS] MARKET %s RECOVERED (%s): #%I64u exists despite retcode=%d",
                     isBuy?"BUY":"SELL",model,found,g_trade.ResultRetcode());
        }
     }

   if(posId==0)
     {
      PrintFormat("[SS] MARKET %s FAILED (%s): retcode=%d %s (terminal holds no matching position)",
                  isBuy?"BUY":"SELL",model,
                  g_trade.ResultRetcode(),g_trade.ResultRetcodeDescription());
      Alert(StringFormat("SS: MARKET %s FAILED - %s",
                         isBuy?"BUY":"SELL",g_trade.ResultRetcodeDescription()));
      return(false);
     }
   OnPositionOpened((ulong)posId,model);
   return(true);
  }

//+------------------------------------------------------------------+
//| Build & send the order for a confirmed signal                    |
//+------------------------------------------------------------------+
void PlaceOrder(const ENUM_BIAS bias,SEntrySignal &sig)
  {
   g_orderKind=""; g_reqPrice=0; g_reqSpread=0;   // fresh context per attempt
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

   // Backtest finding: trades whose SL sits wide relative to volatility are net
   // negative as a group (Welch p=0.0099 on the 602-trade export). Reject before
   // sizing rather than just sizing down, since the edge is genuinely absent, not
   // just under-risked. Measured against the live ask/bid, same as OpenMarket's
   // reference price, since LIMIT vs MARKET is not resolved yet at this point.
   if(g_s.maxSlAtrRatio>0)
     {
      double atrNow=CurrentATR();
      double refPx =isBuy?ask:bid;
      double slDist=MathAbs(refPx-sl);
      if(atrNow>0 && slDist/atrNow>g_s.maxSlAtrRatio)
        {
         PrintFormat("[SS] SKIPPED (%s %s): SL/ATR %.2f exceeds max %.2f (sl dist %.2f, atr %.2f)",
                     sig.model,isBuy?"BUY":"SELL",slDist/atrNow,g_s.maxSlAtrRatio,slDist,atrNow);
         return;
        }
     }

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
        {
         PrintFormat("[SS] %s: price already beyond the retrace level %.2f -> MARKET entry",
                     sig.model,sig.price);
         g_orderKind="LIMIT_DEGRADED";   // a limit that never got to work
         g_reqPrice =sig.price;          // keep what we ASKED for, for slippage
        }
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
   double tp=g_risk.PriceForMoney(g_risk.MaxTargetMoney(),lots,isBuy,entry);

   g_orderKind="LIMIT";
   g_reqPrice =entry;
   g_reqSpread=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);

   datetime sentAt=TimeCurrent();
   bool ok=isBuy
           ? g_trade.BuyLimit (lots,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,"SS "+sig.model)
           : g_trade.SellLimit(lots,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,"SS "+sig.model);

   ulong placed = ok ? g_trade.ResultOrder() : 0;

   // NEVER CONCLUDE "NO ORDER" FROM A FAILED SEND. MetaTrader build 6116
   // returns false from OrderSend for a pending order the server has ACCEPTED
   // AND PLACED, leaving the result empty -- retcode 0, which is exactly what
   // this printed live on 2026-08-26:
   //
   //   [SS] LIMIT SELL FAILED (CHoCH): retcode=0 unknown retcode 0
   //   ...while the journal said: order #152536683214 sell limit 1.43 done in 204ms
   //
   // g_pendingTicket then stayed 0 -- and that variable IS the one-position
   // gate in EvaluateAndAct. With it stuck at 0 the EA believed it had no
   // working order and no position, so two minutes later it placed a SECOND
   // entry on the same setup against the same stop. Both filled, both were
   // stopped out, and neither was ever adopted into g_open[], so neither got a
   // break-even move or the ratchet. The copied fleet took both.
   //
   // The reply is not the only witness -- the terminal is. Adopt what we asked
   // for rather than walking away from a live order.
   if(placed==0)
     {
      ENUM_ORDER_TYPE want = isBuy ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
      placed = FindOwnWorkingOrder(want,lots,entry,sentAt-2);
      if(placed==0) placed = FindOwnRecentPosition(isBuy,lots,sentAt-2);
      if(placed!=0)
         PrintFormat("[SS] LIMIT %s RECOVERED (%s): #%I64u exists despite retcode=%d",
                     isBuy?"BUY":"SELL",sig.model,placed,g_trade.ResultRetcode());
     }

   if(placed==0)
     {
      PrintFormat("[SS] LIMIT %s FAILED (%s): retcode=%d %s (terminal holds no matching order)",
                  isBuy?"BUY":"SELL",sig.model,
                  g_trade.ResultRetcode(),g_trade.ResultRetcodeDescription());
      Alert(StringFormat("SS: LIMIT %s FAILED - %s",
                         isBuy?"BUY":"SELL",g_trade.ResultRetcodeDescription()));
      return;
     }
   g_pendingTicket=placed;
   g_pendingModel =sig.model;
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
   st.biasAuto=(g_s.biasMode==BIAS_MODE_VWAP && InpForcedBias==BIAS_NONE);
   st.vwap=g_vwapNow; st.vwapAtOpen=g_vwapAtOpen; st.sessionOpen=g_sessionOpenPx;
   st.session=g_session.CurrentSession(now);
   st.inWindow=g_session.InEntryWindow(now);
   st.rangeValid=g_session.RangeValid();
   st.rangeHi=g_session.RangeHigh(); st.rangeLo=g_session.RangeLow();
   st.rangeExited=false; st.swept=false; st.sweptLevel=0; st.sweepWick=0;
   st.entryMet=false; st.entryModel=""; st.entryPrice=0; st.entryIsLimit=false;
   st.openCount=OpenCount(); st.positionOpen=(st.openCount>0);
   st.allAtBE=st.positionOpen && AllOpenAtBreakEven();
   st.pending=(g_pendingTicket!=0);
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

   if(st.positionOpen) st.floatPct=OpenFloatPercent();

   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

   // detection window: session bars PLUS 'detectPreHours' before the open —
   // the first session candles often sweep/gap against PRE-session structure
   // (swings, FVGs), which a session-only window cannot see. The signal bar
   // itself (the confirming close) is always in-session since evaluation
   // only runs during the session.
   datetime ss=(st.session!=SESSION_NONE)?g_session.SessionStartServer(now):0;
   g_entry.SetWindow(ss>0?ss-(datetime)(g_s.detectPreHours*3600.0):0);
   g_entry.SetSessionStart(ss); // pattern core stays in-session

   // sweep + entry evaluated whenever armed & in session (for the dashboard),
   // independent of the entry window
   SEntrySignal sig; bool haveSig=false;
   if(st.bias!=BIAS_NONE && st.session!=SESSION_NONE)
     {
      g_liq.Update(st.bias,ss);
      st.swept=g_liq.Swept(); st.sweptLevel=g_liq.SweptLevel(); st.sweepWick=g_liq.SweepExtreme();
      if(st.swept)
        {
         // entry pattern must belong to the SWEEPING LEG or later: anchored
         // at the swept level's own bar, so gaps formed by the leg that runs
         // up/down to take the liquidity count, while older zones never do
         g_entry.SetNotBefore(g_liq.TargetTime());
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

   // NOTE: the prior-day 4H range is drawn for REFERENCE only; whether price
   // broke out of it is the trader's MANUAL check (rule 2) - the code does
   // not gate entries on it. Arming a bias starts the hunt immediately.
   bool canAttempt = st.bias!=BIAS_NONE && st.session!=SESSION_NONE && st.inWindow
                     && g_pendingTicket==0 && CanOpenAnother() && AddDirectionAllowed(st.bias)
                     && st.canOpen && st.dayAllowed;

   if(canAttempt && st.swept && haveSig)
     {
      PlaceOrder(st.bias,sig);
      st.note="ORDER SENT: "+sig.model;
      st.pending=(g_pendingTicket!=0);
      st.openCount=OpenCount(); st.positionOpen=(st.openCount>0);
      if(g_pendingTicket!=0)
        {                    // start a BOS-trailing cycle for this limit
         g_pendingBasisTime=sig.structTime;
         g_lastBos=sig; g_bosCount=1;
        }
     }
   else
     {
      if(st.bias==BIAS_NONE)                                  st.note=st.biasAuto
                                                                       ?"waiting session open (VWAP auto-bias)"
                                                                       :"arm a bias (BUY/SELL)";
      else if(st.pending)                                    st.note="limit pending";
      else if(st.positionOpen && !g_s.addWhenBreakEven)      st.note="managing position";
      else if(st.positionOpen && !st.allAtBE)                st.note=StringFormat(
                                                                       "managing position (add needs SL at BE, %d open)",st.openCount);
      else if(st.positionOpen && st.openCount>=g_s.maxOpenPositions)
                                                             st.note=StringFormat(
                                                                       "max open positions reached (%d)",st.openCount);
      else if(st.positionOpen && !AddDirectionAllowed(st.bias))
                                                             st.note=StringFormat(
                                                                       "add blocked: %s only",
                                                                       g_s.addDirection==ADD_DIR_COUNTER?"counter-direction":"same-direction");
      else if(st.session==SESSION_NONE)                      st.note="out of session";
      else if(!st.canOpen)                                   st.note="session cap reached";
      else if(!st.dayAllowed)                                st.note=dayDisabledNote;
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

   // prior-day last-4h range (rule 2) — reference only, drawn strictly over
   // its own 4 hours (right edge = range end, never into the Asia session)
   if(ses==SESSION_ASIA && g_session.RangeValid())
      g_visuals.DrawPriorRange(g_session.RangeStartSrv(),g_session.RangeEndSrv(),
                               g_session.RangeEndSrv(),
                               g_session.RangeHigh(),g_session.RangeLow());

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
      // draw the newest gap RELEVANT to the armed bias: a SELL entry inverts
      // a BULLISH gap (close below it) and a BUY entry inverts a BEARISH
      // one — so that is the zone worth marking. No bias -> newest of any.
      ENUM_BIAS fb=g_panel.Bias();
      SFvg fv[]; ArrayResize(fv,8);
      int c=g_entry.CollectFVGs(fv,8,120);
      int pick=-1;
      for(int i=0;i<c;i++)
        {
         if(fb==BIAS_SELL && !fv[i].bullish) continue; // sell hunts bullish gaps
         if(fb==BIAS_BUY  &&  fv[i].bullish) continue; // buy hunts bearish gaps
         pick=i; break;
        }
      if(pick>=0)
         g_visuals.DrawFVG(0,fv[pick].t,now,fv[pick].lo,fv[pick].hi,fv[pick].inverted,fv[pick].bullish);
      g_visuals.ClearFVGs(pick>=0?1:0,InpMaxFVGs);
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
//| Refresh the live VWAP value and extend its curve by the bars that |
//| closed since the last call. The curve is wiped and restarted when |
//| the anchor period rolls over (new Riyadh day / week).             |
//+------------------------------------------------------------------+
void UpdateVwap(const datetime now)
  {
   datetime anchor=g_vwap.AnchorStart(now);
   if(anchor!=g_vwapAnchorDrawn)
     {
      g_visuals.ClearVwap();
      g_vwapAnchorDrawn=anchor;
      g_vwapDrawnTo=0;
     }

   datetime t[]; double v[];
   int n=g_vwap.Series(anchor,now,t,v);
   if(n<=0){ g_vwapNow=0; return; }
   g_vwapNow=v[n-1];

   if(!InpShowVwap) return;
   int start=(n>InpVwapDrawBars)?n-InpVwapDrawBars:1; // cap the drawn history
   for(int i=MathMax(1,start);i<n;i++)
     {
      if(t[i]<=g_vwapDrawnTo) continue;               // already drawn
      g_visuals.DrawVwapSegment(t[i-1],v[i-1],t[i],v[i]);
     }
   g_vwapDrawnTo=t[n-1];

   // keep the open-vs-VWAP decision visible for the rest of the day
   if(g_vwapAtOpen>0 && g_sessionOpenT>0)
      g_visuals.DrawVwapOpenMark(g_sessionOpenT,g_vwapAtOpen,now,
         StringFormat("VWAP@open %.2f - open %s -> %s",g_vwapAtOpen,
                      g_sessionOpenPx>g_vwapAtOpen?"ABOVE":"BELOW",
                      g_sessionOpenPx>g_vwapAtOpen?"BUY":"SELL"));
  }

//+------------------------------------------------------------------+
//| VWAP auto-bias — replaces the manual rule-17 input when           |
//| BiasMode = VWAP. Decided ONCE per session, on its first bar:      |
//|   session opens ABOVE the VWAP -> BUY, BELOW -> SELL.             |
//| The VWAP compared against is the value carried INTO the session   |
//| (bars strictly before the opening bar), so the opening bar itself |
//| cannot move the level it is being judged by.                      |
//| The panel still works as an override: a click after the automatic |
//| decision wins for the rest of that session (the key is latched).  |
//| ForcedBias outranks both.                                         |
//+------------------------------------------------------------------+
void UpdateAutoBias(const datetime now)
  {
   if(g_s.biasMode!=BIAS_MODE_VWAP || InpForcedBias!=BIAS_NONE) return;

   ENUM_SESSION ses=g_session.CurrentSession(now);
   if(ses==SESSION_NONE)
     {
      // out of session: disarm, so nothing is hunted until the next open
      if(g_autoBiasKey!="")
        {
         if(g_panel.Bias()!=BIAS_NONE){ g_panel.SetBias(BIAS_NONE); g_liq.Reset(); }
         g_autoBiasKey=""; g_autoBiasWarnKey="";
        }
      return;
     }

   string sk=g_session.SessionKey(now);
   if(sk==g_autoBiasKey) return;              // already decided for this session

   datetime ss=g_session.SessionStartServer(now);
   if(ss<=0) return;

   MqlRates r[]; ArraySetAsSeries(r,false);
   if(CopyRates(_Symbol,g_s.tf,ss,now,r)<1) return; // opening bar not there yet
   datetime openT =r[0].time;
   double   openPx=r[0].open;

   double vw=0;
   if(!g_vwap.ValueAt(openT-1,vw) || vw<=0)
     {
      if(g_autoBiasWarnKey!=sk)
        {
         g_autoBiasWarnKey=sk;
         PrintFormat("[SS] AUTO BIAS: no VWAP data before the %s open - bias stays NONE",
                     SessionName(ses));
        }
      return;
     }

   ENUM_BIAS b=(openPx>vw)?BIAS_BUY:(openPx<vw)?BIAS_SELL:BIAS_NONE;

   g_autoBiasKey  =sk;
   g_vwapAtOpen   =vw;
   g_sessionOpenPx=openPx;
   g_sessionOpenT =openT;

   if(b!=g_panel.Bias()){ g_panel.SetBias(b); g_liq.Reset(); }

   string bs=(b==BIAS_BUY)?"BUY":(b==BIAS_SELL)?"SELL":"NONE (open == VWAP)";
   PrintFormat("[SS] AUTO BIAS (VWAP): %s open %.2f vs VWAP %.2f -> %s",
               SessionName(ses),openPx,vw,bs);
   Alert(StringFormat("SS: AUTO BIAS %s - %s open %.2f vs VWAP %.2f",
                      bs,SessionName(ses),openPx,vw));
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

   // Evaluated once here: management may need it before the detection branch.
   bool newBar=IsNewBar();

   // Manage any open position (BE, runner, caps). Every tick by default, which
   // is how it behaves live. With manageOnBarClose the decisions are taken on
   // the new bar's open only, so the Strategy Tester's tick model stops moving
   // the result — see README "Tick model" for the trade-off.
   // sample BEFORE management, so an exit's own bar still contributes and the
   // recorded excursion is not truncated by the close
   SampleExcursions(newBar);
   if(newBar && InpWriteCsv && InpTrackCounterfactual)
      g_analytics.UpdateCounterfactuals(iHigh(_Symbol,g_s.tf,1),iLow(_Symbol,g_s.tf,1));

   if(OpenCount()>0 && (newBar || !g_s.manageOnBarClose))
      g_dtp.Manage(g_trade,g_risk,g_entry);

   CheckClosedPosition();
   ManagePending();   // detect CHoCH limit fills / cancel on timeout

   // bar-close work
   if(newBar)
     {
      // live 4H range box during its 20:00->00:00 window (outside sessions);
      // it persists and the Asia session reuses the same object key
      UpdateRangeBox(now);

      // VWAP first, then the auto-bias it feeds — both run before the
      // detection branch so a session can arm and act on the same bar
      UpdateVwap(now);
      UpdateAutoBias(now);

      // A working limit always owns the bar: it is the setup in progress, so
      // it trails on new BOS and no fresh detection runs beside it.
      // Otherwise detection is blocked only while a position still carries
      // real risk — with addWhenBreakEven, positions already at break-even
      // let the hunt continue (see CanOpenAnother).
      if(g_pendingTicket!=0)
        {
         TrailPendingOnNewBos(now);
         g_state.note=(g_bosCount>1)
                      ?StringFormat("limit pending (BOS %d, order on prev BOS)",g_bosCount)
                      :"limit pending";
        }
      else if(OpenCount()>0 && !CanOpenAnother())
        {
         g_state.note=(OpenCount()>1)
                      ?StringFormat("managing %d positions",OpenCount())
                      :"managing position";
        }
      else
        {
         EvaluateAndAct(now);
         UpdateVisuals(now);

         ENUM_SESSION ses=g_session.CurrentSession(now);
         if(ses!=SESSION_NONE)
           {
            UpdateSwings(g_session.SessionStartServer(now)); // in-session structure only
            UpdateLivePatterns(now);
           }
         else
            g_visuals.ClearFVGs(0,InpMaxFVGs); // wipe stale patterns out of session
        }
     }

   RefreshDashboardLive(); // keep bias/session/position live every tick
  }
//+------------------------------------------------------------------+
