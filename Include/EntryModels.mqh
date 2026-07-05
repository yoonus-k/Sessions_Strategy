//+------------------------------------------------------------------+
//|                                                  EntryModels.mqh  |
//|  Close-confirmed entry triggers (charter rule 6):                 |
//|   - CHoCH : structure break confirmed on candle CLOSE, but the    |
//|             ENTRY is a pending LIMIT at a retracement of the leg   |
//|             that broke structure (avoids chasing a long break bar).|
//|   - IFVG  : reclaim of an inverted fair-value gap -> MARKET entry. |
//|  All detection operates on CLOSED bars (index >= 1).              |
//|                                                                   |
//|  NOTE: v1 implementation intended for visual/backtest refinement. |
//+------------------------------------------------------------------+
#ifndef SESSIONS_STRATEGY_ENTRYMODELS_MQH
#define SESSIONS_STRATEGY_ENTRYMODELS_MQH

#include "Common.mqh"
#include "Liquidity.mqh"   // IsSwingHigh / IsSwingLow

//--- Result of an entry evaluation (also carries geometry for drawing)
struct SEntrySignal
  {
   bool     valid;
   string   model;        // "CHoCH" or "IFVG"
   bool     useLimit;     // true => place a pending LIMIT at 'price'
   double   price;        // limit price (CHoCH); 0 for market (IFVG)
   // CHoCH geometry
   double   legHi;        // breaking leg high
   double   legLo;        // breaking leg low
   datetime legHiTime;
   datetime legLoTime;
   double   structLevel;  // broken structure swing level
   datetime structTime;
   // IFVG geometry
   double   zoneLo;
   double   zoneHi;
   datetime zoneTime;
  };

//--- A fair-value gap (for live drawing)
struct SFvg
  {
   datetime t;       // left edge (older bar) time
   double   lo;
   double   hi;
   bool     bullish; // gap direction
   bool     inverted;// price closed through it -> IFVG
  };

class CEntryModels
  {
private:
   SSettings m_s;
   string    m_symbol;
   int       m_lookback;
   datetime  m_from;     // session-open bound; 0 = unbounded

   int Copy(MqlRates &r[]) const
     {
      ArraySetAsSeries(r,true);
      if(m_from>0) return(CopyRates(m_symbol,m_s.tf,m_from,TimeCurrent(),r));
      int need=m_lookback+2*m_s.swingStrength+6;
      return(CopyRates(m_symbol,m_s.tf,0,need,r));
     }

public:
   void Init(const SSettings &s,const string symbol,const int lookbackBars=150)
     {
      m_s=s; m_symbol=symbol; m_lookback=lookbackBars; m_from=0;
     }

   //--- Restrict all detection to bars from this server time onward
   void SetWindow(const datetime fromTime){ m_from=fromTime; }

   //+----------------------------------------------------------------+
   //| CHoCH: structure break (close-confirmed) -> LIMIT at retrace    |
   //|  of the leg that broke structure.                              |
   //|  BUY  leg = [break extreme high .. pullback low]; entry =       |
   //|        legHi - retrace*(legHi-legLo)                            |
   //|  SELL leg mirrored; entry = legLo + retrace*(legHi-legLo)       |
   //+----------------------------------------------------------------+
   bool CheckCHoCH(const ENUM_BIAS bias,SEntrySignal &sig)
     {
      MqlRates r[]; int n=Copy(r);
      int N=MathMax(1,m_s.chochSwing); // smaller N catches fast reaction-high breaks
      if(n<2*N+6) return(false);
      int lim=(int)MathMin(n-N-1,m_lookback);
      double ret=m_s.chochEntryRetrace;

      if(bias==BIAS_BUY)
        {
         // most recent confirmed swing high = the last lower-high to break
         int iStruct=-1;
         for(int i=1+N;i<lim;i++) if(IsSwingHigh(r,n,i,N)){ iStruct=i; break; }
         if(iStruct<0) return(false);
         double lvl=r[iStruct].high;
         // FRESH break: prior closed bar below, last closed bar above
         if(r[2].close<=lvl && r[1].close>lvl)
           {
            double legHi=-DBL_MAX, legLo=DBL_MAX; int hiIdx=1, loIdx=1;
            for(int j=1;j<=iStruct;j++)
              {
               if(r[j].high>legHi){ legHi=r[j].high; hiIdx=j; }
               if(r[j].low <legLo){ legLo=r[j].low;  loIdx=j; }
              }
            sig.valid=true; sig.model="CHoCH"; sig.useLimit=true;
            sig.legHi=legHi; sig.legLo=legLo;
            sig.legHiTime=r[hiIdx].time; sig.legLoTime=r[loIdx].time;
            sig.structLevel=lvl; sig.structTime=r[iStruct].time;
            sig.price=legHi-ret*(legHi-legLo);
            return(true);
           }
        }
      else if(bias==BIAS_SELL)
        {
         int iStruct=-1;
         for(int i=1+N;i<lim;i++) if(IsSwingLow(r,n,i,N)){ iStruct=i; break; }
         if(iStruct<0) return(false);
         double lvl=r[iStruct].low;
         if(r[2].close>=lvl && r[1].close<lvl)
           {
            double legHi=-DBL_MAX, legLo=DBL_MAX; int hiIdx=1, loIdx=1;
            for(int j=1;j<=iStruct;j++)
              {
               if(r[j].high>legHi){ legHi=r[j].high; hiIdx=j; }
               if(r[j].low <legLo){ legLo=r[j].low;  loIdx=j; }
              }
            sig.valid=true; sig.model="CHoCH"; sig.useLimit=true;
            sig.legHi=legHi; sig.legLo=legLo;
            sig.legHiTime=r[hiIdx].time; sig.legLoTime=r[loIdx].time;
            sig.structLevel=lvl; sig.structTime=r[iStruct].time;
            sig.price=legLo+ret*(legHi-legLo);
            return(true);
           }
        }
      return(false);
     }

   //+----------------------------------------------------------------+
   //| IFVG: reclaim of an inverted fair-value gap -> MARKET entry     |
   //+----------------------------------------------------------------+
   bool CheckIFVG(const ENUM_BIAS bias,SEntrySignal &sig)
     {
      MqlRates r[]; int n=Copy(r);
      if(n<6) return(false);
      int lim=(int)MathMin(n-3,m_lookback);

      if(bias==BIAS_BUY)
        {
         for(int i=2;i<lim;i++)
           {
            double zoneLow =r[i].high;
            double zoneHigh=r[i+2].low;
            if(zoneHigh<=zoneLow) continue;
            if(r[1].low<=zoneHigh && r[1].close>zoneHigh)
              {
               sig.valid=true; sig.model="IFVG"; sig.useLimit=false; sig.price=0;
               sig.zoneLo=zoneLow; sig.zoneHi=zoneHigh; sig.zoneTime=r[i+2].time;
               return(true);
              }
            return(false);
           }
        }
      else if(bias==BIAS_SELL)
        {
         for(int i=2;i<lim;i++)
           {
            double zoneHigh=r[i].low;
            double zoneLow =r[i+2].high;
            if(zoneHigh<=zoneLow) continue;
            if(r[1].high>=zoneLow && r[1].close<zoneLow)
              {
               sig.valid=true; sig.model="IFVG"; sig.useLimit=false; sig.price=0;
               sig.zoneLo=zoneLow; sig.zoneHi=zoneHigh; sig.zoneTime=r[i+2].time;
               return(true);
              }
            return(false);
           }
        }
      return(false);
     }

   //+----------------------------------------------------------------+
   //| Most recent swing level that a CHoCH would break (for display) |
   //+----------------------------------------------------------------+
   bool WatchLevel(const ENUM_BIAS bias,double &level,datetime &t)
     {
      MqlRates r[]; int n=Copy(r);
      int N=MathMax(1,m_s.chochSwing);
      if(n<2*N+4) return(false);
      int lim=(int)MathMin(n-N-1,m_lookback);
      for(int i=1+N;i<lim;i++)
        {
         if(bias==BIAS_BUY && IsSwingHigh(r,n,i,N)){ level=r[i].high; t=r[i].time; return(true); }
         if(bias==BIAS_SELL&& IsSwingLow (r,n,i,N)){ level=r[i].low;  t=r[i].time; return(true); }
        }
      return(false);
     }

   //+----------------------------------------------------------------+
   //| Collect recent fair-value gaps (with inversion flag)           |
   //+----------------------------------------------------------------+
   int CollectFVGs(SFvg &out[],const int maxOut,const int scan=120)
     {
      MqlRates r[]; int n=Copy(r);
      if(n<5) return(0);
      int lim=(int)MathMin(n-2,scan);
      int cnt=0;
      for(int i=2;i<lim && cnt<maxOut;i++)
        {
         // 3-candle window: A=i+1 (older), B=i, C=i-1 (newer)
         double bullLo=r[i+1].high, bullHi=r[i-1].low;   // bullish gap zone
         double bearHi=r[i+1].low,  bearLo=r[i-1].high;  // bearish gap zone
         bool bull=(bullHi>bullLo);
         bool bear=(bearHi<bearLo); // i.e. r[i-1].high < r[i+1].low
         if(!bull && !bear) continue;

         SFvg f; f.t=r[i+1].time; f.bullish=bull; f.inverted=false;
         if(bull){ f.lo=bullLo; f.hi=bullHi; }
         else    { f.lo=bearHi; f.hi=bearLo; } // bear: lo=r[i+1].low, hi=r[i-1].high

         // inversion: a newer bar closed through the gap (opposite side)
         for(int k=1;k<i-1;k++)
           {
            if(bull && r[k].close<f.lo){ f.inverted=true; break; }
            if(bear && r[k].close>f.hi){ f.inverted=true; break; }
           }
         out[cnt++]=f;
        }
      return(cnt);
     }

   //+----------------------------------------------------------------+
   //| Combined check honoring the configured entry-model preference  |
   //+----------------------------------------------------------------+
   bool CheckEntry(const ENUM_BIAS bias,SEntrySignal &sig)
     {
      sig.valid=false; sig.useLimit=false; sig.price=0; sig.model="";
      sig.legHi=0; sig.legLo=0; sig.legHiTime=0; sig.legLoTime=0;
      sig.structLevel=0; sig.structTime=0; sig.zoneLo=0; sig.zoneHi=0; sig.zoneTime=0;
      SEntrySignal a,b; bool ca=false,cb=false;
      if(m_s.entryModel!=ENTRY_IFVG_ONLY)  ca=CheckCHoCH(bias,a);
      if(m_s.entryModel!=ENTRY_CHOCH_ONLY) cb=CheckIFVG (bias,b);

      switch(m_s.entryModel)
        {
         case ENTRY_CHOCH_ONLY: if(ca){ sig=a; return(true);} break;
         case ENTRY_IFVG_ONLY:  if(cb){ sig=b; return(true);} break;
         case ENTRY_CHOCH_FIRST:
         case ENTRY_EITHER:
            if(ca){ sig=a; return(true);}
            if(cb){ sig=b; return(true);}
            break;
        }
      return(false);
     }
  };

#endif // SESSIONS_STRATEGY_ENTRYMODELS_MQH
