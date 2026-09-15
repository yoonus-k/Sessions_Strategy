//+------------------------------------------------------------------+
//|                                                     Triggers.mqh  |
//|  P3 - the two entry trigger types (spec §9.2/§9.3), each queried  |
//|  per direction: "is there a LONG trigger this bar?" / "a SHORT    |
//|  trigger?" Call Refresh()+Update() once per closed bar, then      |
//|  Query(dir) as many times as needed (ZoneEngine asks both ways).  |
//|                                                                   |
//|  Entry Type A - BOS: owns a private CFractals instance (BOS IS    |
//|  fractal-structure-break, per spec "delegate to Fractals.mqh" -   |
//|  this is Triggers' internal machinery, not a peer the caller      |
//|  wires up, unlike AVWAP/ZigZag/SessionQuality). Reuses            |
//|  bosSwingDepth/bosBufferPoints/bosConfirmMode already in          |
//|  SSettingsV2 for Fractals.mqh - no duplicated settings.           |
//|                                                                   |
//|  Entry Type B - Reversal+Momentum (spec §9.3), evaluated on       |
//|  closed bars independently per direction:                         |
//|   1. counter-move: within revCounterLookback bars, size (window   |
//|      high/low span) >= revMinCounterMoveAtr*ATR, ending at a      |
//|      local extreme revLow/revHigh.                                |
//|   2. momentum candle: body >= revBodyAtr*ATR, close in the        |
//|      top/bottom revCloseLocPct of its own range, AND EITHER an    |
//|      engulfing candle (revRequireEngulf) OR a close beyond the    |
//|      last revBreakBars highs/lows (the spec's "or" alternative).  |
//|   3. revConfirmCloses confirming closes with the extreme holding  |
//|      (>1 arms a small pending state that must survive N-1 more    |
//|      bars before firing; the default of 1 fires immediately on    |
//|      the momentum candle itself, same as BOS).                    |
//|                                                                   |
//|  entryFillMode (BOS_CLOSE vs NEXT_OPEN) is applied to BOTH types  |
//|  here for consistency, even though spec §9.2 only names it under  |
//|  BOS - a documented extrapolation, not a spec quote.              |
//|                                                                   |
//|  Pure detection - never places orders.                           |
//+------------------------------------------------------------------+
#ifndef V2_TRIGGERS_MQH
#define V2_TRIGGERS_MQH

#include "V2Common.mqh"
#include "Fractals.mqh"

struct STriggerEvent
  {
   bool        valid;
   string      type;             // "BOS" | "REV"
   ENUM_DIR_V2 dir;
   double      entryPrice;
   datetime    entryTime;        // barTime (BOS_CLOSE fill) or barTime+1 bar (NEXT_OPEN fill)
   double      protectedExtreme; // BOS: legLow(long)/legHigh(short). REV: revLow/revHigh.
   double      legRange;
   datetime    barTime;          // the bar the pattern's core signal closed on
   datetime    legFromTime;      // leg span, for a "shade the leg" overlay
   datetime    legToTime;
  };

struct SDiagTriggers
  {
   STriggerEvent last;
   bool          hasLast;
   int           countThisSession;
   double        atr;
   double        lastLegRangeAtr; // 0 if atr<=0
  };

class CTriggers
  {
private:
   SSettingsV2   m_s;
   string        m_sym;
   CFractals     m_fr;
   int           m_atrHandle;

   int           m_countSession;
   STriggerEvent m_last;
   bool          m_hasLast;

   STriggerEvent m_bosThisBar;
   STriggerEvent m_revLongThisBar;
   STriggerEvent m_revShortThisBar;

   struct SRevPending
     {
      bool     active;
      double   extreme;      // revLow (long) / revHigh (short) - frozen at arm time
      double   entryClose;   // momentum candle's close - frozen (BOS_CLOSE fill)
      double   entryNextOpen;// bar-after-momentum-candle's open - frozen (NEXT_OPEN fill)
      double   legHigh, legLow;
      datetime barTime;      // momentum candle's time
      int      closesHeld;
     };
   SRevPending m_revLongPending, m_revShortPending;

   double ATR() const
     {
      if(m_atrHandle==INVALID_HANDLE) return(0.0);
      double a[]; ArraySetAsSeries(a,true);
      if(CopyBuffer(m_atrHandle,0,0,2,a)<1) return(0.0);
      return(a[0]);
     }

   double BullBody(const MqlRates &bar) const { return((bar.close>bar.open)?(bar.close-bar.open):0.0); }
   double BearBody(const MqlRates &bar) const { return((bar.close<bar.open)?(bar.open-bar.close):0.0); }

   double EntryPrice(const double closeFill,const double nextOpenFill) const
     {
      return((m_s.entryFillMode==EF_NEXT_OPEN)?nextOpenFill:closeFill);
     }

   //+--------------------------------------------------------------+
   //| Look for a FRESH long-reversal candidate on the just-closed    |
   //| bar (r[1]). r is series-ordered (r[0]=forming, r[1]=newest      |
   //| closed, ..., r[n-1]=oldest).                                    |
   //+--------------------------------------------------------------+
   bool ScanReversalLong(const MqlRates &r[],const int n,const double atr,
                        double &revLow,double &legHigh,double &entryClose,double &entryNextOpen) const
     {
      int look=MathMax(1,m_s.revCounterLookback);
      if(n<look+3) return(false);

      double winHi=-DBL_MAX, winLo=DBL_MAX;
      for(int i=1;i<=look && i<n;i++)
        {
         if(r[i].high>winHi) winHi=r[i].high;
         if(r[i].low <winLo) winLo=r[i].low;
        }
      if(winHi<=-DBL_MAX || winLo>=DBL_MAX) return(false);
      if(atr<=0.0 || (winHi-winLo)<m_s.revMinCounterMoveAtr*atr) return(false);

      MqlRates mc=r[1]; // momentum candle = the bar that just closed
      double range=mc.high-mc.low;
      if(range<=0.0) return(false);
      double body=BullBody(mc);
      if(atr<=0.0 || body<m_s.revBodyAtr*atr) return(false);
      double closeLoc=(mc.close-mc.low)/range;
      if(closeLoc<(1.0-m_s.revCloseLocPct)) return(false);

      bool cond2b=false;
      if(m_s.revRequireEngulf)
        {
         MqlRates pv=r[2];
         cond2b=(mc.close>mc.open && mc.open<=pv.close && mc.close>=pv.open);
        }
      else
        {
         int bb=MathMax(1,m_s.revBreakBars);
         double hh=-DBL_MAX;
         for(int i=2;i<=bb+1 && i<n;i++) if(r[i].high>hh) hh=r[i].high;
         cond2b=(hh>-DBL_MAX && mc.close>hh);
        }
      if(!cond2b) return(false);

      revLow=winLo; legHigh=winHi;
      entryClose=mc.close; entryNextOpen=r[0].open;
      return(true);
     }

   bool ScanReversalShort(const MqlRates &r[],const int n,const double atr,
                         double &revHigh,double &legLow,double &entryClose,double &entryNextOpen) const
     {
      int look=MathMax(1,m_s.revCounterLookback);
      if(n<look+3) return(false);

      double winHi=-DBL_MAX, winLo=DBL_MAX;
      for(int i=1;i<=look && i<n;i++)
        {
         if(r[i].high>winHi) winHi=r[i].high;
         if(r[i].low <winLo) winLo=r[i].low;
        }
      if(winHi<=-DBL_MAX || winLo>=DBL_MAX) return(false);
      if(atr<=0.0 || (winHi-winLo)<m_s.revMinCounterMoveAtr*atr) return(false);

      MqlRates mc=r[1];
      double range=mc.high-mc.low;
      if(range<=0.0) return(false);
      double body=BearBody(mc);
      if(atr<=0.0 || body<m_s.revBodyAtr*atr) return(false);
      double closeLoc=(mc.high-mc.close)/range; // distance from the top, mirrored
      if(closeLoc<(1.0-m_s.revCloseLocPct)) return(false);

      bool cond2b=false;
      if(m_s.revRequireEngulf)
        {
         MqlRates pv=r[2];
         cond2b=(mc.close<mc.open && mc.open>=pv.close && mc.close<=pv.open);
        }
      else
        {
         int bb=MathMax(1,m_s.revBreakBars);
         double ll=DBL_MAX;
         for(int i=2;i<=bb+1 && i<n;i++) if(r[i].low<ll) ll=r[i].low;
         cond2b=(ll<DBL_MAX && mc.close<ll);
        }
      if(!cond2b) return(false);

      revHigh=winHi; legLow=winLo;
      entryClose=mc.close; entryNextOpen=r[0].open;
      return(true);
     }

public:
   void Init(const SSettingsV2 &s,const string sym)
     {
      m_s=s; m_sym=sym;
      m_fr.Init(s,sym);
      m_atrHandle=(s.atrPeriod>0)?iATR(sym,s.tf,s.atrPeriod):INVALID_HANDLE;
      m_countSession=0; m_hasLast=false;
      m_bosThisBar.valid=false; m_revLongThisBar.valid=false; m_revShortThisBar.valid=false;
      m_revLongPending.active=false; m_revShortPending.active=false;
     }
   void Deinit()
     {
      m_fr.Deinit();
      if(m_atrHandle!=INVALID_HANDLE) IndicatorRelease(m_atrHandle);
     }

   //--- call once per session-key change
   void ResetSession()
     {
      m_fr.ResetSession();
      m_countSession=0; m_hasLast=false;
      m_revLongPending.active=false; m_revShortPending.active=false;
     }

   //--- call once per new bar, before Update()
   void RefreshStructure(){ m_fr.Refresh(); }

   //--- direct pass-through, for a test harness that wants to overlay
   //--- the raw fractal swings/BOS the same way T2b did
   CFractals *FractalsPtr(){ return(GetPointer(m_fr)); }

   //+--------------------------------------------------------------+
   //| Call once per newly CLOSED bar.                                |
   //+--------------------------------------------------------------+
   void Update()
     {
      m_bosThisBar.valid=false; m_revLongThisBar.valid=false; m_revShortThisBar.valid=false;
      double atr=ATR();

      // ---- Entry Type A: BOS ----
      if(m_s.entryMode==EM_BOS_ONLY || m_s.entryMode==EM_BOTH)
        {
         SBosEvent bos=m_fr.CheckBOS();
         if(bos.valid)
           {
            double closeFill=iClose(m_sym,m_s.tf,1);
            double nextOpenFill=iOpen(m_sym,m_s.tf,0);
            STriggerEvent ev;
            ev.valid=true; ev.type="BOS"; ev.dir=bos.dir;
            ev.protectedExtreme=(bos.dir==DIR_LONG)?bos.legLow:bos.legHigh;
            ev.legRange=bos.legRange; ev.barTime=bos.barTime;
            ev.legFromTime=bos.legFromTime; ev.legToTime=bos.legToTime;
            ev.entryPrice=EntryPrice(closeFill,nextOpenFill);
            ev.entryTime=(m_s.entryFillMode==EF_NEXT_OPEN)?(bos.barTime+PeriodSeconds(m_s.tf)):bos.barTime;
            m_bosThisBar=ev;
            m_last=ev; m_hasLast=true; m_countSession++;
           }
        }
      else
         m_fr.CheckBOS(); // keep its per-swing memory advancing even when not consumed

      // ---- Entry Type B: Reversal+Momentum ----
      if(m_s.entryMode==EM_REVERSAL_ONLY || m_s.entryMode==EM_BOTH)
        {
         MqlRates r[]; ArraySetAsSeries(r,true);
         int n=CopyRates(m_sym,m_s.tf,0,MathMax(50,m_s.revCounterLookback+10),r);

         // LONG side
         double revLow,legHigh,entryClose,entryNextOpen;
         if(n>0 && ScanReversalLong(r,n,atr,revLow,legHigh,entryClose,entryNextOpen))
           {
            m_revLongPending.active=true; m_revLongPending.extreme=revLow;
            m_revLongPending.entryClose=entryClose; m_revLongPending.entryNextOpen=entryNextOpen;
            m_revLongPending.legHigh=legHigh; m_revLongPending.legLow=revLow;
            m_revLongPending.barTime=r[1].time; m_revLongPending.closesHeld=1;
           }
         else if(m_revLongPending.active)
           {
            if(r[1].close<m_revLongPending.extreme) m_revLongPending.active=false; // failed to hold
            else m_revLongPending.closesHeld++;
           }
         if(m_revLongPending.active && m_revLongPending.closesHeld>=MathMax(1,m_s.revConfirmCloses))
           {
            STriggerEvent ev;
            ev.valid=true; ev.type="REV"; ev.dir=DIR_LONG;
            ev.protectedExtreme=m_revLongPending.extreme;
            ev.legRange=m_revLongPending.legHigh-m_revLongPending.legLow;
            ev.barTime=m_revLongPending.barTime;
            ev.legFromTime=m_revLongPending.barTime-(datetime)(MathMax(1,m_s.revCounterLookback)*PeriodSeconds(m_s.tf));
            ev.legToTime=m_revLongPending.barTime;
            ev.entryPrice=EntryPrice(m_revLongPending.entryClose,m_revLongPending.entryNextOpen);
            ev.entryTime=(m_s.entryFillMode==EF_NEXT_OPEN)?(m_revLongPending.barTime+PeriodSeconds(m_s.tf)):m_revLongPending.barTime;
            m_revLongThisBar=ev;
            m_last=ev; m_hasLast=true; m_countSession++;
            m_revLongPending.active=false; // fire once
           }

         // SHORT side
         double revHigh,legLow,entryCloseS,entryNextOpenS;
         if(n>0 && ScanReversalShort(r,n,atr,revHigh,legLow,entryCloseS,entryNextOpenS))
           {
            m_revShortPending.active=true; m_revShortPending.extreme=revHigh;
            m_revShortPending.entryClose=entryCloseS; m_revShortPending.entryNextOpen=entryNextOpenS;
            m_revShortPending.legHigh=revHigh; m_revShortPending.legLow=legLow;
            m_revShortPending.barTime=r[1].time; m_revShortPending.closesHeld=1;
           }
         else if(m_revShortPending.active)
           {
            if(r[1].close>m_revShortPending.extreme) m_revShortPending.active=false;
            else m_revShortPending.closesHeld++;
           }
         if(m_revShortPending.active && m_revShortPending.closesHeld>=MathMax(1,m_s.revConfirmCloses))
           {
            STriggerEvent ev;
            ev.valid=true; ev.type="REV"; ev.dir=DIR_SHORT;
            ev.protectedExtreme=m_revShortPending.extreme;
            ev.legRange=m_revShortPending.legHigh-m_revShortPending.legLow;
            ev.barTime=m_revShortPending.barTime;
            ev.legFromTime=m_revShortPending.barTime-(datetime)(MathMax(1,m_s.revCounterLookback)*PeriodSeconds(m_s.tf));
            ev.legToTime=m_revShortPending.barTime;
            ev.entryPrice=EntryPrice(m_revShortPending.entryClose,m_revShortPending.entryNextOpen);
            ev.entryTime=(m_s.entryFillMode==EF_NEXT_OPEN)?(m_revShortPending.barTime+PeriodSeconds(m_s.tf)):m_revShortPending.barTime;
            m_revShortThisBar=ev;
            m_last=ev; m_hasLast=true; m_countSession++;
            m_revShortPending.active=false;
           }
        }
     }

   //--- "is there a trigger THIS bar in direction dir?" (BOS wins the
   //--- tie-break if both types fire the same direction the same bar)
   STriggerEvent Query(const ENUM_DIR_V2 dir) const
     {
      if(m_bosThisBar.valid && m_bosThisBar.dir==dir) return(m_bosThisBar);
      if(dir==DIR_LONG  && m_revLongThisBar.valid)  return(m_revLongThisBar);
      if(dir==DIR_SHORT && m_revShortThisBar.valid) return(m_revShortThisBar);
      STriggerEvent none; none.valid=false; none.type="-"; none.dir=DIR_NONE;
      none.entryPrice=0; none.entryTime=0; none.protectedExtreme=0; none.legRange=0;
      none.barTime=0; none.legFromTime=0; none.legToTime=0;
      return(none);
     }

   //--- any trigger at all this bar, either direction (for a simple "did anything fire" check)
   bool AnyThisBar() const { return(m_bosThisBar.valid || m_revLongThisBar.valid || m_revShortThisBar.valid); }

   //--- raw per-type accessors, for a test harness that wants to see EVERYTHING that fired
   //--- this bar (Query() collapses a same-bar/same-direction BOS+REV tie to BOS only, which
   //--- is correct for the real consumer but would hide the REV event from a visual check)
   STriggerEvent BosThisBar()      const { return(m_bosThisBar); }
   STriggerEvent RevLongThisBar()  const { return(m_revLongThisBar); }
   STriggerEvent RevShortThisBar() const { return(m_revShortThisBar); }

   SDiagTriggers Diag() const
     {
      SDiagTriggers d;
      d.hasLast=m_hasLast; d.last=m_last; d.countThisSession=m_countSession;
      d.atr=ATR();
      d.lastLegRangeAtr=(m_hasLast && d.atr>0.0)?m_last.legRange/d.atr:0.0;
      return(d);
     }
  };

#endif // V2_TRIGGERS_MQH
