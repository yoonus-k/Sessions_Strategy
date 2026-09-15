//+------------------------------------------------------------------+
//|                                                        AVWAP.mqh  |
//|  P1 - Anchored VWAP + +/-1s and +/-2s bands.                      |
//|                                                                   |
//|      VWAP = S(v*p) / S(v)                       (since the anchor) |
//|      var  = S(v*p*p) / S(v) - VWAP*VWAP                            |
//|      sigma= sqrt(max(0,var))                                      |
//|      U1=VWAP+m1*s  U2=VWAP+m2*s   L1,L2 mirror                     |
//|                                                                   |
//|  - Anchor bar is set once (SetAnchor) and LOCKED - no repaint.    |
//|  - Closed bars only: folds bars with time < nowBar.               |
//|  - Volume = tick_volume on gold; real_volume used only when the   |
//|    feed actually provides it. A zero-volume bar still contributes |
//|    its price (weight forced to 1), matching v1.                   |
//|  - Band output is 'not ready' until MinBarsSinceAnchor bars and   |
//|    while sigma ~ 0 (warm-up).                                     |
//|                                                                   |
//|  Pure calculation - never places orders.                         |
//+------------------------------------------------------------------+
#ifndef V2_AVWAP_MQH
#define V2_AVWAP_MQH

#include "V2Common.mqh"

struct SDiagAVWAP
  {
   bool     hasAnchor;
   bool     ready;            // hasAnchor && bars>=min && sigma>0
   bool     suppressed;       // !ready while an anchor exists (warm-up)
   datetime anchorTime;
   int      barsSinceAnchor;
   double   vwap;
   double   sigma;
   double   u1,u2,l1,l2;
   double   refPrice;         // price fed in for the d calc
   double   dPrice;           // refPrice - vwap
   double   dSigma;           // dPrice / sigma  (0 when sigma<=0)
  };

class CAVWAP
  {
private:
   SSettingsV2 m_s;
   string      m_sym;
   datetime    m_anchor;      // 0 = unset

   // cache of the last Compute()
   int         m_count;
   double      m_vwap, m_sigma;

   double Src(const MqlRates &r) const
     {
      switch(m_s.priceInput)
        {
         case PI_CLOSE: return(r.close);
         case PI_HL2:   return((r.high+r.low)/2.0);
         case PI_OHLC4: return((r.open+r.high+r.low+r.close)/4.0);
         default:       return((r.high+r.low+r.close)/3.0); // HLC3
        }
     }

public:
   void Init(const SSettingsV2 &s,const string sym)
     {
      m_s=s; m_sym=sym; m_anchor=0;
      m_count=0; m_vwap=0; m_sigma=0;
     }

   //--- set / lock the anchor. A repeated identical time is a no-op so
   //--- the caller can call it unconditionally at each session open.
   void SetAnchor(const datetime t)
     {
      if(t>0 && t!=m_anchor){ m_anchor=t; m_count=0; m_vwap=0; m_sigma=0; }
     }
   void ClearAnchor(){ m_anchor=0; m_count=0; m_vwap=0; m_sigma=0; }
   datetime Anchor() const { return(m_anchor); }
   bool     HasAnchor() const { return(m_anchor>0); }

   //+--------------------------------------------------------------+
   //| Running series over [anchor .. last closed bar before nowBar].|
   //| Fills 'times/vwap/sig' oldest-first; returns the point count. |
   //| bands are vwap +/- m1/m2 * sig at the same indices.          |
   //+--------------------------------------------------------------+
   int Compute(const datetime nowBar,datetime &times[],double &vwap[],double &sig[])
     {
      ArrayFree(times); ArrayFree(vwap); ArrayFree(sig);
      m_count=0; m_vwap=0; m_sigma=0;
      if(m_anchor<=0 || nowBar<=m_anchor) return(0);

      MqlRates r[]; ArraySetAsSeries(r,false); // oldest first
      int n=CopyRates(m_sym,m_s.tf,m_anchor,nowBar,r);
      if(n<=0) return(0);

      // decide volume source once
      long realSum=0;
      for(int i=0;i<n;i++) realSum+=r[i].real_volume;
      bool useReal=(m_s.volumeSrc==VS_REAL && realSum>0);

      ArrayResize(times,n); ArrayResize(vwap,n); ArrayResize(sig,n);
      double sv=0, svp=0, svp2=0; int c=0;
      for(int i=0;i<n;i++)
        {
         if(r[i].time>=nowBar) break;             // closed bars only
         double p=Src(r[i]);
         double v=useReal?(double)r[i].real_volume:(double)r[i].tick_volume;
         if(v<=0) v=1.0;
         sv+=v; svp+=v*p; svp2+=v*p*p;
         double vw=(sv>0)?svp/sv:p;
         double var=(sv>0)?(svp2/sv-vw*vw):0.0;
         if(var<0) var=0.0;
         times[c]=r[i].time; vwap[c]=vw; sig[c]=MathSqrt(var);
         c++;
        }
      ArrayResize(times,c); ArrayResize(vwap,c); ArrayResize(sig,c);
      m_count=c;
      if(c>0){ m_vwap=vwap[c-1]; m_sigma=sig[c-1]; }
      return(c);
     }

   //--- last computed values (call Compute first on this bar)
   bool Latest(double &vwapOut,double &sigmaOut,int &bars) const
     {
      vwapOut=m_vwap; sigmaOut=m_sigma; bars=m_count;
      return(m_count>0);
     }

   double U1() const { return(m_vwap+m_s.band1Mult*m_sigma); }
   double U2() const { return(m_vwap+m_s.band2Mult*m_sigma); }
   double L1() const { return(m_vwap-m_s.band1Mult*m_sigma); }
   double L2() const { return(m_vwap-m_s.band2Mult*m_sigma); }

   //--- ready = anchored, warm, and sigma is meaningful
   bool Ready() const
     {
      return(m_anchor>0 && m_count>=m_s.minBarsSinceAnchor && m_sigma>0.0);
     }

   //+--------------------------------------------------------------+
   //| Diagnostics. Call AFTER Compute() for this bar. refPrice is    |
   //| whatever the caller wants d measured against (e.g. close[1]).  |
   //+--------------------------------------------------------------+
   SDiagAVWAP Diag(const double refPrice) const
     {
      SDiagAVWAP d;
      d.hasAnchor      =(m_anchor>0);
      d.ready          =Ready();
      d.suppressed     =(m_anchor>0 && !Ready());
      d.anchorTime     =m_anchor;
      d.barsSinceAnchor=m_count;
      d.vwap =m_vwap; d.sigma=m_sigma;
      d.u1=U1(); d.u2=U2(); d.l1=L1(); d.l2=L2();
      d.refPrice=refPrice;
      d.dPrice =refPrice-m_vwap;
      d.dSigma =(m_sigma>0.0)?d.dPrice/m_sigma:0.0;
      return(d);
     }
  };

#endif // V2_AVWAP_MQH
