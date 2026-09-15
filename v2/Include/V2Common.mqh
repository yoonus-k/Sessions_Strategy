//+------------------------------------------------------------------+
//|                                                     V2Common.mqh  |
//|  Shared enums, the SSettingsV2 tunable struct, and small time /   |
//|  math helpers for the Anchored-VWAP Sessions EA (v2).             |
//|                                                                   |
//|  See v2/doc/IMPLEMENTATION_PLAN.md and                            |
//|      v2/doc/Anchored_VWAP_Sessions_EA_Spec.md                     |
//|                                                                   |
//|  Convention: modules never place orders. A new tunable = a field  |
//|  here + an input in the consumer + a line in its BuildSettings()  |
//|  + a row in the plan's parameter table.                           |
//+------------------------------------------------------------------+
#ifndef V2_COMMON_MQH
#define V2_COMMON_MQH

//====================================================================
//  ENUMS
//====================================================================

//--- The three intraday windows (Riyadh time). Disjoint by construction.
enum ENUM_SESSION_V2
  {
   SESS_NONE   = 0,
   SESS_ASIA   = 1,
   SESS_LONDON = 2,
   SESS_NY     = 3
  };

//--- What a session is allowed to do this EA.
enum ENUM_SESSION_ROLE
  {
   ROLE_OFF         = 0, // ignored entirely
   ROLE_ANCHOR_ONLY = 1, // may supply a VWAP anchor, never trades (London)
   ROLE_TRADE       = 2  // trades AND may supply an anchor (Asia, NY)
  };

//--- How session clock times are interpreted.
enum ENUM_SESSION_TIME_MODE
  {
   STM_FIXED_RIYADH = 0, // fixed Riyadh local time (UTC+3, no DST)
   STM_TRACK_MARKET = 1  // follow the market's own DST (not used yet)
  };

//--- DST rule set for the BROKER server clock (Riyadh itself never shifts).
enum ENUM_DST_CALENDAR
  {
   DSTCAL_NONE = 0,
   DSTCAL_US   = 1, // 2nd Sunday Mar .. 1st Sunday Nov
   DSTCAL_EU   = 2  // last Sunday Mar .. last Sunday Oct
  };

//--- Directional stance / trade direction.
enum ENUM_DIR_V2
  {
   DIR_NONE  = 0,
   DIR_LONG  = 1,
   DIR_SHORT = -1
  };

//--- Price zone versus the anchored VWAP and its bands.
enum ENUM_ZONE_V2
  {
   ZONE_NONE = 0,
   ZONE_Z1   = 1, // |d| < 1s   : direct / committed trend
   ZONE_Z2   = 2, // 1s..2s     : confirmation / contested (flip-enabled)
   ZONE_Z3   = 3  // |d| >= 2s  : extended / committed reversion
  };

//--- VWAP price source (Pine 'src').
enum ENUM_PRICE_INPUT_V2
  {
   PI_HLC3  = 0,
   PI_CLOSE = 1,
   PI_HL2   = 2,
   PI_OHLC4 = 3
  };

//--- Volume series for the VWAP / sigma sums.
enum ENUM_VOLUME_SRC_V2
  {
   VS_TICK = 0, // tick_volume (gold: the only meaningful one)
   VS_REAL = 1  // real_volume, falls back to tick when the feed is all-zero
  };

//--- Session-quality decision method.
enum ENUM_QUALITY_MODE_V2
  {
   QM_SCORE = 0, // weighted score, pass >= threshold
   QM_GATES = 1  // every enabled threshold must pass
  };

//--- What to do when no volatile prior session is found within the lookback.
enum ENUM_NO_ANCHOR_V2
  {
   NA_SKIP_SESSION = 0
  };

//--- Which trigger families are hunted.
enum ENUM_ENTRY_MODE_V2
  {
   EM_BOS_ONLY      = 0,
   EM_REVERSAL_ONLY = 1,
   EM_BOTH          = 2
  };

//--- How a BOS is confirmed.
enum ENUM_BOS_CONFIRM_V2
  {
   BC_CLOSE = 0, // close beyond the swing by >= buffer
   BC_WICK  = 1  // wick beyond is enough
  };

//--- Which price a triggered market entry uses.
enum ENUM_ENTRY_FILL_V2
  {
   EF_BOS_CLOSE = 0, // the trigger bar's close
   EF_NEXT_OPEN = 1  // next bar open
  };

//--- How the stop buffer beyond the protected extreme is sized.
enum ENUM_SL_BUFFER_MODE_V2
  {
   SLB_PCT_OF_LEG = 0, // fraction of the trigger leg range
   SLB_ATR        = 1, // multiple of ATR
   SLB_POINTS     = 2  // fixed points
  };

//--- Position sizing unit.
enum ENUM_RISK_MODE_V2
  {
   RM_PERCENT   = 0, // % of balance, lots derived from R
   RM_FIXED_LOT = 1
  };

//--- How a position ended.
enum ENUM_EXIT_REASON_V2
  {
   XR_NONE        = 0,
   XR_TP          = 1,
   XR_SL          = 2,
   XR_FORCE_CLOSE = 3,
   XR_END_OF_TEST = 4
  };

//====================================================================
//  SETTINGS  (filled by each .mq5's BuildSettingsV2())
//  Sections are populated as their owning modules are built.
//====================================================================
struct SSettingsV2
  {
   //--- General -----------------------------------------------------
   ENUM_TIMEFRAMES        tf;                    // base timeframe (M5)
   long                   magic;

   //--- Time / sessions ------------------------------------------------
   ENUM_SESSION_TIME_MODE sessionTimeMode;
   double                 brokerWinterOffsetHr;  // broker = UTC + this, in winter/standard time
   bool                   brokerObservesDST;
   ENUM_DST_CALENDAR      brokerDSTCalendar;

   bool                   asiaEnabled;   ENUM_SESSION_ROLE asiaRole;   int asiaStartMin;   int asiaEndMin;
   bool                   londonEnabled; ENUM_SESSION_ROLE londonRole; int londonStartMin; int londonEndMin;
   bool                   nyEnabled;     ENUM_SESSION_ROLE nyRole;     int nyStartMin;     int nyEndMin;

   int                    noNewEntryOffsetSec;    // no entries in the last N sec of a session
   int                    entryWindowMinutes;     // 30  no NEW trade after this many minutes since session open; 0 = unlimited
   int                    forceCloseOffsetSec;    // flat this many sec before session end
   bool                   closeOnSessionEnd;

   //--- AVWAP + sigma bands ------------------------------------------
   ENUM_PRICE_INPUT_V2    priceInput;             // HLC3
   ENUM_VOLUME_SRC_V2     volumeSrc;              // tick volume
   double                 band1Mult;              // 1.0
   double                 band2Mult;              // 2.0
   int                    minBarsSinceAnchor;     // 5 - suppress band logic until warm

   //--- ZigZag (anchor-pivot detector) -----------------------------
   int                    zzDepth;                // 24
   int                    zzDeviation;            // 5  (points)
   int                    zzBackstep;             // 2
   int                    atrPeriod;              // 14 (shared with SessionQuality)

   //--- Fractals / BOS (structure detector) -----------------------
   int                    bosSwingDepth;          // 3  (bars each side of a fractal)
   int                    bosBufferPoints;        // 0  (extra points beyond the swing)
   ENUM_BOS_CONFIRM_V2    bosConfirmMode;         // BC_CLOSE

   //--- Session-quality / volatility classifier (relative) -------
   ENUM_QUALITY_MODE_V2   qualityMode;            // QM_SCORE
   double                 qualityScoreThreshold;  // 0.60
   int                    qualityBaselineN;       // 20 (prior same-type sessions)
   double                 minRangeRatio;          // 0.70  range / baseline (confirm-only, never blocks - see SessionQuality.mqh)
   double                 minRangeAtr;            // 3.0   range / ATR
   double                 minLegAtr;              // 1.5   largest ZZ leg / ATR
   double                 minEfficiency;          // 0.30  Kaufman efficiency ratio
   double                 impulseBarAtrMult;      // 0.8   a bar counts as "impulse" if range >= this*ATR
   int                    minImpulseBars;         // 2     anti-single-spike gate (GATES mode)
   double                 wLeg;                   // 0.35  SCORE weights
   double                 wEff;                   // 0.30
   double                 wRangeBase;             // 0.20
   double                 wRangeAtr;              // 0.15

   //--- Anchor selection (SessionQuality + ZigZag -> chosen VWAP anchor) --
   double                 maxAnchorLookbackHr;    // 48   how far back to search for a qualifying session
   double                 anchorFlexMin;          // 120  pivot search window = [source session open, close+this]
   double                 anchorPreRollMin;       // 30   re-select/re-anchor this many minutes BEFORE the
                                                   //      trade session opens, so AVWAP has a head start
   ENUM_NO_ANCHOR_V2      noAnchorAction;         // NA_SKIP_SESSION (only option so far)

   //--- Zone classifier (price vs AVWAP+sigma bands -> Z1/Z2/Z3) -----
   int                    confirmStateMaxBars;    // 12  Z2 CONFIRMING counter wraps back to 1 after this many bars

   //--- Rejection / breakthrough primitives (spec Sec9.1) ------------
   double                 touchTolSigma;          // 0.10  band-touch tolerance, in sigma
   double                 rejectCloseSigma;       // 0.05  how far back past the band the close must be
   bool                   rejectRequireWick;      // true  require a real rejection wick
   double                 rejectWickMinFrac;      // 0.5   min wick / bar-range fraction
   double                 breakBufferSigma;       // 0.15  how far past the band the close must clear
   bool                   breakRequireMomentum;   // true  require a body >= breakBodyAtr*ATR
   double                 breakBodyAtr;           // 0.8   min body, in ATR, for a valid break

   //--- Triggers: BOS (delegates to Fractals.mqh's bosSwingDepth/       --
   //--- bosBufferPoints/bosConfirmMode above) + Reversal+Momentum ------
   ENUM_ENTRY_MODE_V2     entryMode;              // EM_BOTH
   ENUM_ENTRY_FILL_V2     entryFillMode;          // EF_BOS_CLOSE  (applied to BOTH trigger types here)
   int                    revCounterLookback;     // 8    bars searched for the counter-move / revLow|revHigh
   double                 revMinCounterMoveAtr;   // 0.8  min counter-move size, in ATR
   double                 revBodyAtr;             // 1.0  min momentum-candle body, in ATR
   double                 revCloseLocPct;         // 0.33 close must sit in the top/bottom this fraction of its range
   bool                   revRequireEngulf;       // false
   int                    revBreakBars;           // 2    "close breaks last N highs/lows" alt confirmation
   int                    revConfirmCloses;       // 1    confirming closes required before the trigger fires

   //--- ZoneEngine: the per-bar decision resolver (spec Sec14) --------
   bool                   allowFlipInDirectZone;   // false  Z1: take the opposing trigger if the committed one never fires
   bool                   allowFlipInExtendedZone; // false  Z3: same, for the reversion direction

   //--- Risk / SL / TP / sizing (spec Sec10) --------------------------
   double                 rr;                     // 1.5   TP = entry +/- rr * R
   ENUM_SL_BUFFER_MODE_V2 slBufferMode;           // SLB_PCT_OF_LEG
   double                 slBufferPct;            // 0.10  x legRange (PCT_OF_LEG mode)
   double                 slBufferAtrMult;        // 0.0   x ATR      (ATR mode)
   double                 slBufferPoints;         // 0.0   fixed points (POINTS mode)
   double                 minStopAtrMult;         // 0.0   floor: widen SL to at least this many ATR if closer
   bool                   clampStopsToBroker;     // true  widen SL to the broker's SYMBOL_TRADE_STOPS_LEVEL
   ENUM_RISK_MODE_V2      riskMode;               // RM_PERCENT
   double                 riskPercent;            // 0.5
   double                 fixedLot;               // 0.01  (RM_FIXED_LOT mode)

   //--- Trade & session management (spec Sec11) -----------------------
   int                    maxTriesPerSession;      // 2
   bool                   secondTryOnlyAfterSl;    // true  2nd attempt only if the 1st stopped out
   bool                   allowReentryAfterWin;    // false a win closes the session
   int                    maxSpreadPoints;         // 50
   int                    maxSlippagePoints;       // 20
   bool                   beEnabled;               // true  move SL to entry once price reaches beTriggerR*R
   double                 beTriggerR;              // 0.5   R-multiple (of the trade's OWN entry->SL distance) that arms breakeven

   //--- (later sections:
   //---  Entries, Risk, Management, Diagnostics)
  };

//====================================================================
//  SMALL HELPERS
//====================================================================

//--- "HH:MM" -> minutes from midnight. Returns 0 on a malformed string.
int V2_ParseHM(const string hm)
  {
   string parts[];
   int k=StringSplit(hm,(ushort)':',parts);
   if(k<2) return(0);
   int h=(int)StringToInteger(parts[0]);
   int m=(int)StringToInteger(parts[1]);
   if(h<0) h=0; if(h>23) h=23;
   if(m<0) m=0; if(m>59) m=59;
   return(h*60+m);
  }

//--- Minutes elapsed since local midnight for a given time value.
int V2_MinuteOfDay(const datetime t)
  {
   MqlDateTime dt; TimeToStruct(t,dt);
   return(dt.hour*60+dt.min);
  }

//--- Local midnight of the day that contains 't'.
datetime V2_Midnight(const datetime t)
  {
   MqlDateTime dt; TimeToStruct(t,dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   return(StructToTime(dt));
  }

//--- Days in a Gregorian month.
int V2_DaysInMonth(const int year,const int month)
  {
   int dim[]={31,28,31,30,31,30,31,31,30,31,30,31};
   int d=dim[(month-1)%12];
   if(month==2 && ((year%4==0 && year%100!=0) || year%400==0)) d=29;
   return(d);
  }

//--- 00:00 UTC of the n-th Sunday (n=1..5) of a month.
datetime V2_NthSunday(const int year,const int month,const int nth)
  {
   MqlDateTime dt; dt.year=year; dt.mon=month; dt.day=1;
   dt.hour=0; dt.min=0; dt.sec=0;
   datetime first=StructToTime(dt);
   MqlDateTime f; TimeToStruct(first,f);
   int dow=f.day_of_week;                 // 0 = Sunday
   int firstSun=(dow==0)?1:(8-dow);
   int day=firstSun+(nth-1)*7;
   int dim=V2_DaysInMonth(year,month);
   if(day>dim) day-=7;
   dt.day=day;
   return(StructToTime(dt));
  }

//--- 00:00 UTC of the last Sunday of a month.
datetime V2_LastSunday(const int year,const int month)
  {
   int dim=V2_DaysInMonth(year,month);
   MqlDateTime dt; dt.year=year; dt.mon=month; dt.day=dim;
   dt.hour=0; dt.min=0; dt.sec=0;
   datetime last=StructToTime(dt);
   MqlDateTime l; TimeToStruct(last,l);
   int dow=l.day_of_week;                 // 0 = Sunday
   int day=dim-dow;
   dt.day=day;
   return(StructToTime(dt));
  }

//--- Is DST in effect at UTC time 'utc' for the given calendar?
//    Transition hours approximated at the wall-clock changeover:
//    US ~07:00 UTC, EU 01:00 UTC. A one-hour ambiguity at the exact
//    switch is acceptable for a session EA that trades hours later.
bool V2_DstActive(const ENUM_DST_CALENDAR cal,const datetime utc)
  {
   if(cal==DSTCAL_NONE) return(false);
   MqlDateTime dt; TimeToStruct(utc,dt);
   int y=dt.year;
   if(cal==DSTCAL_US)
     {
      datetime start=V2_NthSunday(y,3,2)+7*3600;
      datetime end  =V2_NthSunday(y,11,1)+6*3600;
      return(utc>=start && utc<end);
     }
   // EU
   datetime start=V2_LastSunday(y,3)+1*3600;
   datetime end  =V2_LastSunday(y,10)+1*3600;
   return(utc>=start && utc<end);
  }

//--- Short English name for a session.
string V2_SessionName(const ENUM_SESSION_V2 s)
  {
   switch(s)
     {
      case SESS_ASIA:   return("ASIA");
      case SESS_LONDON: return("LONDON");
      case SESS_NY:     return("NY");
     }
   return("-");
  }

string V2_RoleName(const ENUM_SESSION_ROLE r)
  {
   switch(r)
     {
      case ROLE_TRADE:       return("TRADE");
      case ROLE_ANCHOR_ONLY: return("ANCHOR");
     }
   return("OFF");
  }

string V2_DirName(const ENUM_DIR_V2 d)
  {
   if(d==DIR_LONG)  return("LONG");
   if(d==DIR_SHORT) return("SHORT");
   return("NONE");
  }

string V2_ZoneName(const ENUM_ZONE_V2 z)
  {
   switch(z)
     {
      case ZONE_Z1: return("Z1");
      case ZONE_Z2: return("Z2");
      case ZONE_Z3: return("Z3");
     }
   return("--");
  }

//--- name of the regime a session locked at open (ZoneEngine's
//--- regimeZone/regimeLocked, 2026-09-15 regime-lock redesign) - distinct
//--- from V2_ZoneName(), which names the LIVE zone at a given bar.
string V2_RegimeName(const ENUM_ZONE_V2 regimeZone,const bool regimeLocked)
  {
   if(!regimeLocked) return("NOT_CAPTURED");
   switch(regimeZone)
     {
      case ZONE_Z1: return("CONTINUATION");
      case ZONE_Z3: return("REVERSAL");
      case ZONE_Z2: return("CONFIRMATION");
     }
   return("-");
  }

string V2_DayName(const datetime t)
  {
   string n[7]={"Sun","Mon","Tue","Wed","Thu","Fri","Sat"};
   MqlDateTime dt; TimeToStruct(t,dt);
   return(n[dt.day_of_week]);
  }

#endif // V2_COMMON_MQH
