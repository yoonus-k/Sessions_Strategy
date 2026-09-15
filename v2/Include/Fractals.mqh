//+------------------------------------------------------------------+
//|                                                     Fractals.mqh  |
//|  P2 - structure / BOS detector (independent of ZigZag).           |
//|                                                                   |
//|  Fractal pivot: bar i is a fractal high if high[i] is strictly    |
//|  greater than the highs of the N bars on EACH side; confirmed     |
//|  only once those N right-side bars have closed. Mirror for lows.  |
//|                                                                   |
//|  BOS = a closed bar that breaks the most recent confirmed swing   |
//|  in either direction (CLOSE or WICK), reported once per swing.    |
//|  The BOS "leg" spans from the broken swing's bar to the breaking  |
//|  bar; downstream Triggers use legLow (bull) / legHigh (bear) as   |
//|  the protected extreme.                                           |
//|                                                                   |
//|  Pure detection - never places orders.                           |
//+------------------------------------------------------------------+
#ifndef V2_FRACTALS_MQH
#define V2_FRACTALS_MQH

#include "V2Common.mqh"

#define FR_SCAN_BARS 700

struct SFractal
  {
   datetime time;
   double   price;
   bool     isHigh;
  };

struct SBosEvent
  {
   bool        valid;
   ENUM_DIR_V2 dir;          // DIR_LONG = broke a swing HIGH, DIR_SHORT = broke a swing LOW
   double      brokenLevel;
   datetime    brokenTime;   // bar time of the swing that was broken
   datetime    barTime;      // bar time of the break
   double      legHigh;
   double      legLow;
   double      legRange;
   datetime    legFromTime;
   datetime    legToTime;
  };

struct SDiagFractals
  {
   int      swingHighCount;
   int      swingLowCount;
   double   lastSwingHigh;
   double   lastSwingLow;
   datetime lastSwingHighTime;
   datetime lastSwingLowTime;
   bool     swingHighBroken;   // last swing high already produced a BOS
   bool     swingLowBroken;
   int      bosCount;          // since the last ResetSession()
   SBosEvent lastBos;
   double   atr;
   SFractal lastHi[5]; int lastHiN;
   SFractal lastLo[5]; int lastLoN;
  };

class CFractals
  {
private:
   SSettingsV2 m_s;
   string      m_sym;
   int         m_atrHandle;

   SFractal    m_hi[]; int m_hiN;
   SFractal    m_lo[]; int m_loN;

   datetime    m_brokenHiTime;   // swing-high time that last produced a bull BOS
   datetime    m_brokenLoTime;
   int         m_bosCount;
   SBosEvent   m_lastBos;

   double Point_() const { return(SymbolInfoDouble(m_sym,SYMBOL_POINT)); }

   double ATR() const
     {
      if(m_atrHandle==INVALID_HANDLE) return(0);
      double a[]; ArraySetAsSeries(a,true);
      if(CopyBuffer(m_atrHandle,0,0,2,a)<1) return(0);
      return(a[0]);
     }

public:
   void Init(const SSettingsV2 &s,const string sym)
     {
      m_s=s; m_sym=sym;
      m_atrHandle=(s.atrPeriod>0)?iATR(sym,s.tf,s.atrPeriod):INVALID_HANDLE;
      ArrayResize(m_hi,0); ArrayResize(m_lo,0); m_hiN=0; m_loN=0;
      m_brokenHiTime=0; m_brokenLoTime=0; m_bosCount=0;
      m_lastBos.valid=false;
     }
   void Deinit(){ if(m_atrHandle!=INVALID_HANDLE) IndicatorRelease(m_atrHandle); }

   //--- zero the per-session BOS memory (call on a session key change)
   void ResetSession()
     {
      m_brokenHiTime=0; m_brokenLoTime=0; m_bosCount=0;
      m_lastBos.valid=false;
     }

   //+--------------------------------------------------------------+
   //| Rebuild the confirmed-fractal lists from closed bars.         |
   //+--------------------------------------------------------------+
   void Refresh()
     {
      ArrayResize(m_hi,0); ArrayResize(m_lo,0); m_hiN=0; m_loN=0;
      int N=MathMax(1,m_s.bosSwingDepth);

      MqlRates r[]; ArraySetAsSeries(r,true);
      int n=CopyRates(m_sym,m_s.tf,0,FR_SCAN_BARS,r);
      if(n<2*N+3) return;

      // i is a candidate pivot; need N closed bars on its right => i>=1+N,
      // and index 0 is the forming bar so never touch it.
      for(int i=n-1-N;i>=1+N;i--)
        {
         bool isHi=true, isLo=true;
         for(int k=1;k<=N;k++)
           {
            if(r[i].high<=r[i-k].high || r[i].high<=r[i+k].high) isHi=false;
            if(r[i].low >=r[i-k].low  || r[i].low >=r[i+k].low ) isLo=false;
            if(!isHi && !isLo) break;
           }
         if(isHi){ ArrayResize(m_hi,m_hiN+1); m_hi[m_hiN].time=r[i].time; m_hi[m_hiN].price=r[i].high; m_hi[m_hiN].isHigh=true;  m_hiN++; }
         if(isLo){ ArrayResize(m_lo,m_loN+1); m_lo[m_loN].time=r[i].time; m_lo[m_loN].price=r[i].low;  m_lo[m_loN].isHigh=false; m_loN++; }
        }
      // m_hi / m_lo are oldest-first (loop walked oldest -> newest)
     }

   int  SwingHighCount() const { return(m_hiN); }
   int  SwingLowCount()  const { return(m_loN); }
   bool LastSwingHigh(double &price,datetime &t) const
     { if(m_hiN<=0) return(false); price=m_hi[m_hiN-1].price; t=m_hi[m_hiN-1].time; return(true); }
   bool LastSwingLow(double &price,datetime &t) const
     { if(m_loN<=0) return(false); price=m_lo[m_loN-1].price; t=m_lo[m_loN-1].time; return(true); }

   //--- fractal by age within a list: from=0 -> newest
   bool GetHigh(const int from,SFractal &out) const
     { int idx=m_hiN-1-from; if(idx<0||idx>=m_hiN) return(false); out=m_hi[idx]; return(true); }
   bool GetLow(const int from,SFractal &out) const
     { int idx=m_loN-1-from; if(idx<0||idx>=m_loN) return(false); out=m_lo[idx]; return(true); }

   //+--------------------------------------------------------------+
   //| Fresh BOS on the last closed bar, or {valid=false}.           |
   //| Reported once per swing (memory cleared by ResetSession).     |
   //+--------------------------------------------------------------+
   SBosEvent CheckBOS()
     {
      SBosEvent ev; ev.valid=false;

      MqlRates r[]; ArraySetAsSeries(r,true);
      int n=CopyRates(m_sym,m_s.tf,0,FR_SCAN_BARS,r);
      if(n<4) return(ev);
      double buf=m_s.bosBufferPoints*Point_();
      bool wick=(m_s.bosConfirmMode==BC_WICK);

      // ---- bull BOS: break the most recent confirmed swing high ----
      if(m_hiN>0)
        {
         SFractal sw=m_hi[m_hiN-1];
         double lvl=sw.price+buf;
         double probeNow =wick?r[1].high:r[1].close;
         double probePrev=wick?r[2].high:r[2].close;
         if(sw.time!=m_brokenHiTime && probePrev<=lvl && probeNow>lvl)
           {
            ev=BuildLeg(r,n,DIR_LONG,sw.price,sw.time);
            m_brokenHiTime=sw.time; m_bosCount++; m_lastBos=ev;
            return(ev);
           }
        }
      // ---- bear BOS: break the most recent confirmed swing low ----
      if(m_loN>0)
        {
         SFractal sw=m_lo[m_loN-1];
         double lvl=sw.price-buf;
         double probeNow =wick?r[1].low:r[1].close;
         double probePrev=wick?r[2].low:r[2].close;
         if(sw.time!=m_brokenLoTime && probePrev>=lvl && probeNow<lvl)
           {
            ev=BuildLeg(r,n,DIR_SHORT,sw.price,sw.time);
            m_brokenLoTime=sw.time; m_bosCount++; m_lastBos=ev;
            return(ev);
           }
        }
      return(ev);
     }

private:
   //--- assemble the leg from the broken swing's bar to bar[1]
   SBosEvent BuildLeg(const MqlRates &r[],const int n,const ENUM_DIR_V2 dir,
                      const double lvl,const datetime swTime) const
     {
      SBosEvent ev; ev.valid=true; ev.dir=dir;
      ev.brokenLevel=lvl; ev.brokenTime=swTime; ev.barTime=r[1].time;
      double hi=-DBL_MAX, lo=DBL_MAX;
      datetime from=swTime, to=r[1].time;
      for(int i=1;i<n;i++)
        {
         if(r[i].time<from || r[i].time>to) continue;
         if(r[i].high>hi) hi=r[i].high;
         if(r[i].low <lo) lo=r[i].low;
        }
      if(hi==-DBL_MAX){ hi=r[1].high; lo=r[1].low; }
      ev.legHigh=hi; ev.legLow=lo; ev.legRange=hi-lo;
      ev.legFromTime=from; ev.legToTime=to;
      return(ev);
     }

public:
   double    CurrentATR() const { return(ATR()); }
   int       BosCount()   const { return(m_bosCount); }
   SBosEvent LastBos()    const { return(m_lastBos); }

   SDiagFractals Diag() const
     {
      SDiagFractals d;
      d.swingHighCount=m_hiN; d.swingLowCount=m_loN;
      d.lastSwingHigh=0; d.lastSwingLow=0; d.lastSwingHighTime=0; d.lastSwingLowTime=0;
      if(m_hiN>0){ d.lastSwingHigh=m_hi[m_hiN-1].price; d.lastSwingHighTime=m_hi[m_hiN-1].time; }
      if(m_loN>0){ d.lastSwingLow =m_lo[m_loN-1].price; d.lastSwingLowTime =m_lo[m_loN-1].time; }
      d.swingHighBroken=(m_hiN>0 && m_hi[m_hiN-1].time==m_brokenHiTime);
      d.swingLowBroken =(m_loN>0 && m_lo[m_loN-1].time==m_brokenLoTime);
      d.bosCount=m_bosCount;
      d.lastBos=m_lastBos;
      d.atr=ATR();
      d.lastHiN=0;
      for(int i=m_hiN-1;i>=0 && d.lastHiN<5;i--) d.lastHi[d.lastHiN++]=m_hi[i];
      d.lastLoN=0;
      for(int i=m_loN-1;i>=0 && d.lastLoN<5;i--) d.lastLo[d.lastLoN++]=m_lo[i];
      return(d);
     }
  };

#endif // V2_FRACTALS_MQH
