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
   SESSION_NONE = 0,
   SESSION_ASIA = 1,
   SESSION_NY   = 2
  };

//--- Entry confirmation model selection
enum ENUM_ENTRY_MODEL
  {
   ENTRY_CHOCH_FIRST = 0, // CHoCH primary, IFVG fallback (default)
   ENTRY_CHOCH_ONLY  = 1,
   ENTRY_IFVG_ONLY   = 2,
   ENTRY_EITHER      = 3  // whichever fires first
  };

//--- Where the initial stop loss is anchored
enum ENUM_SL_ANCHOR
  {
   SL_ANCHOR_CHOCH_LEG  = 0, // CHoCH breaking-leg extreme (IFVG falls back to sweep wick)
   SL_ANCHOR_SWEEP_WICK = 1  // Sweep wick (session extreme of the sweeping leg)
  };

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
   int               dayCloseHourRiyadh;      // anchor for prior-day 4h range
   int               rangeLengthHours;        // Asia range length (4)
   int               entryWindowMinutes;      // entry window from session open
   // Structure
   int               swingStrength;           // N candles each side (sweep target swings)
   int               chochSwing;              // N for the CHoCH reaction high/low (smaller = catches faster breaks)
   ENUM_ENTRY_MODEL  entryModel;
   double            chochEntryRetrace;       // CHoCH limit retrace of breaking leg (0.25)
   double            preSweepHours;           // how far left of session open to look for the low/high to sweep
   // Risk
   double            riskPercent;             // 0.95
   ENUM_SL_ANCHOR    slAnchor;                // CHoCH leg extreme vs sweep wick
   double            slBufferPoints;          // pad beyond wick
   double            breakEvenAtPercent;      // 2.0
   // Targets
   double            defaultTargetPercent;    // 4.0
   double            maxTargetPercent;        // 10.0
   bool              usePartialTP;
   double            partialPercent;          // 50
   // Momentum
   double            momentumBodyATR;         // 1.3
   int               momentumStallBars;       // 3
   double            atrContractionFactor;    // 0.6
   double            trailPadPoints;
   // Caps
   int               maxTradesPerSession;     // 2
   bool              stopAfterFirstWin;       // true
   // Logging
   bool              writeJournal;
  };

//+------------------------------------------------------------------+
//| Live strategy state, fed to the on-chart dashboard               |
//+------------------------------------------------------------------+
struct SStratState
  {
   ENUM_BIAS    bias;
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
   bool         positionOpen;
   double       floatPct;
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

#endif // SESSIONS_STRATEGY_COMMON_MQH
