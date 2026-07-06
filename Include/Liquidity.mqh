//+------------------------------------------------------------------+
//|                                                    Liquidity.mqh  |
//|  Swing detection + liquidity sweep (charter rules 4 & 5).         |
//|  A sweep here just means price TOOK the level (traded beyond the   |
//|  nearest prior swing high/low). The entry model confirms reversal. |
//+------------------------------------------------------------------+
#ifndef SESSIONS_STRATEGY_LIQUIDITY_MQH
#define SESSIONS_STRATEGY_LIQUIDITY_MQH

#include "Common.mqh"

//--- Shared swing helpers (also used by EntryModels) ---------------
bool IsSwingHigh(const MqlRates &r[],const int n,const int i,const int N)
  {
   if(i-N<0 || i+N>=n) return(false);
   double v=r[i].high;
   for(int k=1;k<=N;k++)
      if(r[i-k].high>v || r[i+k].high>v) return(false);
   return(true);
  }

bool IsSwingLow(const MqlRates &r[],const int n,const int i,const int N)
  {
   if(i-N<0 || i+N>=n) return(false);
   double v=r[i].low;
   for(int k=1;k<=N;k++)
      if(r[i-k].low<v || r[i+k].low<v) return(false);
   return(true);
  }

class CLiquidity
  {
private:
   SSettings m_s;
   string    m_symbol;
   int       m_lookback;
   // state (reset each session)
   bool      m_swept;
   double    m_sweptLevel;     // the level that was actually taken
   double    m_sweepExtreme;   // session extreme = SL anchor (the wick)
   datetime  m_sweepTime;
   double    m_targetLevel;    // the low/high currently marked to be swept
   datetime  m_targetTime;

public:
   void Init(const SSettings &s,const string symbol,const int lookbackBars=300)
     {
      m_s=s; m_symbol=symbol; m_lookback=lookbackBars;
      Reset();
     }

   void Reset()
     {
      m_swept=false; m_sweptLevel=0; m_sweepExtreme=0; m_sweepTime=0;
      m_targetLevel=0; m_targetTime=0;
     }

   //--- Sweep model (robust, trailing):
   //    BUY  : the marked LOW trails to the most recent confirmed swing low
   //           (it starts as the nearest pre-session low and follows new lows
   //           down). It is "swept" the moment a more-recent IN-SESSION bar
   //           trades below the marked low (WICK is enough, no close needed);
   //           the marker then freezes there.
   //    SELL : mirror with swing highs.
   //    SL anchor = the session extreme (lowest low / highest high).
   //
   //    IMPORTANT: the break-check against the CURRENTLY marked level always
   //    runs first, using raw wicks, before any retargeting. IsSwingLow/High
   //    requires N bars on BOTH sides to not have a lower/higher extreme, so
   //    the very wick that sweeps the marked level also disqualifies that
   //    level from being re-found as "a swing" on this same bar. If we let
   //    the swing search run first, it can silently skip past the level that
   //    just got swept (falling back to an older, deeper, unrelated swing)
   //    and the sweep would never be detected. Checking the stored target
   //    first avoids that: a wick always counts, and the target can only
   //    move forward in time (never back to a stale/older level).
   void Update(const ENUM_BIAS bias,const datetime sessionStart)
     {
      if(bias==BIAS_NONE || sessionStart<=0) return;
      int N=m_s.swingStrength;
      datetime scanFrom=sessionStart-(datetime)(m_s.preSweepHours*3600.0);
      MqlRates r[]; ArraySetAsSeries(r,true);
      int n=CopyRates(m_symbol,m_s.tf,scanFrom,TimeCurrent(),r);
      if(n<2*N+1) return;

      if(bias==BIAS_BUY)
        {
         // 1) break-check the level we are CURRENTLY watching, wick is enough
         if(!m_swept && m_targetLevel>0)
            for(int k=0;k<n;k++)
               if(r[k].time>=sessionStart && r[k].time>m_targetTime && r[k].low<m_targetLevel)
                 { m_swept=true; m_sweptLevel=m_targetLevel; break; }

         // 2) not yet swept -> may trail forward to a newer confirmed swing low
         if(!m_swept)
           {
            int iL=-1;
            for(int i=N;i<n-N;i++) if(IsSwingLow(r,n,i,N)){ iL=i; break; }
            if(iL>=0 && (m_targetLevel<=0 || r[iL].time>m_targetTime))
              { m_targetLevel=r[iL].low; m_targetTime=r[iL].time; }
           }

         // SL anchor = the extreme of the SWEEPING leg only (from the
         // currently marked target's own bar onward), never a stale/deeper
         // low from earlier in the session that is unrelated to this sweep.
         datetime extFrom=(m_targetTime>0)?m_targetTime:sessionStart;
         double lo=DBL_MAX; datetime lt=sessionStart;
         for(int i=0;i<n;i++) if(r[i].time>=extFrom && r[i].low<lo){ lo=r[i].low; lt=r[i].time; }
         if(lo<DBL_MAX){ m_sweepExtreme=lo; m_sweepTime=lt; }
        }
      else // BIAS_SELL
        {
         if(!m_swept && m_targetLevel>0)
            for(int k=0;k<n;k++)
               if(r[k].time>=sessionStart && r[k].time>m_targetTime && r[k].high>m_targetLevel)
                 { m_swept=true; m_sweptLevel=m_targetLevel; break; }

         if(!m_swept)
           {
            int iH=-1;
            for(int i=N;i<n-N;i++) if(IsSwingHigh(r,n,i,N)){ iH=i; break; }
            if(iH>=0 && (m_targetLevel<=0 || r[iH].time>m_targetTime))
              { m_targetLevel=r[iH].high; m_targetTime=r[iH].time; }
           }

         datetime extFrom=(m_targetTime>0)?m_targetTime:sessionStart;
         double hi=-DBL_MAX; datetime ht=sessionStart;
         for(int i=0;i<n;i++) if(r[i].time>=extFrom && r[i].high>hi){ hi=r[i].high; ht=r[i].time; }
         if(hi>-DBL_MAX){ m_sweepExtreme=hi; m_sweepTime=ht; }
        }
     }

   bool     Swept()        const { return(m_swept); }
   double   SweptLevel()   const { return(m_sweptLevel); }
   double   SweepExtreme() const { return(m_sweepExtreme); } // SL anchor (wick)
   datetime SweepTime()    const { return(m_sweepTime); }
   double   TargetLevel()  const { return(m_targetLevel); }  // marked low/high to sweep
   datetime TargetTime()   const { return(m_targetTime); }
  };

#endif // SESSIONS_STRATEGY_LIQUIDITY_MQH
