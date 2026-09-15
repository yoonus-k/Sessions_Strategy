//+------------------------------------------------------------------+
//|                                                       ZigZag.mqh  |
//|  P2 - anchor-pivot detector.                                      |
//|                                                                   |
//|  Thin wrapper over the stock MT5 indicator  Examples\ZigZag       |
//|  (Depth / Deviation / Backstep). Reading its buffers guarantees   |
//|  the pivots match the indicator the user overlays for the T2a     |
//|  visual check, with almost no code to get wrong.                  |
//|                                                                   |
//|  Buffer 0 = ZigZag section, 1 = high pivots, 2 = low pivots.      |
//|  The NEWEST non-zero pivot is treated as tentative (ZigZag can    |
//|  still move it); everything older is confirmed.                   |
//|                                                                   |
//|  Pure detection - never places orders.                           |
//+------------------------------------------------------------------+
#ifndef V2_ZIGZAG_MQH
#define V2_ZIGZAG_MQH

#include "V2Common.mqh"

#define ZZ_SCAN_BARS 2000   // history depth pulled from the indicator

struct SZZPivot
  {
   datetime time;
   double   price;
   bool     isHigh;
  };

struct SDiagZigZag
  {
   bool     handleOk;
   int      confirmedCount;
   bool     tailPending;       // a developing (tentative) newest pivot exists
   SZZPivot tentative;         // the developing pivot (valid when tailPending)
   SZZPivot last[6];           // newest-first CONFIRMED pivots
   int      lastN;
   double   lastLegSize;       // |newest confirmed - previous confirmed|
   double   lastLegAtr;        // lastLegSize / ATR  (0 if ATR unavailable)
   double   atr;
  };

class CZigZag
  {
private:
   SSettingsV2 m_s;
   string      m_sym;
   int         m_zzHandle;
   int         m_atrHandle;

   // rebuilt each Refresh(), oldest-first
   SZZPivot    m_piv[];
   int         m_count;
   bool        m_tail;         // last entry in m_piv is tentative

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
      m_zzHandle=iCustom(sym,s.tf,"Examples\\ZigZag",
                         s.zzDepth,s.zzDeviation,s.zzBackstep);
      m_atrHandle=(s.atrPeriod>0)?iATR(sym,s.tf,s.atrPeriod):INVALID_HANDLE;
      ArrayResize(m_piv,0); m_count=0; m_tail=false;
     }
   void Deinit()
     {
      if(m_zzHandle!=INVALID_HANDLE)  IndicatorRelease(m_zzHandle);
      if(m_atrHandle!=INVALID_HANDLE) IndicatorRelease(m_atrHandle);
     }

   bool HandleOk() const { return(m_zzHandle!=INVALID_HANDLE); }

   //+--------------------------------------------------------------+
   //| Rebuild the pivot list from the indicator buffers. Call once  |
   //| per new bar.                                                  |
   //+--------------------------------------------------------------+
   bool Refresh()
     {
      ArrayResize(m_piv,0); m_count=0; m_tail=false;
      if(m_zzHandle==INVALID_HANDLE) return(false);

      int bars=Bars(m_sym,m_s.tf);
      int n=MathMin(ZZ_SCAN_BARS,bars-1);
      if(n<10) return(false);

      double hi[],lo[]; datetime tm[];
      ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true); ArraySetAsSeries(tm,true);
      if(CopyBuffer(m_zzHandle,1,0,n,hi)<=0) return(false);
      if(CopyBuffer(m_zzHandle,2,0,n,lo)<=0) return(false);
      if(CopyTime(m_sym,m_s.tf,0,n,tm)<=0)   return(false);

      // walk oldest -> newest so m_piv is chronological
      for(int i=n-1;i>=1;i--)  // skip index 0 (forming bar)
        {
         bool isHi=(hi[i]!=0.0 && hi[i]!=EMPTY_VALUE);
         bool isLo=(lo[i]!=0.0 && lo[i]!=EMPTY_VALUE);
         if(!isHi && !isLo) continue;
         SZZPivot p;
         p.time  =tm[i];
         p.isHigh=isHi;
         p.price =isHi?hi[i]:lo[i];
         // if two consecutive same-type entries appear, keep the more extreme
         if(m_count>0 && m_piv[m_count-1].isHigh==p.isHigh)
           {
            bool better=p.isHigh?(p.price>m_piv[m_count-1].price)
                                :(p.price<m_piv[m_count-1].price);
            if(better) m_piv[m_count-1]=p;
            continue;
           }
         ArrayResize(m_piv,m_count+1);
         m_piv[m_count++]=p;
        }
      m_tail=(m_count>0); // newest pivot is always the developing one
      return(true);
     }

   //--- total pivots held (including the tentative tail)
   int  Total()          const { return(m_count); }
   //--- confirmed = all but the developing tail
   int  ConfirmedCount() const { return(m_tail?MathMax(0,m_count-1):m_count); }
   bool TailPending()    const { return(m_tail); }

   //--- pivot by age. from=0 -> newest CONFIRMED. includeTentative=true
   //--- makes from=0 the developing pivot instead.
   bool Get(const int from,SZZPivot &out,const bool includeTentative=false) const
     {
      int top=includeTentative?m_count-1:ConfirmedCount()-1;
      int idx=top-from;
      if(idx<0 || idx>=m_count) return(false);
      out=m_piv[idx];
      return(true);
     }

   //--- newest CONFIRMED pivot whose time is within [t0, t1]
   bool LastSignificantIn(const datetime t0,const datetime t1,SZZPivot &out) const
     {
      int top=ConfirmedCount()-1;
      for(int i=top;i>=0;i--)
         if(m_piv[i].time>=t0 && m_piv[i].time<=t1){ out=m_piv[i]; return(true); }
      return(false);
     }

   //--- OLDEST CONFIRMED pivot whose time is within [t0, t1] - i.e. the one
   //--- CLOSEST to t0. Mirrors LastSignificantIn (closest to t1); used by
   //--- AnchorSelect to find the nearest pivot AFTER a session's close,
   //--- where "nearest" means earliest, not newest.
   bool FirstSignificantIn(const datetime t0,const datetime t1,SZZPivot &out) const
     {
      int top=ConfirmedCount()-1;
      for(int i=0;i<=top;i++)
         if(m_piv[i].time>=t0 && m_piv[i].time<=t1){ out=m_piv[i]; return(true); }
      return(false);
     }

   //--- largest leg (|price diff| between consecutive pivots) whose BOTH
   //--- endpoints lie within [t0, t1]. Confirmed pivots only.
   double LargestLegIn(const datetime t0,const datetime t1) const
     {
      double best=0.0;
      int top=ConfirmedCount()-1;
      for(int i=1;i<=top;i++)
        {
         if(m_piv[i-1].time<t0 || m_piv[i].time>t1) continue;
         double leg=MathAbs(m_piv[i].price-m_piv[i-1].price);
         if(leg>best) best=leg;
        }
      return(best);
     }

   double CurrentATR() const { return(ATR()); }

   //+--------------------------------------------------------------+
   SDiagZigZag Diag() const
     {
      SDiagZigZag d;
      d.handleOk       =(m_zzHandle!=INVALID_HANDLE);
      d.confirmedCount =ConfirmedCount();
      d.tailPending    =m_tail;
      d.atr            =ATR();
      if(m_tail && m_count>0) d.tentative=m_piv[m_count-1];

      d.lastN=0;
      int top=ConfirmedCount()-1;
      for(int i=top;i>=0 && d.lastN<6;i--) d.last[d.lastN++]=m_piv[i];

      d.lastLegSize=0.0; d.lastLegAtr=0.0;
      if(ConfirmedCount()>=2)
        {
         d.lastLegSize=MathAbs(m_piv[top].price-m_piv[top-1].price);
         if(d.atr>0) d.lastLegAtr=d.lastLegSize/d.atr;
        }
      return(d);
     }
  };

#endif // V2_ZIGZAG_MQH
