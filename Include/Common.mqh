//+------------------------------------------------------------------+
//|                                                       Common.mqh  |
//|         Shared enums, settings struct and helpers for the EA      |
//+------------------------------------------------------------------+
#ifndef SESSIONS_STRATEGY_COMMON_MQH
#define SESSIONS_STRATEGY_COMMON_MQH

//--- Directional bias the trader arms each session
enum ENUM_BIAS
  {
   BIAS_NONE = 0,   // No trading armed
   BIAS_BUY  = 1,   // Long bias
   BIAS_SELL = 2    // Short bias
  };

//--- Which approved session a timestamp belongs to
enum ENUM_SESSION
  {
   SESSION_NONE   = 0,
   SESSION_ASIA   = 1,
   SESSION_NY     = 2,
   SESSION_LONDON = 3
  };

//--- Entry confirmation model selection
enum ENUM_ENTRY_MODEL
  {
   ENTRY_CHOCH_FIRST = 0, // CHoCH primary, IFVG fallback
   ENTRY_CHOCH_ONLY  = 1,
   ENTRY_IFVG_ONLY   = 2,
   ENTRY_EITHER      = 3  // whichever fires first; same-bar tie -> IFVG wins
  };

//--- Where the initial stop loss is anchored
enum ENUM_SL_ANCHOR
  {
   SL_ANCHOR_CHOCH_LEG  = 0, // Entry-pattern extreme (CHoCH breaking leg / IFVG reclaim leg)
   SL_ANCHOR_SWEEP_WICK = 1  // Sweep wick (session extreme of the sweeping leg)
  };

//--- Where the session direction comes from (charter rule 17)
enum ENUM_BIAS_MODE
  {
   BIAS_MODE_MANUAL = 0, // Trader arms the panel (charter rule 17)
   BIAS_MODE_VWAP   = 1  // Auto: session opens above VWAP -> BUY, below -> SELL
  };

//--- VWAP anchor period (Pine "Session" = a daily reset)
enum ENUM_VWAP_ANCHOR
  {
   VWAP_ANCHOR_DAY  = 0, // Reset each Riyadh day-close hour
   VWAP_ANCHOR_WEEK = 1  // Reset each Monday
  };

//--- VWAP price source (Pine 'src', default hlc3)
enum ENUM_VWAP_SOURCE
  {
   VWAP_SRC_HLC3  = 0, // (H+L+C)/3
   VWAP_SRC_CLOSE = 1,
   VWAP_SRC_HL2   = 2, // (H+L)/2
   VWAP_SRC_OHLC4 = 3  // (O+H+L+C)/4
  };

//--- Hard ceiling on concurrently tracked positions. Sizes the slot arrays in
//--- the main EA and in CDynamicTP; maxOpenPositions is clamped to it.
#define SS_MAX_OPEN 8

//--- Unit for risk AND for every target threshold. Both move together on
//--- purpose: sizing in fixed money while targets stay a % of a growing
//--- balance would let the reward-to-risk ratio drift as the account grows.
enum ENUM_RISK_MODE
  {
   RISK_MODE_PERCENT = 0, // % of account balance
   RISK_MODE_MONEY   = 1  // Fixed money amount (account currency)
  };

//--- Which directions may be added on top of an existing break-even position
enum ENUM_ADD_DIRECTION
  {
   ADD_DIR_BOTH    = 0, // Same or counter direction
   ADD_DIR_COUNTER = 1, // Counter-direction only (hedge the BE position)
   ADD_DIR_SAME    = 2  // Same-direction only (scale in)
  };

//--- How a position ended. Broker-side fills come from DEAL_REASON; the
//--- EA-initiated closes are stamped by CDynamicTP before it closes.
enum ENUM_EXIT_REASON
  {
   EXIT_UNKNOWN        = 0,
   EXIT_TAKE_PROFIT    = 1, // broker TP
   EXIT_STOP_LOSS      = 2, // broker SL, still at the original stop
   EXIT_BREAK_EVEN     = 3, // broker SL, moved to entry
   EXIT_TRAIL_STOP     = 4, // broker SL, trailed past entry
   EXIT_CAP            = 5, // DynamicTP hit MaxTargetMoney()
   EXIT_OPPOSING_CHOCH = 6, // DynamicTP saw a reversal
   EXIT_END_OF_TEST    = 7  // still open when the run ended
  };

string ExitReasonName(const ENUM_EXIT_REASON r)
  {
   switch(r)
     {
      case EXIT_TAKE_PROFIT:    return("TAKE_PROFIT");
      case EXIT_STOP_LOSS:      return("STOP_LOSS");
      case EXIT_BREAK_EVEN:     return("BREAK_EVEN");
      case EXIT_TRAIL_STOP:     return("TRAIL_STOP");
      case EXIT_CAP:            return("CAP");
      case EXIT_OPPOSING_CHOCH: return("OPPOSING_CHOCH");
      case EXIT_END_OF_TEST:    return("END_OF_TEST");
     }
   return("UNKNOWN");
  }

//--- Counterfactual state: after an early exit, would the ORIGINAL SL/TP
//--- have resolved as a win or a loss?
enum ENUM_CF_STATE
  {
   CF_NA         = 0, // exited at its own TP or SL - nothing to ask
   CF_WATCHING   = 1,
   CF_WOULD_WIN  = 2,
   CF_WOULD_LOSE = 3,
   CF_UNRESOLVED = 4  // watch window expired
  };

string CfStateName(const ENUM_CF_STATE c)
  {
   switch(c)
     {
      case CF_WATCHING:   return("WATCHING");
      case CF_WOULD_WIN:  return("WOULD_WIN");
      case CF_WOULD_LOSE: return("WOULD_LOSE");
      case CF_UNRESOLVED: return("UNRESOLVED");
     }
   return("NA");
  }

//--- Per-trade outcome bookkeeping for session caps
enum ENUM_TRADE_RESULT
  {
   RESULT_OPEN = 0,
   RESULT_WIN  = 1,
   RESULT_LOSS = 2
  };

//+------------------------------------------------------------------+
//| All tunable settings, filled from inputs in the main EA          |
//+------------------------------------------------------------------+
struct SSettings
  {
   // General
   ENUM_TIMEFRAMES   tf;                      // working timeframe (M2)
   long              magic;                   // EA magic number
   // Timezone / sessions (Riyadh local time)
   double            brokerToRiyadhOffsetHr;  // server -> Riyadh hours
   int               asiaStartMin;            // minutes from midnight (Riyadh)
   int               asiaEndMin;
   int               nyStartMin;
   int               nyEndMin;
   bool              useLondon;               // London session enabled?
   int               londonStartMin;
   int               londonEndMin;
   int               dayCloseHourRiyadh;      // anchor for prior-day 4h range
   int               rangeLengthHours;        // Asia range length (4)
   int               entryWindowMinutes;      // entry window from session open
   // Structure
   int               swingStrength;           // N candles each side (sweep target swings)
   int               chochSwing;              // N for the CHoCH reaction high/low (smaller = catches faster breaks)
   ENUM_ENTRY_MODEL  entryModel;
   double            chochEntryRetrace;       // CHoCH limit retrace of breaking leg (0.25)
   double            preSweepHours;           // how far left of session open to look for the low/high to sweep
   double            detectPreHours;          // CHoCH/IFVG structure may reference bars this far before session open
   // Bias source
   ENUM_BIAS_MODE    biasMode;                // manual panel vs VWAP auto-bias
   ENUM_VWAP_ANCHOR  vwapAnchor;              // VWAP reset period
   ENUM_VWAP_SOURCE  vwapSource;              // VWAP price source (hlc3)
   // Risk. riskMode picks which column of the pairs below is live; read them
   // through CRiskManager (RiskMoney / BreakEvenMoney / DefaultTargetMoney /
   // MaxTargetMoney) rather than touching the fields directly.
   ENUM_RISK_MODE    riskMode;                // % of balance vs fixed money
   double            riskPercent;             // 0.5   [PERCENT mode]
   double            riskMoney;               // 500   [MONEY mode]
   ENUM_SL_ANCHOR    slAnchor;                // CHoCH leg extreme vs sweep wick
   double            slBufferPoints;          // pad beyond wick
   double            breakEvenAtPercent;      // 0.25  (~0.5R at riskPercent 0.5)
   double            breakEvenAtMoney;        // 250   [MONEY mode]
   // Targets
   double            defaultTargetPercent;    // 5.0
   double            defaultTargetMoney;      // 5000  [MONEY mode]
   double            maxTargetPercent;        // 5.0 - equal to the default target, so the
                                              // partial and the structure trail below the
                                              // cap check in DynamicTP are unreachable
   double            maxTargetMoney;          // 5000  [MONEY mode]
   bool              usePartialTP;            // false
   double            partialPercent;          // 50
   // Momentum
   double            momentumBodyATR;         // 1.3
   int               momentumStallBars;       // 3
   double            atrContractionFactor;    // 0.6
   double            trailPadPoints;
   // Management cadence
   bool              manageOnBarClose;        // run DynamicTP on new bar only (default true)
   // Adding on top of a risk-free position
   bool              addWhenBreakEven;        // allow a 2nd+ position once every open one is at BE
   ENUM_ADD_DIRECTION addDirection;           // which directions may be added
   int               maxOpenPositions;        // ceiling on concurrent positions (1..SS_MAX_OPEN)
   // Caps
   int               maxTradesPerSession;     // 3
   bool              stopAfterFirstWin;       // true
   bool              tradeMonday;             // allow trading on Monday
   bool              tradeFriday;             // allow trading on Friday
   // Logging
   bool              writeJournal;
  };

//+------------------------------------------------------------------+
//| Live strategy state, fed to the on-chart dashboard               |
//+------------------------------------------------------------------+
struct SStratState
  {
   ENUM_BIAS    bias;
   bool         biasAuto;      // bias came from the VWAP rule, not the panel
   double       vwap;          // live VWAP value
   double       vwapAtOpen;    // VWAP carried into the session (decision input)
   double       sessionOpen;   // open price of the session's first bar
   ENUM_SESSION session;
   bool         inWindow;
   bool         rangeValid;
   double       rangeHi;
   double       rangeLo;
   bool         rangeExited;
   bool         swept;
   double       sweptLevel;
   double       sweepWick;
   bool         entryMet;
   string       entryModel;
   double       entryPrice;
   bool         entryIsLimit;
   int          trades;
   int          wins;
   bool         canOpen;
   int          maxTrades;
   bool         dayAllowed;
   bool         positionOpen;
   int          openCount;    // concurrently open positions
   bool         allAtBE;      // every open position has its SL at break-even or better
   double       floatPct;     // summed floating P/L of all open positions
   bool         pending;
   string       note;
  };

//+------------------------------------------------------------------+
//| Convert current server time to Riyadh time                       |
//+------------------------------------------------------------------+
datetime ToRiyadh(const datetime serverTime,const SSettings &s)
  {
   return(serverTime + (datetime)(s.brokerToRiyadhOffsetHr*3600.0));
  }

//+------------------------------------------------------------------+
//| Convert a Riyadh time back to server time                        |
//+------------------------------------------------------------------+
datetime FromRiyadh(const datetime riyadhTime,const SSettings &s)
  {
   return(riyadhTime - (datetime)(s.brokerToRiyadhOffsetHr*3600.0));
  }

//+------------------------------------------------------------------+
//| Minutes elapsed since Riyadh midnight for a given time           |
//+------------------------------------------------------------------+
int RiyadhMinuteOfDay(const datetime riyadhTime)
  {
   MqlDateTime dt;
   TimeToStruct(riyadhTime,dt);
   return(dt.hour*60+dt.min);
  }

//+------------------------------------------------------------------+
//| Short English name of a session (logs, dashboard, box labels)    |
//+------------------------------------------------------------------+
string SessionName(const ENUM_SESSION ses)
  {
   switch(ses)
     {
      case SESSION_ASIA:   return("ASIA");
      case SESSION_LONDON: return("LONDON");
      case SESSION_NY:     return("NY");
     }
   return("-");
  }

//+------------------------------------------------------------------+
//| English week-day name of a given time                            |
//+------------------------------------------------------------------+
string DayOfWeekName(const datetime t)
  {
   string names[7]={"Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"};
   MqlDateTime dt; TimeToStruct(t,dt);
   return(names[dt.day_of_week]);
  }

#endif // SESSIONS_STRATEGY_COMMON_MQH
